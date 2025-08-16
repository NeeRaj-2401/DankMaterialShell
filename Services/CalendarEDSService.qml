pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../Common/edsparser.js" as Lib

Singleton {
  id: root

  // -------- public state
  property var calendars: []        // [{uid,name,backend,enabled,color}]
  property var eventsByUid: ({})    // { uid: [event,...] }
  property string lastError: ""
  
  readonly property var calendarColors: [
    "#6366F1",
    "#10B981",
    "#F59E0B",
    "#EF4444",
    "#8B5CF6",
    "#06B6D4",
    "#F97316",
    "#84CC16",
    "#EC4899",
    "#64748B",
    "#14B8A6",
    "#A855F7",
    "#22C55E",
    "#F472B6",
    "#6B7280"
  ]
  
  // Helper to get consistent color for calendar
  function getCalendarColor(calendarUid) {
    const cal = calendars.find(c => c.uid === calendarUid)
    if (cal && cal.color) return cal.color
    
    const sortedCals = calendars.slice().sort((a, b) => {
      const nameCompare = a.name.localeCompare(b.name)
      if (nameCompare !== 0) return nameCompare
      return a.uid.localeCompare(b.uid)
    })
    const index = sortedCals.findIndex(c => c.uid === calendarUid)
    if (index === -1) return calendarColors[0]
    return calendarColors[index % calendarColors.length]
  }

  // -------- signals
  signal calendarsChangedExternally()
  signal eventsChangedExternally(string calendarUid)
  signal reminderTriggered(var payload) // placeholder if you parse Alarm signals
  signal eventsUpdated() // Internal signal when events change

  // -------- tools
  readonly property string gdbus: "gdbus"

  // Process for listing calendars
  Process {
    id: listCalendarsProc
    command: []
    running: false
    
    stdout: StdioCollector {
      id: listCalendarsOutput
      onStreamFinished: {
        root._listCalendarsRawOutput = text
        const candidates = Lib.EDSParser.extractCalendarSources(text)
        if (!candidates.length) {
          calendars = [{ uid: "system-calendar", name: "Personal", backend: "local", enabled: true }]
          return
        }
        root._pendingCalendarOpens = candidates
        root._workingCalendars = []
        root._openNextCalendar()
      }
    }
    
    onExited: (code) => {
      if (code !== 0) {
        lastError = `listCalendars failed: exit code ${code}`
      }
    }
  }
  
  // Process for opening calendars
  Process {
    id: openCalendarProc
    command: []
    running: false
    
    property string currentUid: ""
    property bool continueToEvents: false
    property bool continueToCreate: false
    property bool hasProcessed: false
    
    stdout: StdioCollector {
      id: openCalendarOutput
      onStreamFinished: {
        if (openCalendarProc.hasProcessed) return
        openCalendarProc.hasProcessed = true
        
        const m = Lib.EDSParser.parseOpenCalendar(text)
        if (m) {
          root._workingCalendars.push(openCalendarProc.currentUid)
          root._calendarConnections[openCalendarProc.currentUid] = m
        } else {
        }
        root._openNextCalendar(openCalendarProc.continueToEvents, openCalendarProc.continueToCreate)
      }
    }
    
    stderr: StdioCollector {
      id: openCalendarError
    }
    
    onExited: (code) => {
      // Only process if we haven't already handled this
      if (openCalendarProc.hasProcessed) return
      
      // For successful exits (code 0), let the stream handler process the output
      // For failed exits, process immediately
      if (code !== 0) {
        openCalendarProc.hasProcessed = true
        root._openNextCalendar(openCalendarProc.continueToEvents, openCalendarProc.continueToCreate)
      }
    }
  }
  
  // Process for getting events from all calendars in a single command
  Process {
    id: getEventsProc
    command: []
    running: false
    
    property var calendarUids: []
    property string startQuery: ""
    property string endQuery: ""
    property string searchQuery: ""
    
    stdout: StdioCollector {
      id: getEventsOutput
      onStreamFinished: {
        
        // Parse the combined output - each calendar's output is separated by "---CALENDAR:uid---"
        const sections = text.split("---CALENDAR:")
        const collectedEvents = {}
        
        
        for (let i = 1; i < sections.length; i++) { // Skip first empty section
          const section = sections[i]
          const uidEndIndex = section.indexOf("---")
          if (uidEndIndex === -1) continue
          
          const uid = section.substring(0, uidEndIndex)
          const rawData = section.substring(uidEndIndex + 3) // Skip "---"
          
          
          if (rawData.trim().length === 0) {
            collectedEvents[uid] = []
            continue
          }
          
          const vevents = Lib.EDSParser.extractVEVENTs(rawData)
          
          const items = vevents.map(v => {
            const ev = Lib.EDSParser.ICS.parseEvent(v)
            ev.calendar_uid = uid
            ev.calendar_color = getCalendarColor(uid)
            return ev
          }).filter(ev => {
            if (!getEventsProc.searchQuery) return true
            const hay = (ev.summary||"") + " " + (ev.description||"")
            return hay.toLowerCase().indexOf(getEventsProc.searchQuery.toLowerCase()) !== -1
          })
          
          if (items.length > 0) {
          }
          
          collectedEvents[uid] = items
        }
        
        // Merge new events with existing events instead of replacing
        const mergedEvents = Object.assign({}, eventsByUid)
        for (const uid in collectedEvents) {
          const newEvents = collectedEvents[uid]
          const existingEvents = mergedEvents[uid] || []
          
          
          // Create a map of existing events by UID to avoid duplicates
          const existingEventMap = new Map()
          existingEvents.forEach(event => {
            if (event.uid) existingEventMap.set(event.uid, event)
          })
          
          // Add new events that don't already exist
          let addedCount = 0
          newEvents.forEach(newEvent => {
            if (!newEvent.uid || !existingEventMap.has(newEvent.uid)) {
              existingEvents.push(newEvent)
              addedCount++
            }
          })
          
          mergedEvents[uid] = existingEvents
        }
        
        eventsByUid = mergedEvents
        
        _fetchingEvents = false
        eventsUpdated()
      }
    }
    
    stderr: StdioCollector {
      id: getEventsError
    }
    
    onExited: (code) => {
      if (code !== 0) {
        _fetchingEvents = false
      }
    }
  }
  
  // Process for creating events
  Process {
    id: createEventProc
    command: []
    running: false
    
    property string calendarUid: ""
    property var eventOptions: null
    
    stdout: StdioCollector {
      id: createEventOutput
      onStreamFinished: {
        // Refresh events after creation
        if (createEventProc.eventOptions) {
          getEvents({
            calendars: [createEventProc.calendarUid],
            start: Lib.EDSParser.windowStart(createEventProc.eventOptions.start),
            end: Lib.EDSParser.windowEnd(createEventProc.eventOptions.end || Lib.EDSParser.plusHour(createEventProc.eventOptions.start))
          })
        }
      }
    }
    
    onExited: (code) => {
      if (code !== 0) {
        lastError = `createEvent failed: exit code ${code}`
      }
    }
  }
  
  // Internal state for managing operations
  property var _pendingCalendarOpens: []
  property var _workingCalendars: []
  property var _calendarConnections: ({}) // uid -> {bus, objectPath}
  property string _listCalendarsRawOutput: ""

  // -------- public API
  function listCalendars() {
    lastError = ""
    listCalendarsProc.command = [
      gdbus,
      "call","--session",
      "--dest","org.gnome.evolution.dataserver.Sources5",
      "--object-path","/org/gnome/evolution/dataserver/SourceManager",
      "--method","org.freedesktop.DBus.ObjectManager.GetManagedObjects"
    ]
    listCalendarsProc.running = true
  }

  property bool _fetchingEvents: false
  
  // params: { calendars?: [uid], start?, end?, query? }
  function getEvents(params) {
    lastError = ""
    params = params || {}
    const chosen = params.calendars && params.calendars.length
      ? params.calendars
      : calendars.map(c => c.uid)

    const startQ = Lib.EDSParser.toQueryUtc(params.start || "1970-01-01T00:00:00Z")
    const endQ   = Lib.EDSParser.toQueryUtc(params.end   || "2050-01-01T00:00:00Z")

    // Prevent concurrent requests
    if (_fetchingEvents) {
      return
    }
    
    _fetchingEvents = true

    // Setup the process for batch fetching
    getEventsProc.calendarUids = chosen
    getEventsProc.startQuery = startQ
    getEventsProc.endQuery = endQ
    getEventsProc.searchQuery = params.query || ""
    
    // Ensure all calendars are opened first
    _pendingCalendarOpens = chosen.filter(uid => !_calendarConnections[uid])
    if (_pendingCalendarOpens.length > 0) {
      _openNextCalendar(true) // true means continue to events after opening
    } else {
      _fetchAllEvents()
    }
  }

  // opts: { calendar, summary, start, end?, description?, location?, allDay? }
  function createEvent(opts) {
    lastError = ""
    if (!opts || !opts.calendar || !opts.summary || !opts.start) {
      lastError = "Missing required fields: calendar, summary, start"
      return
    }
    
    // Check if calendar is already opened
    const conn = _calendarConnections[opts.calendar]
    if (conn) {
      _createEventWithConnection(opts, conn.bus, conn.objectPath)
    } else {
      // Need to open calendar first
      _pendingCalendarOpens = [opts.calendar]
      _pendingEventCreation = opts
      _openNextCalendar(false, true) // false for events, true for create
    }
  }

  // -------- monitoring via dbus-monitor
  Process {
    id: monitor
    command: [
      "dbus-monitor", "--session", 
      "type='signal',interface='org.gnome.evolution.dataserver.Calendar'"
    ]
    running: true
    
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) {
        if (line.indexOf("org.gnome.evolution.dataserver.Calendar") >= 0) {
          // Fire coarse hints. Consumers can decide what to refetch.
          if (line.indexOf("ObjectsAdded") >= 0 ||
              line.indexOf("ObjectsRemoved") >= 0 ||
              line.indexOf("ObjectsModified") >= 0) {
            root.eventsChangedExternally("")
          } else {
            root.calendarsChangedExternally()
          }
        }
        if (line.indexOf("org.gnome.evolution.dataserver.Alarm") >= 0) {
          // Extend here if you want to parse alarm payloads.
          // root.reminderTriggered({ raw: line })
        }
      }
    }
  }

  Component.onCompleted: {
    listCalendars()
  }

  // -------- internals
  property var _pendingEventCreation: null
  
  function _openNextCalendar(continueToEvents, continueToCreate) {
    continueToEvents = continueToEvents || false
    continueToCreate = continueToCreate || false
    
    if (_pendingCalendarOpens.length === 0) {
      // All done opening calendars
      if (continueToEvents) {
        _fetchAllEvents()
      } else if (continueToCreate && _pendingEventCreation) {
        const opts = _pendingEventCreation
        const conn = _calendarConnections[opts.calendar]
        if (conn) {
          _createEventWithConnection(opts, conn.bus, conn.objectPath)
        }
        _pendingEventCreation = null
      } else if (_listCalendarsRawOutput) {
        // Finish listCalendars operation - only include working calendar sources like calendar-cli.sh
        const allDiscoveredCalendars = Lib.EDSParser.extractCalendarSources(_listCalendarsRawOutput)
        let allCals = Lib.EDSParser.extractCalendarMeta(_listCalendarsRawOutput, allDiscoveredCalendars)
        
        // Filter to only include calendars that can actually be used (have proper backends)
        let cals = allCals.filter(cal => {
          // Include local calendars, caldav calendars, but exclude unknown backends and address books
          const include = cal.backend === "local" || cal.backend === "caldav" || cal.backend === "contacts"
          return include
        })
        
        
        let sortedCals = cals.slice().sort((a, b) => {
          const nameCompare = a.name.localeCompare(b.name)
          if (nameCompare !== 0) return nameCompare
          return a.uid.localeCompare(b.uid)
        })
        
        cals.forEach(cal => {
          const index = sortedCals.findIndex(sc => sc.uid === cal.uid)
          cal.color = calendarColors[index % calendarColors.length]
        })
        
        calendars = cals
        _listCalendarsRawOutput = ""
        
        // Automatically fetch events for the current time period
        if (calendars.length > 0) {
          const now = new Date()
          const startOfMonth = new Date(now.getFullYear(), now.getMonth(), 1)
          const endOfMonth = new Date(now.getFullYear(), now.getMonth() + 1, 0)
          getEvents({
            start: startOfMonth.toISOString(),
            end: endOfMonth.toISOString()
          })
        }
      }
      return
    }
    
    const uid = _pendingCalendarOpens.shift()
    openCalendarProc.currentUid = uid
    openCalendarProc.continueToEvents = continueToEvents
    openCalendarProc.continueToCreate = continueToCreate
    
    
    const cmd = [
      "timeout", "10s", gdbus,
      "call","--session",
      "--dest","org.gnome.evolution.dataserver.Calendar8",
      "--object-path","/org/gnome/evolution/dataserver/CalendarFactory",
      "--method","org.gnome.evolution.dataserver.CalendarFactory.OpenCalendar",
      uid
    ]
    openCalendarProc.hasProcessed = false
    openCalendarProc.command = cmd
    
    // Add a small delay to prevent EDS from reusing subprocess paths
    Qt.callLater(() => {
      openCalendarProc.running = true
    })
  }
  
  function _fetchAllEvents() {
    // Build a single bash command that fetches from all calendars
    const bashCommands = []
    const calendarsToRefresh = []
    
    
    for (const uid of getEventsProc.calendarUids) {
      const conn = _calendarConnections[uid]
      if (!conn) {
        calendarsToRefresh.push(uid)
        continue
      }
      
      const filter = `'(occur-in-time-range? (make-time "${getEventsProc.startQuery}") (make-time "${getEventsProc.endQuery}"))'`
      const gdbusCmd = `gdbus call --session --dest '${conn.bus}' --object-path '${conn.objectPath}' --method 'org.gnome.evolution.dataserver.Calendar.GetObjectList' ${filter}`
      
      // Add marker and command
      bashCommands.push(`echo '---CALENDAR:${uid}---'`)
      bashCommands.push(gdbusCmd)
    }
    
    // If there are calendars that need to be refreshed, do that first
    if (calendarsToRefresh.length > 0) {
      _pendingCalendarOpens = calendarsToRefresh
      _openNextCalendar(true)
      return
    }
    
    if (bashCommands.length === 0) {
      _fetchingEvents = false
      return
    }
    
    const combinedCommand = bashCommands.join('; ')
    
    getEventsProc.command = ["bash", "-c", combinedCommand]
    getEventsProc.running = true
  }
  
  function _createEventWithConnection(opts, bus, objectPath) {
    const uid = "qml-event-" + Date.now()
    const payload = Lib.EDSParser.ICS.buildEvent({
      uid: uid,
      dtstamp: Lib.EDSParser.nowUtcStamp(),
      start: opts.start,
      end: opts.end,
      summary: opts.summary,
      description: opts.description || "",
      location: opts.location || "",
      allDay: !!opts.allDay
    })
    
    createEventProc.calendarUid = opts.calendar
    createEventProc.eventOptions = opts
    createEventProc.command = [
      gdbus,
      "call","--session",
      "--dest", bus,
      "--object-path", objectPath,
      "--method","org.gnome.evolution.dataserver.Calendar.CreateObjects",
      `["${payload}"]`, "0"
    ]
    createEventProc.running = true
  }
  
  // Convenience properties for backward compatibility
  readonly property bool available: calendars.length > 0
  readonly property bool loading: false
  readonly property var events: {
    const allEvents = []
    for (const uid in eventsByUid) {
      allEvents.push(...eventsByUid[uid])
    }
    
    // Deduplicate events by UID (same event may appear in multiple calendars)
    const deduplicatedEvents = []
    const seenUIDs = new Set()
    
    for (const event of allEvents) {
      if (event.uid && seenUIDs.has(event.uid)) {
        continue
      }
      
      if (event.uid) {
        seenUIDs.add(event.uid)
      }
      deduplicatedEvents.push(event)
    }
    
    return deduplicatedEvents
  }
  readonly property bool hasEvents: events.length > 0

  // Helper function to get events for a specific date
  function getEventsForDate(date) {
    const allEvents = []
    for (const uid in eventsByUid) {
      allEvents.push(...eventsByUid[uid])
    }
    
    // Deduplicate events by UID (same event may appear in multiple calendars)
    const deduplicatedEvents = []
    const seenUIDs = new Set()
    
    for (const event of allEvents) {
      if (event.uid && seenUIDs.has(event.uid)) {
        continue
      }
      
      if (event.uid) {
        seenUIDs.add(event.uid)
      }
      deduplicatedEvents.push(event)
    }
    
    
    const targetDate = Qt.formatDate(date, "yyyy-MM-dd")
    return deduplicatedEvents.filter(event => {
      if (!event.start || !event.end) return false
      
      // Parse start date
      let startDate = ""
      const startStr = event.start.toString().replace(/\\r/g, "").replace(/\r/g, "").trim()
      let isAllDayFormat = false
      
      if (startStr.match(/^\d{4}-\d{2}-\d{2}$/)) {
        // YYYY-MM-DD format (all-day events)
        startDate = startStr
        isAllDayFormat = true
      } else if (startStr.match(/^\d{4}-\d{2}-\d{2}T/)) {
        // ISO datetime format
        startDate = startStr.substring(0, 10)
      } else {
        // Try to parse and format
        try {
          startDate = Qt.formatDate(new Date(startStr), "yyyy-MM-dd")
        } catch (e) {
          return false
        }
      }
      
      // Parse end date  
      let endDate = ""
      const endStr = event.end.toString().replace(/\\r/g, "").replace(/\r/g, "").trim()
      
      if (endStr.match(/^\d{4}-\d{2}-\d{2}$/)) {
        // YYYY-MM-DD format (all-day events)
        endDate = endStr
      } else if (endStr.match(/^\d{4}-\d{2}-\d{2}T/)) {
        // ISO datetime format
        endDate = endStr.substring(0, 10)
      } else {
        // Try to parse and format
        try {
          endDate = Qt.formatDate(new Date(endStr), "yyyy-MM-dd")
        } catch (e) {
          endDate = startDate // Fallback to start date
        }
      }
      
      // For all-day events, calendar systems set the end date to the day AFTER the event ends
      // This applies to both single-day and multi-day events, so we always subtract 1 day
      if (isAllDayFormat && endDate > startDate) {
        const endDateObj = new Date(endDate)
        endDateObj.setDate(endDateObj.getDate() - 1)
        endDate = Qt.formatDate(endDateObj, "yyyy-MM-dd")
      }
      
      // Check if target date falls within the event range (inclusive)
      const basicMatch = targetDate >= startDate && targetDate <= endDate
      if (basicMatch) return true
      
      // Handle yearly recurring events (RRULE:FREQ=YEARLY)
      // Check if this event has yearly recurrence by looking at the raw event data
      if (event.rrule && event.rrule.includes("FREQ=YEARLY")) {
        const targetDateObj = new Date(targetDate)
        const eventStartObj = new Date(startDate)
        
        // For yearly recurrence, check if month and day match regardless of year
        if (targetDateObj.getMonth() === eventStartObj.getMonth() && 
            targetDateObj.getDate() === eventStartObj.getDate()) {
          return true
        }
      }
      
      return false
    }).map(event => {
      // Convert event properties to the format expected by Events.qml
      const convertedEvent = Object.assign({}, event)
      
      // Parse start time and detect all-day events
      if (event.start) {
        const startStr = event.start.toString().replace(/\\r/g, "").replace(/\r/g, "").trim()
        
        if (startStr.match(/^\d{4}-\d{2}-\d{2}$/)) {
          // YYYY-MM-DD format = all-day event
          const parts = startStr.split("-")
          convertedEvent.start = new Date(parseInt(parts[0]), parseInt(parts[1]) - 1, parseInt(parts[2]))
          convertedEvent.allDay = true
        } else if (startStr.match(/^\d{4}-\d{2}-\d{2}T/)) {
          // ISO datetime format = timed event
          try {
            convertedEvent.start = new Date(startStr)
            convertedEvent.allDay = false
          } catch (e) {
            // Fallback: treat as all-day
            const datePart = startStr.substring(0, 10).split("-")
            convertedEvent.start = new Date(parseInt(datePart[0]), parseInt(datePart[1]) - 1, parseInt(datePart[2]))
            convertedEvent.allDay = true
          }
        } else {
          // Try generic parsing
          try {
            convertedEvent.start = new Date(startStr)
            // If the time is exactly midnight, it's likely an all-day event
            convertedEvent.allDay = (convertedEvent.start.getHours() === 0 && 
                                   convertedEvent.start.getMinutes() === 0 && 
                                   convertedEvent.start.getSeconds() === 0)
          } catch (e) {
            convertedEvent.start = new Date()
            convertedEvent.allDay = true
          }
        }
      }
      
      // Parse end time
      if (event.end) {
        const endStr = event.end.toString().replace(/\\r/g, "").replace(/\r/g, "").trim()
        
        if (endStr.match(/^\d{4}-\d{2}-\d{2}$/)) {
          // YYYY-MM-DD format = all-day event
          const parts = endStr.split("-")
          convertedEvent.end = new Date(parseInt(parts[0]), parseInt(parts[1]) - 1, parseInt(parts[2]))
        } else if (endStr.match(/^\d{4}-\d{2}-\d{2}T/)) {
          // ISO datetime format = timed event
          try {
            convertedEvent.end = new Date(endStr)
          } catch (e) {
            // Fallback to date part only
            const datePart = endStr.substring(0, 10).split("-")
            convertedEvent.end = new Date(parseInt(datePart[0]), parseInt(datePart[1]) - 1, parseInt(datePart[2]))
          }
        } else {
          // Try generic parsing
          try {
            convertedEvent.end = new Date(endStr)
          } catch (e) {
            convertedEvent.end = convertedEvent.start
          }
        }
      } else {
        // Default end time to start time if not provided
        convertedEvent.end = convertedEvent.start
      }
      
      // Handle yearly recurring events - update dates to current year if this is a recurrence match
      if (event.rrule && event.rrule.includes("FREQ=YEARLY") && convertedEvent.start) {
        const targetDateObj = new Date(date)
        const eventStartObj = convertedEvent.start
        
        // If this is a yearly recurring event and the month/day matches the target date,
        // update the event dates to the target year
        if (targetDateObj.getMonth() === eventStartObj.getMonth() && 
            targetDateObj.getDate() === eventStartObj.getDate()) {
          
          // Update start date to target year
          const newStart = new Date(eventStartObj)
          newStart.setFullYear(targetDateObj.getFullYear())
          convertedEvent.start = newStart
          
          // Update end date to target year if it exists
          if (convertedEvent.end) {
            const timeDiff = convertedEvent.end.getTime() - eventStartObj.getTime()
            convertedEvent.end = new Date(newStart.getTime() + timeDiff)
          } else {
            convertedEvent.end = newStart
          }
        }
      }
      
      // Add title property for compatibility
      convertedEvent.title = convertedEvent.summary || "Untitled Event"
      
      // Ensure calendar color is set
      if (!convertedEvent.calendar_color) {
        convertedEvent.calendar_color = getCalendarColor(convertedEvent.calendar_uid)
      }
      
      return convertedEvent
    })
  }

  // Helper function to check if date has events
  function hasEventsForDate(date) {
    const events = getEventsForDate(date)
    return events.length > 0
  }
}