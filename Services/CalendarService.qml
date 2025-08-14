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

    function parseEDSDBusOutput(dbusOutput, calendarSource) {
        let events = []
        
        if (!dbusOutput || !dbusOutput.includes("BEGIN:VEVENT")) {
            return events
        }
        
        try {
            // Parse the D-Bus array output format from EDS GetObjectList
            // Expected format: ['array', ["icalendar_string1", "icalendar_string2", ...]]
            let icalMatches = dbusOutput.match(/"(BEGIN:VCALENDAR[\s\S]*?END:VCALENDAR)"/g)
            if (icalMatches) {
                for (let match of icalMatches) {
                    // Clean up the iCalendar string
                    let icalString = match.substring(1, match.length - 1) // Remove quotes
                    icalString = icalString.replace(/\n/g, '\n').replace(/\n/g, '\n').replace(/"/g, '"')
                    
                    if (icalString.includes("BEGIN:VEVENT")) {
                        let eventEvents = parseICalendarEvents(icalString, calendarSource, root.lastStartDate, root.lastEndDate)
                        events = events.concat(eventEvents)
                    }
                }
            }
        } catch (error) {
            console.warn("CalendarService: Error parsing D-Bus calendar output:", error)
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
        console.log("CalendarService: ensureServicesRunning() called")
        if (!servicesStartProcess.running) {
            console.log("CalendarService: Starting servicesStartProcess")
            servicesStartProcess.running = true
        }
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
            
            if (source.method === "eds_dbus") {
                // Load via EDS D-Bus interface
                edsDBusProcess.calendarSource = source
                edsDBusProcess.totalSources = totalEnabledSources
                edsDBusProcess.startDate = startDate
                edsDBusProcess.endDate = endDate
                edsDBusProcess.start()
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
        console.log("CalendarService: *** DEBUG hasEventsForDate called for", Qt.formatDate(date, "yyyy-MM-dd"), "- found", events.length, "events")
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
        console.log("CalendarService: Component completed, starting initialization")
        console.log("CalendarService: *** CALENDAR SERVICE DEBUG: COMPONENT LOADED ***")
        console.log("CalendarService: Initial state - edsAvailable:", edsAvailable, "servicesRunning:", servicesRunning)
        // Ensure EDS services are available first
        console.log("CalendarService: About to call ensureServicesRunning()")
        ensureServicesRunning()
    }
    
    function discoverCalendars() {
        // Discover available calendar sources via D-Bus
        console.log("CalendarService: Starting calendar discovery")
        calendarDiscoveryProcess.running = true
    }
    

    Process {
        id: calendarDiscoveryProcess
        
        command: ["gdbus", "call", "--session", "--dest", "org.gnome.evolution.dataserver.Sources5", 
                  "--object-path", "/org/gnome/evolution/dataserver/SourceManager",
                  "--method", "org.freedesktop.DBus.ObjectManager.GetManagedObjects"]
        running: false
        
        stdout: StdioCollector {
            onStreamFinished: {
                console.log("CalendarService: Discovery process completed, text length:", text.length)
                parseEDSSources(text)
            }
        }
        
        onExited: exitCode => {
            if (exitCode !== 0) {
                console.warn("CalendarService: Failed to discover calendars, exit code:", exitCode)
                // Try to ensure services are running first
                ensureServicesRunning()
            }
        }
    }
    
    function parseEDSSources(dbusOutput) {
        let sources = []
        let processedUIDs = new Set()  // Track processed UIDs to avoid duplicates
        console.log("CalendarService: Starting to parse EDS sources")
        console.log("CalendarService: D-Bus output length:", dbusOutput.length)
        
        try {
            // Parse D-Bus output to extract calendar sources - improved regex for complex structure
            let sourcePattern = /'UID':\s*<'([^']+)'>,\s*'Data':\s*<'([^']+(?:\\.[^']*)*)'>/g
            let match
            
            while ((match = sourcePattern.exec(dbusOutput)) !== null) {
                let uid = match[1]
                let rawData = match[2]
                
                // Unescape the data properly - handle multiple levels of escaping
                let data = rawData.replace(/\\n/g, '\n').replace(/\\\\n/g, '\n').replace(/\\'/g, "'")
                
                console.log("CalendarService: Processing source", uid)
                
                // Check if this is a calendar source (has [Calendar] section)
                let hasCalendarSection = data.includes('[Calendar]')
                let hasTaskListSection = data.includes('[Task List]')
                
                // Skip if this is not a calendar or if it's a task list
                if (!hasCalendarSection) {
                    // Special case for system calendars and birthdays
                    if (uid !== 'system-calendar' && uid !== 'birthdays') {
                        console.log("CalendarService: Skipping non-calendar source:", uid)
                        continue
                    }
                }
                
                // Explicitly skip task list entries
                if (hasTaskListSection) {
                    console.log("CalendarService: Skipping task list:", uid)
                    continue
                }
                
                // Skip duplicates based on UID
                if (processedUIDs.has(uid)) {
                    console.log("CalendarService: Skipping duplicate UID:", uid)
                    continue
                }
                processedUIDs.add(uid)
                
                // Parse DisplayName from INI-style data
                let displayName = uid // fallback
                
                // Find DisplayName= in the data - look in [Data Source] section first
                let lines = data.split('\n')
                let inDataSourceSection = false
                
                for (let line of lines) {
                    line = line.trim()
                    
                    if (line === '[Data Source]') {
                        inDataSourceSection = true
                        continue
                    } else if (line.startsWith('[') && line.endsWith(']') && line !== '[Data Source]') {
                        inDataSourceSection = false
                        continue
                    }
                    
                    if (inDataSourceSection && line.startsWith('DisplayName=')) {
                        displayName = line.substring(12).trim()
                        break
                    }
                }
                
                // If no DisplayName found in [Data Source], try WebDAV Backend section for cloud calendars
                if (displayName === uid && data.includes('[WebDAV Backend]')) {
                    let webdavMatch = data.match(/\[WebDAV Backend\][^[]*DisplayName=([^\n]+)/);
                    if (webdavMatch) {
                        displayName = webdavMatch[1].trim()
                    }
                }
                
                console.log("CalendarService: Found calendar", uid, "with name", displayName)
                
                // Check if calendar is enabled
                let enabled = true
                let enabledMatch = data.match(/Enabled=(true|false)/)
                if (enabledMatch && enabledMatch[1] === 'false') {
                    console.log("CalendarService: Skipping disabled calendar:", displayName)
                    continue
                }
                
                // Skip known problematic calendars that often fail (but keep holidays for now)
                // if (displayName.includes('Holidays') || uid.includes('holiday')) {
                //     console.log("CalendarService: Skipping potentially problematic holiday calendar:", displayName)
                //     continue
                // }
                
                // Determine calendar color if available
                let color = '#62a0ea' // default blue
                
                // Try to find color in [Calendar] section
                let calendarSectionMatch = data.match(/\[Calendar\][^[]*Color=([^\\n\s]+)/);
                if (calendarSectionMatch) {
                    color = calendarSectionMatch[1].trim()
                } else {
                    // Try WebDAV Backend section for cloud calendars
                    let webdavColorMatch = data.match(/\[WebDAV Backend\][^[]*Color=([^\\n\s]+)/);
                    if (webdavColorMatch) {
                        color = webdavColorMatch[1].trim()
                    }
                }
                
                // Check backend type
                let backend = 'local'
                if (data.includes('BackendName=caldav')) {
                    backend = 'caldav'
                } else if (data.includes('BackendName=microsoft365')) {
                    backend = 'microsoft365'
                } else if (data.includes('BackendName=google')) {
                    backend = 'google'
                } else if (data.includes('BackendName=local')) {
                    backend = 'local'
                } else if (data.includes('BackendName=contacts')) {
                    backend = 'contacts'
                }
                
                // Check connection status
                let connectionStatus = 'unknown'
                let connectionMatch = data.match(/'ConnectionStatus':\s*<'([^']*)'>/);
                if (connectionMatch) {
                    connectionStatus = connectionMatch[1]
                }
                
                sources.push({
                    uid: uid,
                    name: displayName,
                    id: displayName,
                    color: color,
                    backend: backend,
                    enabled: enabled,
                    method: "eds_dbus"
                })
            }
            
            console.log("CalendarService: Discovered", sources.length, "calendar sources:")
            for (let source of sources) {
                console.log("  -", source.name, "(", source.uid, ") backend:", source.backend, "enabled:", source.enabled)
            }
            
            // Set discovered sources
            root.calendarSources = sources
            root.calendarDiscoveryCompleted = true
            root.edsAvailable = sources.length > 0
            root.servicesRunning = sources.length > 0
            root.initialized = true
            
            // Load events from discovered calendars
            if (sources.length > 0) {
                console.log("CalendarService: Starting to load events from", sources.length, "calendars")
                loadCurrentMonth()
            } else {
                console.log("CalendarService: No calendars discovered, no events to load")
            }
            
        } catch (error) {
            console.warn("CalendarService: Error parsing EDS sources:", error)
            root.edsAvailable = false
            root.servicesRunning = false
            root.initialized = true
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
            console.log("CalendarService: Service start process exited with code:", exitCode)
            if (exitCode === 0) {
                console.log("CalendarService: EDS services started successfully")
                // Services are now running, set flags and discover calendars
                root.servicesRunning = true
                root.edsAvailable = true
                root.initialized = true
                discoverCalendars()
            } else {
                console.warn("CalendarService: Failed to start EDS services:", exitCode)
                // Try to check if they're already running
                checkEDSAvailability()
            }
        }
    }

    Timer {
        id: serviceInitTimer
        interval: 1000
        repeat: false
        onTriggered: discoverCalendars()
    }

    Process {
        id: edsCheckProcess

        command: ["bash", "-c", "systemctl --user is-active evolution-source-registry.service && systemctl --user is-active evolution-calendar-factory.service"]
        running: false
        onExited: exitCode => {
            console.log("CalendarService: EDS check completed with exit code:", exitCode)
            if (exitCode === 0) {
                console.log("CalendarService: EDS services are running, starting discovery")
                root.edsAvailable = true
                root.servicesRunning = true
                root.initialized = true
                discoverCalendars()
            } else {
                console.log("CalendarService: EDS services not detected, trying to start them")
                ensureServicesRunning()
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

    // EDS D-Bus Process for calendar sources  
    Process {
        id: edsDBusProcess
        property var calendarSource
        property int totalSources
        property date startDate
        property date endDate 
        
        running: false
        
        function start() {
            if (!running && calendarSource) {
                // First get the calendar bus name
                getCalendarBus.running = true
            }
        }
    }
    
    Process {
        id: getCalendarBus
        command: ["busctl", "--user", "list", "--no-pager"]
        running: false
        
        stdout: StdioCollector {
            onStreamFinished: {
                let calendarBus = ""
                let lines = text.split('\n')
                for (let line of lines) {
                    if (line.includes('org.gnome.evolution.dataserver.Calendar')) {
                        let parts = line.split(/\s+/)
                        if (parts[0] && parts[0].includes('Calendar')) {
                            calendarBus = parts[0]
                            break
                        }
                    }
                }
                
                if (calendarBus) {
                    openCalendar.calendarBus = calendarBus
                    openCalendar.running = true
                } else {
                    console.warn("CalendarService: No calendar bus found")
                    handleCalendarCompletion(edsDBusProcess.calendarSource, [], 1, edsDBusProcess.totalSources)
                }
            }
        }
    }
    
    Process {
        id: openCalendar
        property string calendarBus: ""
        running: false
        
        command: calendarBus ? 
            ["gdbus", "call", "--session", "--dest", calendarBus,
             "--object-path", "/org/gnome/evolution/dataserver/CalendarFactory",
             "--method", "org.gnome.evolution.dataserver.CalendarFactory.OpenCalendar",
             edsDBusProcess.calendarSource ? edsDBusProcess.calendarSource.uid : ""] : []
        
        stdout: StdioCollector {
            onStreamFinished: {
                // Parse the calendar info response
                // Expected format: ('/path/to/calendar', 'bus.name.Calendar8')
                let objectPathMatch = text.match(/\('([^']+)',/)
                let busNameMatch = text.match(/, '([^']*Calendar[0-9]*)'/)  
                
                if (objectPathMatch && busNameMatch) {
                    let objectPath = objectPathMatch[1]
                    let busName = busNameMatch[1]
                    
                    console.log("CalendarService: Opened calendar", edsDBusProcess.calendarSource?.name, "with path:", objectPath, "bus:", busName)
                    
                    if (objectPath !== '/' && busName) {
                        getCalendarEvents.objectPath = objectPath
                        getCalendarEvents.busName = busName
                        getCalendarEvents.running = true
                    } else {
                        console.warn("CalendarService: Invalid calendar paths for", edsDBusProcess.calendarSource ? edsDBusProcess.calendarSource.name : "unknown")
                        handleCalendarCompletion(edsDBusProcess.calendarSource, [], 1, edsDBusProcess.totalSources)
                    }
                } else {
                    console.warn("CalendarService: Failed to parse calendar info for", edsDBusProcess.calendarSource ? edsDBusProcess.calendarSource.name : "unknown", "- response:", text.trim())
                    handleCalendarCompletion(edsDBusProcess.calendarSource, [], 1, edsDBusProcess.totalSources)
                }
            }
        }
        
        onExited: exitCode => {
            if (exitCode !== 0) {
                console.warn("CalendarService: Failed to open calendar", edsDBusProcess.calendarSource ? edsDBusProcess.calendarSource.name : "unknown")
                handleCalendarCompletion(edsDBusProcess.calendarSource, [], exitCode, edsDBusProcess.totalSources)
            }
        }
    }
    
    Process {
        id: getCalendarEvents
        property string objectPath: ""
        property string busName: ""
        running: false
        
        command: {
            if (!objectPath || !busName) return []
            
            // Create date range query using S-expressions
            // Use ISO string format and extract date parts more reliably
            let startDate = edsDBusProcess.startDate || new Date(2025, 0, 1) // Jan 1, 2025
            let endDate = edsDBusProcess.endDate || new Date(2025, 11, 31)   // Dec 31, 2025
            
            let startYear = startDate.getFullYear()
            let startMonth = startDate.getMonth() + 1
            let startDay = startDate.getDate()
            let startDateStr = startYear + 
                              (startMonth < 10 ? "0" + startMonth : startMonth) + 
                              (startDay < 10 ? "0" + startDay : startDay) + "T000000Z"
            
            let endYear = endDate.getFullYear()
            let endMonth = endDate.getMonth() + 1
            let endDay = endDate.getDate()
            let endDateStr = endYear + 
                            (endMonth < 10 ? "0" + endMonth : endMonth) + 
                            (endDay < 10 ? "0" + endDay : endDay) + "T235959Z"
            
            let query = `(occur-in-time-range? (make-time "${startDateStr}") (make-time "${endDateStr}"))`
            
            console.log("CalendarService: Querying calendar", edsDBusProcess.calendarSource?.name, "from", startDateStr, "to", endDateStr)
            
            return ["gdbus", "call", "--session", "--dest", busName,
                    "--object-path", objectPath,
                    "--method", "org.gnome.evolution.dataserver.Calendar.GetObjectList",
                    query]
        }
        
        stdout: StdioCollector {
            onStreamFinished: {
                let events = parseEDSDBusOutput(text, edsDBusProcess.calendarSource)
                handleCalendarCompletion(edsDBusProcess.calendarSource, events, 0, edsDBusProcess.totalSources)
            }
        }
        
        onExited: exitCode => {
            if (exitCode !== 0) {
                console.warn("CalendarService: Failed to get events from", edsDBusProcess.calendarSource ? edsDBusProcess.calendarSource.name : "unknown")
                handleCalendarCompletion(edsDBusProcess.calendarSource, [], exitCode, edsDBusProcess.totalSources)
            }
        }
    }


    // Calendar completion handler
    property int completedCalendars: 0
    
    function handleCalendarCompletion(source, eventsOrOutput, exitCode, totalSources) {
        console.log("CalendarService: handleCalendarCompletion called for", source ? source.name : "unknown", "exitCode:", exitCode)
        
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
            console.warn("CalendarService: Failed to load events from", source ? source.name : "unknown", "exit code:", exitCode, "- continuing with other calendars")
        }
        
        completedCalendars++
        console.log("CalendarService: Completed", completedCalendars, "of", totalSources, "calendars")
        
        if (completedCalendars >= totalSources) {
            // All calendars completed, update eventsByDate
            console.log("CalendarService: All calendars processed, updating events by date with", allEvents.length, "total events")
            updateEventsByDate()
            completedCalendars = 0
            root.isLoading = false
        }
    }

    function updateEventsByDate() {
        let newEventsByDate = {}
        
        console.log("CalendarService: updateEventsByDate called with", allEvents.length, "total events")
        for (let i = 0; i < Math.min(5, allEvents.length); i++) {
            console.log("  Event", i + ":", allEvents[i].title, "on", allEvents[i].start, "in calendar", allEvents[i].calendar)
        }
        
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