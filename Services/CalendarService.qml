pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property bool edsAvailable: false
    property bool goaAvailable: false
    property var eventsByDate: ({})
    property var allEvents: []
    property bool isLoading: false
    property bool servicesRunning: false
    property date lastStartDate
    property date lastEndDate
    property string lastError: ""
    property int cacheValidityMinutes: 5
    // Calendar sources configuration
    property var calendarSources: [
        {
            id: "system-calendar",
            name: "Local",
            color: "#62a0ea",
            enabled: true
        }
        // TODO: Add Google calendar sources when available
        // These source IDs may need to be discovered dynamically
        // {
        //     id: "bb18426cbf2c6dec9c5691191557fad1122debc3",
        //     name: "Personal", 
        //     color: "#9fe1e7",
        //     enabled: false
        // },
        // {
        //     id: "66e623f01943debd6827e4ea9a25d1f112f523d0",
        //     name: "Family",
        //     color: "#f691b2", 
        //     enabled: false
        // },
        // {
        //     id: "514c4961780c62c58972878514eede7eeb15fe36",
        //     name: "Holidays",
        //     color: "#42d692",
        //     enabled: false
        // }
    ]

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
            
            // Parse lines in the VEVENT block
            let lines = veventBlock.split(/\r?\n/)
            for (let line of lines) {
                line = line.trim()
                if (!line.includes(':')) continue
                
                let colonIndex = line.indexOf(':')
                let key = line.substring(0, colonIndex).toUpperCase()
                let value = line.substring(colonIndex + 1)
                
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
                        event.start = parseDateString(value)
                        event.allDay = line.includes(";VALUE=DATE:")
                        break
                    case key.startsWith("DTEND"):
                        event.end = parseDateString(value)
                        break
                }
            }
            
            // Only include events with title and within date range
            if (event.title && event.start && isEventInDateRange(event.start, event.end, startDate, endDate)) {
                events.push(event)
            }
        }
        
        return events
    }

    function isEventInDateRange(eventStart, eventEnd, rangeStart, rangeEnd) {
        if (!eventStart) return false
        
        try {
            let startMs = eventStart
            let endMs = eventEnd || startMs
            let rangeStartMs = rangeStart.getTime()
            let rangeEndMs = rangeEnd.getTime()
            
            return startMs <= rangeEndMs && endMs >= rangeStartMs
        } catch (e) {
            console.warn("CalendarService: Date parsing error:", e)
            return true
        }
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
        if (!root.edsAvailable || !root.servicesRunning) {
            return
        }
        if (root.isLoading) {
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
            
            if (source.id === "system-calendar") {
                // Store source info for the completion handler
                localCalendarProcess.calendarSource = source
                localCalendarProcess.totalSources = totalEnabledSources
                
                // Start the D-Bus call for this calendar
                localCalendarProcess.start()
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
        ensureServicesRunning()
        checkEDSAvailability()
        checkGOAAvailability()
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
            if (exitCode === 0) {
                root.servicesRunning = true
                loadCurrentMonth()
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

    // Individual calendar Process components
    Process {
        id: localCalendarProcess
        property var calendarSource
        property int totalSources
        property string calendarOutput: ""
        
        command: ["bash", "-c", `
            # Open system-calendar and get objects
            CALENDAR_INFO=$(gdbus call --session \\
                --dest org.gnome.evolution.dataserver.Calendar8 \\
                --object-path /org/gnome/evolution/dataserver/CalendarFactory \\
                --method org.gnome.evolution.dataserver.CalendarFactory.OpenCalendar \\
                "system-calendar" 2>/dev/null)
            
            if [ -n "$CALENDAR_INFO" ]; then
                OBJECT_PATH=$(echo "$CALENDAR_INFO" | grep -o "'/[^']*'" | head -1 | tr -d "'")
                BUS_NAME=$(echo "$CALENDAR_INFO" | grep -o "'org\\.gnome\\.evolution\\.dataserver\\.Calendar[0-9]*'" | tr -d "'")
                
                # Get object list from the calendar
                gdbus call --session \\
                    --dest "$BUS_NAME" \\
                    --object-path "$OBJECT_PATH" \\
                    --method org.gnome.evolution.dataserver.Calendar.GetObjectList \\
                    "#t" 2>/dev/null | \\
                python3 -c "
import sys, re
output = sys.stdin.read()
if 'BEGIN:VCALENDAR' in output:
    # Extract just the iCalendar content from D-Bus tuple output
    matches = re.findall(r'(BEGIN:VCALENDAR.*?END:VCALENDAR)', output, re.DOTALL)
    for match in matches:
        print(match)
elif output.strip():
    print(output.strip())
"
            fi
        `]
        running: false
        
        function start() {
            if (!running) {
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
                localCalendarProcess.calendarOutput += data + "\n"
            }
        }
    }

    Process {
        id: personalCalendarProcess
        property var calendarSource
        property int totalSources
        property string calendarOutput: ""
        
        command: ["bash", "-c", `
            # Open personal Google calendar
            CALENDAR_INFO=$(gdbus call --session \\
                --dest org.gnome.evolution.dataserver.Calendar8 \\
                --object-path /org/gnome/evolution/dataserver/CalendarFactory \\
                --method org.gnome.evolution.dataserver.CalendarFactory.OpenCalendar \\
                "bb18426cbf2c6dec9c5691191557fad1122debc3" 2>/dev/null)
            
            if [ -n "$CALENDAR_INFO" ]; then
                OBJECT_PATH=$(echo "$CALENDAR_INFO" | grep -o "'/[^']*'" | head -1 | tr -d "'")
                BUS_NAME=$(echo "$CALENDAR_INFO" | grep -o "'org\\.gnome\\.evolution\\.dataserver\\.Calendar[0-9]*'" | tr -d "'")
                
                # Get object list from the calendar
                gdbus call --session \\
                    --dest "$BUS_NAME" \\
                    --object-path "$OBJECT_PATH" \\
                    --method org.gnome.evolution.dataserver.Calendar.GetObjectList \\
                    "#t" 2>/dev/null | \\
                python3 -c "
import sys, re
output = sys.stdin.read()
if 'BEGIN:VCALENDAR' in output:
    # Extract just the iCalendar content from D-Bus tuple output
    matches = re.findall(r'(BEGIN:VCALENDAR.*?END:VCALENDAR)', output, re.DOTALL)
    for match in matches:
        print(match)
elif output.strip():
    print(output.strip())
"
            fi
        `]
        running: false
        
        function start() {
            if (!running) {
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
                personalCalendarProcess.calendarOutput += data + "\n"
            }
        }
    }

    Process {
        id: familyCalendarProcess
        property var calendarSource
        property int totalSources
        property string calendarOutput: ""
        
        command: ["bash", "-c", `
            # Open family Google calendar
            CALENDAR_INFO=$(gdbus call --session \\
                --dest org.gnome.evolution.dataserver.Calendar8 \\
                --object-path /org/gnome/evolution/dataserver/CalendarFactory \\
                --method org.gnome.evolution.dataserver.CalendarFactory.OpenCalendar \\
                "66e623f01943debd6827e4ea9a25d1f112f523d0" 2>/dev/null)
            
            if [ -n "$CALENDAR_INFO" ]; then
                OBJECT_PATH=$(echo "$CALENDAR_INFO" | grep -o "'/[^']*'" | head -1 | tr -d "'")
                BUS_NAME=$(echo "$CALENDAR_INFO" | grep -o "'org\\.gnome\\.evolution\\.dataserver\\.Calendar[0-9]*'" | tr -d "'")
                
                # Get object list from the calendar
                gdbus call --session \\
                    --dest "$BUS_NAME" \\
                    --object-path "$OBJECT_PATH" \\
                    --method org.gnome.evolution.dataserver.Calendar.GetObjectList \\
                    "#t" 2>/dev/null | \\
                python3 -c "
import sys, re
output = sys.stdin.read()
if 'BEGIN:VCALENDAR' in output:
    # Extract just the iCalendar content from D-Bus tuple output
    matches = re.findall(r'(BEGIN:VCALENDAR.*?END:VCALENDAR)', output, re.DOTALL)
    for match in matches:
        print(match)
elif output.strip():
    print(output.strip())
"
            fi
        `]
        running: false
        
        function start() {
            if (!running) {
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
                familyCalendarProcess.calendarOutput += data + "\n"
            }
        }
    }

    Process {
        id: holidaysCalendarProcess
        property var calendarSource
        property int totalSources
        property string calendarOutput: ""
        
        command: ["bash", "-c", `
            # Open holidays Google calendar
            CALENDAR_INFO=$(gdbus call --session \\
                --dest org.gnome.evolution.dataserver.Calendar8 \\
                --object-path /org/gnome/evolution/dataserver/CalendarFactory \\
                --method org.gnome.evolution.dataserver.CalendarFactory.OpenCalendar \\
                "514c4961780c62c58972878514eede7eeb15fe36" 2>/dev/null)
            
            if [ -n "$CALENDAR_INFO" ]; then
                OBJECT_PATH=$(echo "$CALENDAR_INFO" | grep -o "'/[^']*'" | head -1 | tr -d "'")
                BUS_NAME=$(echo "$CALENDAR_INFO" | grep -o "'org\\.gnome\\.evolution\\.dataserver\\.Calendar[0-9]*'" | tr -d "'")
                
                # Get object list from the calendar
                gdbus call --session \\
                    --dest "$BUS_NAME" \\
                    --object-path "$OBJECT_PATH" \\
                    --method org.gnome.evolution.dataserver.Calendar.GetObjectList \\
                    "#t" 2>/dev/null | \\
                python3 -c "
import sys, re
output = sys.stdin.read()
if 'BEGIN:VCALENDAR' in output:
    # Extract just the iCalendar content from D-Bus tuple output
    matches = re.findall(r'(BEGIN:VCALENDAR.*?END:VCALENDAR)', output, re.DOTALL)
    for match in matches:
        print(match)
elif output.strip():
    print(output.strip())
"
            fi
        `]
        running: false
        
        function start() {
            if (!running) {
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
                holidaysCalendarProcess.calendarOutput += data + "\n"
            }
        }
    }

    // Calendar completion handler
    property int completedCalendars: 0
    
    function handleCalendarCompletion(source, output, exitCode, totalSources) {
        if (exitCode === 0) {
            if (output && output.trim()) {
                // Parse iCalendar events from the raw output
                let events = parseICalendarEvents(output.trim(), source, root.lastStartDate, root.lastEndDate)
                
                // Add events to allEvents array
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
            
            let startDate = new Date(event.start)
            let endDate = event.end ? new Date(event.end) : startDate
            
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
                let aTime = new Date(a.start).getTime()
                let bTime = new Date(b.start).getTime()
                return aTime - bTime
            })
        }
        
        root.eventsByDate = newEventsByDate
        root.lastError = ""
        saveToCache(newEventsByDate)
    }
}