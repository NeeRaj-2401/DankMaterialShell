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
    property var calendarSources: ({})
    property bool isLoading: false
    property string lastError: ""
    property date lastStartDate
    property date lastEndDate
    property bool servicesRunning: false
    property var edsServices: ["evolution-source-registry", "evolution-calendar-factory"]
    property int cacheValidityMinutes: 5
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
        if (eventsProcess.running) {
            return
        }
        
        if (isCacheValid(startDate, endDate)) {
            loadFromCache()
            return
        }

        root.lastStartDate = startDate
        root.lastEndDate = endDate
        root.isLoading = true
        
        let startDateStr = Qt.formatDate(startDate, "yyyy-MM-dd")
        let endDateStr = Qt.formatDate(endDate, "yyyy-MM-dd")
        
        eventsProcess.requestStartDate = startDate
        eventsProcess.requestEndDate = endDate
        eventsProcess.command = ["/bin/bash", "-c", 
            `# Load calendar events from Evolution Data Server
CALENDAR_INFO=$(gdbus call --session \\
    --dest org.gnome.evolution.dataserver.Calendar8 \\
    --object-path /org/gnome/evolution/dataserver/CalendarFactory \\
    --method org.gnome.evolution.dataserver.CalendarFactory.OpenCalendar \\
    "system-calendar" 2>/dev/null)

if [ -n "$CALENDAR_INFO" ] && [[ "$CALENDAR_INFO" != *"Error:"* ]]; then
    OBJECT_PATH=$(echo "$CALENDAR_INFO" | grep -o "'/[^']*'" | head -1 | tr -d "'")
    BUS_NAME=$(echo "$CALENDAR_INFO" | grep -o "'org\\.gnome\\.evolution\\.dataserver\\.Calendar[0-9]*'" | tr -d "'")
    
    if [ -n "$OBJECT_PATH" ] && [ -n "$BUS_NAME" ]; then
        EVENTS=$(gdbus call --session \\
            --dest "$BUS_NAME" \\
            --object-path "$OBJECT_PATH" \\
            --method org.gnome.evolution.dataserver.Calendar.GetObjectList \\
            "#t" 2>/dev/null)
        
        if [[ "$EVENTS" != *"@as []"* ]] && [ -n "$EVENTS" ]; then
            export START_DATE="${startDateStr}"
            export END_DATE="${endDateStr}"
            echo "$EVENTS" | go run parse_calendar_events.go
        else
            echo "[]"
        fi
    else
        echo "[]"
    fi
else
    echo "[]"
fi
`]
        eventsProcess.running = true
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
        id: eventsProcess

        property date requestStartDate
        property date requestEndDate
        property string rawOutput: ""

        running: false
        onExited: exitCode => {
            root.isLoading = false
            if (exitCode !== 0) {
                root.lastError = "Failed to load events from EDS (exit code: " + exitCode + ")"
                return
            }
            
            try {
                let newEventsByDate = {}
                let outputLines = eventsProcess.rawOutput.trim().split('\n')
                
                for (let line of outputLines) {
                    line = line.trim()
                    if (!line || line === "[]" || line === "")
                        continue

                    let events = JSON.parse(line)
                    if (!Array.isArray(events))
                        continue

                    for (let event of events) {
                        if (!event.id || !event.title)
                            continue

                        let startDate = parseEventDate(event.start)
                        let endDate = parseEventDate(event.end) || startDate
                        
                        let eventTemplate = {
                            "id": event.id,
                            "title": event.title || "Untitled Event",
                            "start": startDate,
                            "end": endDate,
                            "location": event.location || "",
                            "description": event.description || "",
                            "url": event.url || "",
                            "calendar": event.calendar || "Default",
                            "color": event.color || "#1976d2",
                            "allDay": event.allDay || false,
                            "isMultiDay": startDate.toDateString() !== endDate.toDateString()
                        }

                        let currentDate = new Date(startDate)
                        while (currentDate <= endDate) {
                            let dateKey = Qt.formatDate(currentDate, "yyyy-MM-dd")
                            if (!newEventsByDate[dateKey])
                                newEventsByDate[dateKey] = []

                            let existingEvent = newEventsByDate[dateKey].find(e => e.id === event.id)
                            if (!existingEvent) {
                                let dayEvent = Object.assign({}, eventTemplate)
                                
                                if (currentDate.getTime() === startDate.getTime()) {
                                    dayEvent.start = new Date(startDate)
                                } else {
                                    dayEvent.start = new Date(currentDate)
                                    if (!dayEvent.allDay)
                                        dayEvent.start.setHours(0, 0, 0, 0)
                                }
                                
                                if (currentDate.getTime() === endDate.getTime()) {
                                    dayEvent.end = new Date(endDate)
                                } else {
                                    dayEvent.end = new Date(currentDate)
                                    if (!dayEvent.allDay)
                                        dayEvent.end.setHours(23, 59, 59, 999)
                                }
                                
                                newEventsByDate[dateKey].push(dayEvent)
                            }
                            
                            currentDate.setDate(currentDate.getDate() + 1)
                        }
                    }
                }

                for (let dateKey in newEventsByDate) {
                    newEventsByDate[dateKey].sort((a, b) => {
                        return a.start.getTime() - b.start.getTime()
                    })
                }
                
                root.eventsByDate = newEventsByDate
                root.lastError = ""
                saveToCache(newEventsByDate)
                
            } catch (error) {
                root.lastError = "Failed to parse EDS events: " + error.toString()
                root.eventsByDate = {}
            }
            
            eventsProcess.rawOutput = ""
        }

        function parseEventDate(dateStr) {
            if (!dateStr) return new Date()
            
            if (dateStr instanceof Date) return dateStr
            
            if (typeof dateStr === 'string') {
                if (dateStr.includes('T')) {
                    return new Date(dateStr)
                } else {
                    let parts = dateStr.split('-')
                    if (parts.length === 3) {
                        return new Date(parseInt(parts[0]), parseInt(parts[1]) - 1, parseInt(parts[2]))
                    }
                }
            }
            
            return new Date()
        }

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                eventsProcess.rawOutput += data + "\n"
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
}