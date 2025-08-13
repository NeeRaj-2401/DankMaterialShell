pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property bool edsAvailable: false
    property bool goaAvailable: false
    property bool initialized: false
    property var eventsByDate: ({})
    property var allEvents: []
    property bool isLoading: false
    property bool servicesRunning: false
    property date lastStartDate
    property date lastEndDate
    property string lastError: ""
    property int cacheValidityMinutes: 5
    // Calendar sources discovered dynamically
    property var calendarSources: []
    property bool calendarDiscoveryCompleted: false

    // JavaScript iCalendar parser
    function parseICalendarEvents(icalText, calendarSource, startDate, endDate) {
        let events = []
        
        if (!icalText || icalText.trim() === '') {
            return events
        }
        
        // Extract VEVENT blocks using regex
        let veventPattern = /BEGIN:VEVENT[\s\S]*?END:VEVENT/g
        let matches = icalText.match(veventPattern)
        
        if (!matches) {
            return events
        }
        
        for (let veventBlock of matches) {
            let event = {
                id: "",
                title: "", 
                description: "",
                location: "",
                start: "",
                end: "",
                allDay: false,
                calendar: calendarSource.name,
                color: calendarSource.color
            }
            
            // Unfold lines (handle line continuations with leading spaces)
            let unfoldedText = veventBlock.replace(/\r?\n[ \t]/g, '')
            let lines = unfoldedText.split(/\r?\n/)
            
            for (let line of lines) {
                line = line.trim()
                if (!line.includes(':')) continue
                
                let colonIndex = line.indexOf(':')
                let key = line.substring(0, colonIndex).toUpperCase()
                let value = line.substring(colonIndex + 1).trim()
                
                switch (true) {
                    case key === "UID":
                        event.id = value
                        break
                    case key === "SUMMARY":
                        event.title = value
                        break
                    case key === "DESCRIPTION":
                        event.description = value
                        break
                    case key === "LOCATION":
                        event.location = value
                        break
                    case key.startsWith("DTSTART"):
                        try {
                            event.start = new Date(parseDateString(value))
                            event.allDay = line.includes(";VALUE=DATE:")
                        } catch (e) {
                            console.warn("CalendarService: Failed to parse start date:", value, e)
                        }
                        break
                    case key.startsWith("DTEND"):
                        try {
                            event.end = new Date(parseDateString(value))
                        } catch (e) {
                            console.warn("CalendarService: Failed to parse end date:", value, e)
                        }
                        break
                }
            }
            
            // Only include events with title and valid start date
            if (event.title && event.start) {
                // Use current time for events with invalid dates
                if (isEventInDateRange(event.start, event.end, startDate, endDate)) {
                    events.push(event)
                }
            }
        }
        
        return events
    }

    function isEventInDateRange(eventStart, eventEnd, rangeStart, rangeEnd) {
        if (!eventStart) return false
        
        try {
            let startMs = eventStart.getTime ? eventStart.getTime() : eventStart
            let endMs = eventEnd ? (eventEnd.getTime ? eventEnd.getTime() : eventEnd) : startMs
            let rangeStartMs = rangeStart.getTime()
            let rangeEndMs = rangeEnd.getTime()
            
            return startMs <= rangeEndMs && endMs >= rangeStartMs
        } catch (e) {
            console.warn("CalendarService: Date parsing error:", e)
            return true
        }
    }

    function parseDBusCalendarOutput(dbusOutput, calendarSource) {
        let events = []
        
        if (!dbusOutput || !dbusOutput.includes("BEGIN:VEVENT")) {
            return events
        }
        
        // Parse the D-Bus array output format
        // Expected format: as N "icalendar_string1" "icalendar_string2" ...
        let lines = dbusOutput.split('\n')
        for (let line of lines) {
            if (line.includes("BEGIN:VEVENT")) {
                // Extract iCalendar string from D-Bus format
                let icalMatch = line.match(/"(BEGIN:VEVENT.*?END:VEVENT[^"]*)"/)
                if (icalMatch) {
                    let icalString = icalMatch[1].replace(/\\r\\n/g, '\n').replace(/\\"/g, '"')
                    let eventEvents = parseICalendarEvents(icalString, calendarSource, new Date(2025, 0, 1), new Date(2025, 11, 31))
                    events = events.concat(eventEvents)
                }
            }
        }
        
        return events
    }

    function parseDateString(dateStr) {
        // Handle YYYYMMDD format
        if (dateStr.length === 8) {
            let year = parseInt(dateStr.substring(0, 4))
            let month = parseInt(dateStr.substring(4, 6)) - 1
            let day = parseInt(dateStr.substring(6, 8))
            return new Date(year, month, day).getTime()
        } 
        // Handle YYYYMMDDTHHMMSS[Z] format
        else if (dateStr.length >= 15) {
            let year = parseInt(dateStr.substring(0, 4))
            let month = parseInt(dateStr.substring(4, 6)) - 1
            let day = parseInt(dateStr.substring(6, 8))
            let hour = parseInt(dateStr.substring(9, 11))
            let minute = parseInt(dateStr.substring(11, 13))
            let second = parseInt(dateStr.substring(13, 15))
            return new Date(year, month, day, hour, minute, second).getTime()
        }
        
        throw new Error("Unparseable date: " + dateStr)
    }
    
    property var edsServices: ["evolution-source-registry", "evolution-calendar-factory"]
    property string cacheFile: "/tmp/quickshell_calendar_cache.json"
    
    function checkEDSAvailability() {
        if (!edsCheckProcess.running)
            edsCheckProcess.running = true
    }

    function checkGOAAvailability() {
        if (!goaCheckProcess.running)
            goaCheckProcess.running = true
    }

    function ensureServicesRunning() {
        if (!servicesStartProcess.running)
            servicesStartProcess.running = true
    }

    function loadCurrentMonth() {
        if (!root.edsAvailable)
            return

        let today = new Date()
        let firstDay = new Date(today.getFullYear(), today.getMonth(), 1)
        let lastDay = new Date(today.getFullYear(), today.getMonth() + 1, 0)
        let startDate = new Date(firstDay)
        startDate.setDate(startDate.getDate() - firstDay.getDay() - 7)
        let endDate = new Date(lastDay)
        endDate.setDate(endDate.getDate() + (6 - lastDay.getDay()) + 7)
        loadEvents(startDate, endDate)
    }

    function loadEvents(startDate, endDate) {
        console.log("CalendarService: loadEvents called, edsAvailable:", root.edsAvailable, "servicesRunning:", root.servicesRunning)
        if (!root.edsAvailable || !root.servicesRunning) {
            console.warn("CalendarService: Cannot load events - EDS not available or services not running")
            return
        }
        if (root.isLoading) {
            console.log("CalendarService: Already loading, skipping...")
            return
        }
        
        if (isCacheValid(startDate, endDate)) {
            loadFromCache()
            return
        }

        root.lastStartDate = startDate
        root.lastEndDate = endDate
        root.isLoading = true
        
        // Clear previous events
        allEvents = []
        let completedSources = 0
        let totalEnabledSources = calendarSources.filter(s => s.enabled).length
        
        console.log("CalendarService: Loading events from", totalEnabledSources, "sources")
        
        // Load events from each enabled calendar source
        for (let source of calendarSources) {
            if (!source.enabled) continue
            
            if (source.method === "file") {
                // Load from .ics file directly
                fileLoadProcess.calendarSource = source
                fileLoadProcess.totalSources = totalEnabledSources
                fileLoadProcess.start()
            } else if (source.method === "dbus_direct") {
                // Load via direct D-Bus call to discovered calendar object
                directDBusProcess.calendarSource = source
                directDBusProcess.totalSources = totalEnabledSources
                directDBusProcess.start()
            }
        }
    }

    function isCacheValid(startDate, endDate) {
        return false // Disable cache for now during development
    }

    function loadFromCache() {
        // Cache loading implementation
    }

    function saveToCache(events) {
        // Cache saving implementation
    }

    function getEventsForDate(date) {
        let dateKey = Qt.formatDate(date, "yyyy-MM-dd")
        return root.eventsByDate[dateKey] || []
    }

    function hasEventsForDate(date) {
        let events = getEventsForDate(date)
        return events.length > 0
    }

    function refreshCalendars() {
        if (root.edsAvailable && root.servicesRunning) {
            if (root.lastStartDate && root.lastEndDate) {
                loadEvents(root.lastStartDate, root.lastEndDate)
            } else {
                loadCurrentMonth()
            }
        }
    }

    function createEvent(title, startDate, endDate, description, location) {
        if (!root.edsAvailable) {
            console.warn("EDS not available for event creation")
            return false
        }
        
        if (!createEventProcess.running) {
            let startIso = startDate.toISOString().replace(/[-:]/g, '').split('.')[0] + 'Z'
            let endIso = endDate.toISOString().replace(/[-:]/g, '').split('.')[0] + 'Z'
            let uid = "quickshell-" + Date.now() + "-" + Math.random().toString(36).substr(2, 9)
            
            let icalEvent = `BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Quickshell//Calendar Service//EN
BEGIN:VEVENT
UID:${uid}
DTSTART:${startIso}
DTEND:${endIso}
SUMMARY:${title}
DESCRIPTION:${description || ''}
LOCATION:${location || ''}
CREATED:${new Date().toISOString().replace(/[-:]/g, '').split('.')[0] + 'Z'}
LAST-MODIFIED:${new Date().toISOString().replace(/[-:]/g, '').split('.')[0] + 'Z'}
END:VEVENT
END:VCALENDAR`
            
            createEventProcess.eventData = icalEvent
            createEventProcess.running = true
        }
        return true
    }

    function listCalendarAccounts() {
        if (!goaListProcess.running) {
            goaListProcess.running = true
        }
    }

    Component.onCompleted: {
        // Start calendar discovery
        discoverCalendars()
    }
    
    function discoverCalendars() {
        // Discover available calendar sources via D-Bus
        calendarDiscoveryProcess.running = true
    }
    
    function parseDiscoveredCalendars(discoveryOutput) {
        let sources = []
        let lines = discoveryOutput.split('\n')
        let currentCalendar = {}
        let busName = ""
        
        // Define color palette for different calendar types
        let colorPalette = [
            "#62a0ea", // Blue for personal/system
            "#9fe1e7", // Cyan for Google Personal  
            "#f691b2", // Pink for Google Family
            "#42d692", // Green for Google Holidays
            "#ffbe6f", // Orange for Birthdays
            "#a377b8", // Purple for Work
            "#ff6b6b", // Red for Important
            "#4ecdc4"  // Teal for Other
        ]
        let colorIndex = 0
        
        for (let line of lines) {
            line = line.trim()
            
            if (line.startsWith("BUS=")) {
                busName = line.substring(4)
            } else if (line.startsWith("CALENDAR_PATH=")) {
                if (currentCalendar.path || currentCalendar.filePath) {
                    // Finalize previous calendar
                    sources.push(currentCalendar)
                    colorIndex = (colorIndex + 1) % colorPalette.length
                }
                currentCalendar = {
                    color: colorPalette[colorIndex],
                    enabled: true
                }
                
                let pathValue = line.substring(14)
                if (pathValue === "file") {
                    currentCalendar.method = "file"
                } else {
                    currentCalendar.path = pathValue
                    currentCalendar.method = "dbus_direct"
                }
            } else if (line.startsWith("CALENDAR_NAME=")) {
                currentCalendar.name = line.substring(14)
                currentCalendar.id = line.substring(14)
            } else if (line.startsWith("CACHE_DIR=")) {
                currentCalendar.cacheDir = line.substring(10)
            } else if (line.startsWith("WRITABLE=")) {
                currentCalendar.writable = line.substring(9) === "true"
            } else if (line.startsWith("FILE_PATH=")) {
                currentCalendar.filePath = line.substring(10)
            } else if (line.startsWith("BUS_NAME=")) {
                currentCalendar.busName = line.substring(9)
            }
        }
        
        // Add the last calendar
        if (currentCalendar.path || currentCalendar.filePath) {
            sources.push(currentCalendar)
        }
        
        // Set discovered sources
        root.calendarSources = sources
        root.calendarDiscoveryCompleted = true
        root.edsAvailable = sources.length > 0
        root.servicesRunning = sources.length > 0
        root.initialized = true
        
        console.log("CalendarService: Discovered", sources.length, "calendar sources")
        
        // Load events from discovered calendars
        if (sources.length > 0) {
            loadCurrentMonth()
        }
    }

    Process {
        id: calendarDiscoveryProcess
        
        command: ["bash", "-c", `
            # Discover calendar sources - simplified approach
            BUS=$(busctl --user list --no-pager | awk '/org\.gnome\.(evolution\.dataserver|Evolution)\.Calendar[0-9]*/{print $1; exit}')
            if [ -z "$BUS" ]; then
                echo "No EDS Calendar bus found" >&2
                exit 1
            fi
            
            echo "BUS=$BUS"
            
            # Check for system calendar file
            SYSTEM_CALENDAR="/home/purian23/.local/share/evolution/calendar/system/calendar.ics"
            if [ -f "$SYSTEM_CALENDAR" ]; then
                echo "CALENDAR_PATH=file"
                echo "CALENDAR_NAME=system"
                echo "CACHE_DIR=/home/purian23/.local/share/evolution/calendar/system"
                echo "WRITABLE=true"
                echo "FILE_PATH=$SYSTEM_CALENDAR"
                echo "---"
            fi
            
            # Try to discover other calendar sources via CalendarFactory
            # Common calendar IDs to try
            for cal_id in "birthdays" "contacts"; do
                CALENDAR_INFO=$(gdbus call --session \\
                    --dest "$BUS" \\
                    --object-path /org/gnome/evolution/dataserver/CalendarFactory \\
                    --method org.gnome.evolution.dataserver.CalendarFactory.OpenCalendar \\
                    "$cal_id" 2>/dev/null)
                
                if [ -n "$CALENDAR_INFO" ] && echo "$CALENDAR_INFO" | grep -q "object path"; then
                    OBJECT_PATH=$(echo "$CALENDAR_INFO" | grep -o "'/[^']*'" | head -1 | tr -d "'")
                    CAL_BUS_NAME=$(echo "$CALENDAR_INFO" | grep -o "'[^']*Calendar[0-9]*'" | tr -d "'")
                    
                    if [ -n "$OBJECT_PATH" ] && [ -n "$CAL_BUS_NAME" ]; then
                        echo "CALENDAR_PATH=$OBJECT_PATH"
                        echo "CALENDAR_NAME=$cal_id"
                        echo "CACHE_DIR=/home/purian23/.cache/evolution/calendar/$cal_id"
                        echo "WRITABLE=false"
                        echo "BUS_NAME=$CAL_BUS_NAME"
                        echo "---"
                    fi
                fi
            done
        `]
        running: false
        
        onExited: exitCode => {
            if (exitCode === 0) {
                parseDiscoveredCalendars(calendarDiscoveryProcess.output)
            } else {
                console.warn("CalendarService: Failed to discover calendars, exit code:", exitCode)
                // Set service as unavailable
                root.edsAvailable = false
                root.servicesRunning = false
                root.initialized = true
            }
        }
        
        property string output: ""
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                calendarDiscoveryProcess.output += data + "\n"
            }
        }
    }

    Timer {
        id: refreshTimer
        interval: root.cacheValidityMinutes * 60 * 1000
        running: root.edsAvailable && root.servicesRunning
        repeat: true
        onTriggered: refreshCalendars()
    }

    Process {
        id: servicesStartProcess
        
        command: ["bash", "-c", "systemctl --user start evolution-source-registry.service evolution-calendar-factory.service"]
        running: false
        onExited: exitCode => {
            root.servicesRunning = (exitCode === 0)
            if (exitCode === 0) {
                checkEDSAvailability()
            } else {
                console.warn("Failed to start EDS services:", exitCode)
            }
        }
    }

    Process {
        id: edsCheckProcess

        command: ["bash", "-c", "systemctl --user is-active evolution-source-registry.service && systemctl --user is-active evolution-calendar-factory.service"]
        running: false
        onExited: exitCode => {
            root.edsAvailable = (exitCode === 0)
            console.log("CalendarService: EDS check completed, available:", root.edsAvailable)
            if (exitCode === 0) {
                root.servicesRunning = true
                console.log("CalendarService: Loading current month...")
                loadCurrentMonth()
            } else {
                console.warn("CalendarService: EDS services not available, exit code:", exitCode)
            }
        }
    }

    Process {
        id: goaCheckProcess

        command: ["bash", "-c", "systemctl --user is-active goa-daemon.service || pgrep -f goa-daemon"]
        running: false
        onExited: exitCode => {
            root.goaAvailable = (exitCode === 0)
            if (exitCode !== 0) {
                console.warn("GOA daemon not running, calendar accounts may not sync")
            }
        }
    }


    Process {
        id: createEventProcess
        
        property string eventData: ""
        
        command: ["bash", "-c", `
            # Create event in system calendar
            echo "DEBUG: Creating event with data: ${eventData}" >&2
            
            # First open the calendar
            CALENDAR_INFO=$(gdbus call --session \\
                --dest org.gnome.evolution.dataserver.Calendar8 \\
                --object-path /org/gnome/evolution/dataserver/CalendarFactory \\
                --method org.gnome.evolution.dataserver.CalendarFactory.OpenCalendar \\
                "system-calendar" 2>/dev/null)
            
            if [ -n "$CALENDAR_INFO" ]; then
                OBJECT_PATH=$(echo "$CALENDAR_INFO" | grep -o "'/[^']*'" | head -1 | tr -d "'")
                BUS_NAME=$(echo "$CALENDAR_INFO" | grep -o "'org\\.gnome\\.evolution\\.dataserver\\.Calendar[0-9]*'" | tr -d "'")
                
                echo "DEBUG: Creating event on $BUS_NAME at $OBJECT_PATH" >&2
                
                # CreateObjects expects an array of iCalendar strings
                gdbus call --session \\
                    --dest "$BUS_NAME" \\
                    --object-path "$OBJECT_PATH" \\
                    --method org.gnome.evolution.dataserver.Calendar.CreateObjects \\
                    "['${eventData}']" \\
                    "0"
            else
                echo "DEBUG: Failed to open calendar for event creation" >&2
                exit 1
            fi
        `]
        running: false
        onExited: exitCode => {
            if (exitCode === 0) {
                refreshCalendars()
            }
        }
    }

    Process {
        id: goaListProcess
        
        command: ["bash", "-c", `
            # List GOA accounts
            gdbus call --session \\
                --dest org.gnome.OnlineAccounts \\
                --object-path /org/gnome/OnlineAccounts/Manager \\
                --method org.freedesktop.DBus.ObjectManager.GetManagedObjects 2>/dev/null | \\
            python3 -c "
import sys
import json
import re

try:
    input_data = sys.stdin.read()
    accounts = []
    
    # Extract account information from D-Bus output
    account_blocks = re.findall(r'/org/gnome/OnlineAccounts/Accounts/[^}]+', input_data)
    
    for block in account_blocks:
        if 'Calendar' in block:
            account = {}
            if 'ProviderType' in block:
                provider_match = re.search(r'ProviderType.*?[\"']([^\"']+)', block)
                if provider_match:
                    account['provider'] = provider_match.group(1)
            
            if 'PresentationIdentity' in block:
                identity_match = re.search(r'PresentationIdentity.*?[\"']([^\"']+)', block)
                if identity_match:
                    account['identity'] = identity_match.group(1)
            
            if account:
                accounts.append(account)
    
    print(json.dumps(accounts))
except:
    print('[]')
"
        `]
        running: false
        onExited: exitCode => {
            if (exitCode === 0) {
                try {
                    let accounts = JSON.parse(goaListProcess.output)
                } catch (e) {
                    // Ignore parsing errors
                }
            }
        }
        
        property string output: ""
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                goaListProcess.output += data + "\n"
            }
        }
    }

    // File-based calendar loading Process
    Process {
        id: fileLoadProcess
        property var calendarSource
        property int totalSources
        property string calendarOutput: ""
        
        command: calendarSource ? ["cat", calendarSource.filePath] : ["echo", "No file path"]
        running: false
        
        function start() {
            if (!running && calendarSource && calendarSource.filePath) {
                calendarOutput = ""
                running = true
            }
        }
        
        onExited: exitCode => {
            handleCalendarCompletion(calendarSource, calendarOutput, exitCode, totalSources)
        }
        
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                fileLoadProcess.calendarOutput += data + "\n"
            }
        }
    }

    // Direct D-Bus Process for discovered calendars
    Process {
        id: directDBusProcess
        property var calendarSource
        property int totalSources
        property string calendarOutput: ""
        
        command: ["busctl", "--user", "call", calendarSource ? calendarSource.busName : "", calendarSource ? calendarSource.path : "", "org.gnome.evolution.dataserver.Calendar", "GetObjectList", "s", "#t"]
        running: false
        
        function start() {
            if (!running && calendarSource) {
                calendarOutput = ""
                running = true
            }
        }
        
        onExited: exitCode => {
            if (exitCode === 0) {
                let events = parseDBusCalendarOutput(directDBusProcess.calendarOutput, calendarSource)
                handleCalendarCompletion(calendarSource, events, exitCode, totalSources)
            } else {
                handleCalendarCompletion(calendarSource, [], exitCode, totalSources)
            }
        }
        
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                directDBusProcess.calendarOutput += data + "\n"
            }
        }
    }


    // Calendar completion handler
    property int completedCalendars: 0
    
    function handleCalendarCompletion(source, eventsOrOutput, exitCode, totalSources) {
        if (exitCode === 0) {
            let events = []
            
            // Check if eventsOrOutput is already parsed events (array) or raw output (string)
            if (Array.isArray(eventsOrOutput)) {
                events = eventsOrOutput
            } else if (eventsOrOutput && eventsOrOutput.trim && eventsOrOutput.trim()) {
                // Parse iCalendar events from the raw output  
                events = parseICalendarEvents(eventsOrOutput.trim(), source, root.lastStartDate, root.lastEndDate)
            }
            
            // Add events to allEvents array
            if (events.length > 0) {
                allEvents = allEvents.concat(events)
                console.log("CalendarService: Loaded", events.length, "events from", source.name)
            } else {
                console.log("CalendarService: No events found in", source.name)
            }
        } else {
            console.warn("CalendarService: Failed to load events from", source.name, "exit code:", exitCode)
        }
        
        completedCalendars++
        
        if (completedCalendars >= totalSources) {
            // All calendars completed, update eventsByDate
            updateEventsByDate()
            completedCalendars = 0
            root.isLoading = false
        }
    }

    function updateEventsByDate() {
        let newEventsByDate = {}
        
        for (let event of allEvents) {
            if (!event.start) continue
            
            let startDate = event.start instanceof Date ? event.start : new Date(event.start)
            let endDate = event.end ? (event.end instanceof Date ? event.end : new Date(event.end)) : startDate
            
            let currentDate = new Date(startDate)
            while (currentDate <= endDate) {
                let dateKey = Qt.formatDate(currentDate, "yyyy-MM-dd")
                if (!newEventsByDate[dateKey])
                    newEventsByDate[dateKey] = []
                
                newEventsByDate[dateKey].push(event)
                currentDate.setDate(currentDate.getDate() + 1)
            }
        }
        
        // Sort events by start time for each date
        for (let dateKey in newEventsByDate) {
            newEventsByDate[dateKey].sort((a, b) => {
                let aTime = a.start instanceof Date ? a.start.getTime() : new Date(a.start).getTime()
                let bTime = b.start instanceof Date ? b.start.getTime() : new Date(b.start).getTime()
                return aTime - bTime
            })
        }
        
        root.eventsByDate = newEventsByDate
        root.lastError = ""
        saveToCache(newEventsByDate)
    }
}