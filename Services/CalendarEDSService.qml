pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../Common/edsparser.js" as Lib

Singleton {
  id: root

  // -------- public state
  property var calendars: []        // [{uid,name,backend,enabled}]
  property var eventsByUid: ({})    // { uid: [event,...] }
  property string lastError: ""

  // -------- signals
  signal calendarsChangedExternally()
  signal eventsChangedExternally(string calendarUid)
  signal reminderTriggered(var payload) // placeholder if you parse Alarm signals
  signal eventsUpdated() // Internal signal when events change

  // -------- tools
  readonly property string gdbus: "gdbus"

  // one-shot runner
  function run(command, args, onOk, onFail) {
    const p = Qt.createQmlObject('import QtQuick; import Quickshell.Io; Process { }', root)
    p.command = [command].concat(args)
    
    const io = Qt.createQmlObject('import QtQuick; import Quickshell.Io; StdioCollector {}', p)
    p.stdout = io
    
    let finished = false
    
    io.onStreamFinished.connect(function() {
      if (!finished) {
        finished = true
        if (onOk) onOk(io.text)
        p.destroy()
      }
    })
    
    p.onExited.connect(function(code) {
      if (!finished) {
        finished = true
        if (code === 0) {
          if (onOk) onOk(io.text)
        } else {
          (onFail || (e => root.lastError = e))(`${command} failed: exit code ${code}`)
        }
        p.destroy()
      }
    })
    
    p.running = true
  }

  // -------- public API
  function listCalendars() {
    lastError = ""
    const args = [
      "call","--session",
      "--dest","org.gnome.evolution.dataserver.Sources5",
      "--object-path","/org/gnome/evolution/dataserver/SourceManager",
      "--method","org.freedesktop.DBus.ObjectManager.GetManagedObjects"
    ]
    run(gdbus, args, raw => {
      const candidates = Lib.EDSParser.extractCalendarSources(raw)
      if (!candidates.length) {
        calendars = [{ uid: "system-calendar", name: "Personal", backend: "local", enabled: true }]
        return
      }
      let pending = candidates.length
      const working = []
      candidates.forEach(uid => {
        _openCalendar(uid, (ok) => {
          if (ok) working.push(uid)
          if (--pending === 0) calendars = Lib.EDSParser.extractCalendarMeta(raw, working)
        })
      })
    })
  }

  // params: { calendars?: [uid], start?, end?, query? }
  function getEvents(params) {
    lastError = ""
    params = params || {}
    const chosen = params.calendars && params.calendars.length
      ? params.calendars
      : calendars.map(c => c.uid)

    const startQ = Lib.EDSParser.toQueryUtc(params.start || "1970-01-01T00:00:00Z")
    const endQ   = Lib.EDSParser.toQueryUtc(params.end   || "2050-01-01T00:00:00Z")

    chosen.forEach(uid => {
      _openCalendar(uid, (ok, bus, obj) => {
        if (!ok) {
          console.log("CalendarEDSService: Failed to open calendar", uid)
          return
        }
        console.log("CalendarEDSService: Successfully opened calendar", uid, "bus:", bus, "obj:", obj)
        const filter = `(occur-in-time-range? (make-time "${startQ}") (make-time "${endQ}"))`
        const args = ["call","--session","--dest",bus,"--object-path",obj,
                      "--method","org.gnome.evolution.dataserver.Calendar.GetObjectList",
                      filter]
        console.log("CalendarEDSService: Running gdbus command:", args.join(" "))
        run(gdbus, args, raw => {
          console.log("CalendarEDSService: Got events response for", uid, "- length:", raw.length)
          const vevents = Lib.EDSParser.extractVEVENTs(raw)
          console.log("CalendarEDSService: Extracted", vevents.length, "VEVENTs for", uid)
          const items = vevents.map(v => {
            const ev = Lib.EDSParser.ICS.parseEvent(v)
            ev.calendar_uid = uid
            return ev
          }).filter(ev => {
            if (!params.query) return true
            const hay = (ev.summary||"") + " " + (ev.description||"")
            return hay.toLowerCase().indexOf(params.query.toLowerCase()) !== -1
          })
          console.log("CalendarEDSService: Parsed", items.length, "events for", uid)
          if (items.length > 0) {
            console.log("CalendarEDSService: Sample events:")
            for (let i = 0; i < Math.min(3, items.length); i++) {
              console.log("  -", items[i].summary, "on", items[i].start)
            }
          }
          const copy = Object.assign({}, eventsByUid)
          copy[uid] = items
          eventsByUid = copy
          eventsUpdated()
        }, err => {
          console.log("CalendarEDSService: Error getting events for", uid, ":", err)
        })
      })
    })
  }

  // opts: { calendar, summary, start, end?, description?, location?, allDay? }
  function createEvent(opts) {
    lastError = ""
    if (!opts || !opts.calendar || !opts.summary || !opts.start) {
      lastError = "Missing required fields: calendar, summary, start"
      return
    }
    _openCalendar(opts.calendar, (ok, bus, obj) => {
      if (!ok) return
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
      const args = ["call","--session","--dest",bus,"--object-path",obj,
                    "--method","org.gnome.evolution.dataserver.Calendar.CreateObjects",
                    `["${payload}"]`, "0"]
      run(gdbus, args, _ => {
        // quick refresh around new event time
        getEvents({
          calendars: [opts.calendar],
          start: Lib.EDSParser.windowStart(opts.start),
          end: Lib.EDSParser.windowEnd(opts.end || Lib.EDSParser.plusHour(opts.start))
        })
      })
    })
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
  function _openCalendar(uid, cb) {
    const args = [
      "call","--session",
      "--dest","org.gnome.evolution.dataserver.Calendar8",
      "--object-path","/org/gnome/evolution/dataserver/CalendarFactory",
      "--method","org.gnome.evolution.dataserver.CalendarFactory.OpenCalendar",
      uid
    ]
    console.log("CalendarEDSService: Opening calendar", uid, "with command:", args.join(" "))
    run(gdbus, args, raw => {
      console.log("CalendarEDSService: OpenCalendar response for", uid, ":", raw.trim())
      const m = Lib.EDSParser.parseOpenCalendar(raw)
      if (!m) { 
        lastError = "OpenCalendar parse failed for " + uid + ": " + raw.trim()
        console.log("CalendarEDSService: Parse failed for", uid, "raw:", raw.trim())
        cb(false)
        return 
      }
      console.log("CalendarEDSService: Parsed calendar", uid, "bus:", m.bus, "path:", m.objectPath)
      cb(true, m.bus, m.objectPath)
    }, err => { 
      console.log("CalendarEDSService: OpenCalendar failed for", uid, "error:", err)
      cb(false) 
    })
  }
  
  // Convenience properties for backward compatibility
  readonly property bool available: calendars.length > 0
  readonly property bool loading: false
  readonly property var events: {
    const allEvents = []
    for (const uid in eventsByUid) {
      allEvents.push(...eventsByUid[uid])
    }
    return allEvents
  }
  readonly property bool hasEvents: events.length > 0

  // Helper function to get events for a specific date
  function getEventsForDate(date) {
    const allEvents = []
    for (const uid in eventsByUid) {
      allEvents.push(...eventsByUid[uid])
    }
    
    const targetDate = Qt.formatDate(date, "yyyy-MM-dd")
    return allEvents.filter(event => {
      if (!event.start) return false
      
      // Handle different event.start formats
      let eventDate = ""
      const startStr = event.start.toString().replace(/\\r/g, "").replace(/\r/g, "").trim()
      
      if (startStr.match(/^\d{8}$/)) {
        // YYYYMMDD format (like "20250720")
        const year = startStr.substring(0, 4)
        const month = startStr.substring(4, 6)
        const day = startStr.substring(6, 8)
        eventDate = `${year}-${month}-${day}`
      } else if (startStr.match(/^\d{4}-\d{2}-\d{2}/)) {
        // Already in YYYY-MM-DD format
        eventDate = startStr.substring(0, 10)
      } else {
        // Try to parse as a date object
        try {
          eventDate = Qt.formatDate(new Date(startStr), "yyyy-MM-dd")
        } catch (e) {
          return false
        }
      }
      
      return eventDate === targetDate
    }).map(event => {
      // Convert event properties to the format expected by Events.qml
      const convertedEvent = Object.assign({}, event)
      
      // Convert date strings to Date objects
      if (event.start) {
        const startStr = event.start.toString().replace(/\\r/g, "").replace(/\r/g, "").trim()
        if (startStr.match(/^\d{8}$/)) {
          const year = startStr.substring(0, 4)
          const month = parseInt(startStr.substring(4, 6)) - 1 // Month is 0-indexed
          const day = startStr.substring(6, 8)
          convertedEvent.start = new Date(year, month, day)
          convertedEvent.allDay = true
        } else {
          try {
            convertedEvent.start = new Date(startStr)
            convertedEvent.allDay = false
          } catch (e) {
            convertedEvent.start = new Date()
            convertedEvent.allDay = false
          }
        }
      }
      
      if (event.end) {
        const endStr = event.end.toString().replace(/\\r/g, "").replace(/\r/g, "").trim()
        if (endStr.match(/^\d{8}$/)) {
          const year = endStr.substring(0, 4)
          const month = parseInt(endStr.substring(4, 6)) - 1
          const day = endStr.substring(6, 8)
          convertedEvent.end = new Date(year, month, day)
        } else {
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
      
      // Add title property for compatibility
      convertedEvent.title = convertedEvent.summary || "Untitled Event"
      
      return convertedEvent
    })
  }

  // Helper function to check if date has events
  function hasEventsForDate(date) {
    const events = getEventsForDate(date)
    return events.length > 0
  }
}