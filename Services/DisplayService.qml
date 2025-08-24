pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common

Singleton {
    id: root

    property bool brightnessAvailable: devices.length > 0
    property var devices: []
    property var ddcDevices: []
    property var deviceBrightness: ({})
    property var ddcPendingInit: ({})
    property string currentDevice: ""
    property string lastIpcDevice: ""
    property bool ddcAvailable: false
    property var ddcInitQueue: []
    property bool skipDdcRead: false
    property int brightnessLevel: {
        const deviceToUse = lastIpcDevice === "" ? getDefaultDevice() : (lastIpcDevice || currentDevice)
        if (!deviceToUse) return 50

        return getDeviceBrightness(deviceToUse)
    }
    property int maxBrightness: 100
    property bool brightnessInitialized: false

    property bool nightModeActive: false
    property bool automationActive: false
    property bool gammaStepAvailable: false
    property bool geoClue2Available: false
    
    property var nightModeTimer: Timer {
        id: nightModeTimer
        interval: 60000 // Check every minute
        running: automationActive && SessionData.nightModeAutoMode === "time"
        repeat: true
        
        onTriggered: {
            updateTimeBasedNightMode()
        }
    }

    signal brightnessChanged
    signal deviceSwitched

    Component.onCompleted: {
        checkDependencies()
        ddcDetectionProcess.running = true
        refreshDevices()
        
        // Only restore night mode states if they were previously enabled by user
        // Don't auto-start anything - let user control activation
    }

    Connections {
        target: SessionData

        function onNightModeAutoEnabledChanged() {
            updateAutomationState()
        }

        function onNightModeAutoModeChanged() {
            updateAutomationState()
        }

        function onNightModeStartTimeChanged() {
            if (SessionData.nightModeAutoMode === "time" && SessionData.nightModeAutoEnabled) {
                restartGammastep()
            }
        }

        function onNightModeEndTimeChanged() {
            if (SessionData.nightModeAutoMode === "time" && SessionData.nightModeAutoEnabled) {
                restartGammastep()
            }
        }

        function onNightModeTemperatureChanged() {
            if (automationActive || nightModeActive) {
                restartGammastep()
            }
        }
    }

    function setBrightnessInternal(percentage, device) {
        const clampedValue = Math.max(1, Math.min(100, percentage))
        const actualDevice = device === "" ? getDefaultDevice() : (device || currentDevice || getDefaultDevice())

        if (actualDevice) {
            var newBrightness = Object.assign({}, deviceBrightness)
            newBrightness[actualDevice] = clampedValue
            deviceBrightness = newBrightness
        }
        
        const deviceInfo = getCurrentDeviceInfoByName(actualDevice)

        if (deviceInfo && deviceInfo.class === "ddc") {
            ddcBrightnessSetProcess.command = ["ddcutil", "setvcp", "-d", String(deviceInfo.ddcDisplay), "10", String(clampedValue)]
            ddcBrightnessSetProcess.running = true
        } else {
            if (device)
                brightnessSetProcess.command = ["brightnessctl", "-d", device, "set", clampedValue + "%"]
            else
                brightnessSetProcess.command = ["brightnessctl", "set", clampedValue + "%"]
            brightnessSetProcess.running = true
        }
    }

    function setBrightness(percentage, device) {
        setBrightnessInternal(percentage, device)
        brightnessChanged()
    }

    function setCurrentDevice(deviceName, saveToSession = false) {
        if (currentDevice === deviceName)
            return

        currentDevice = deviceName
        lastIpcDevice = deviceName

        if (saveToSession) {
            SessionData.setLastBrightnessDevice(deviceName)
        }

        deviceSwitched()

        const deviceInfo = getCurrentDeviceInfoByName(deviceName)
        if (deviceInfo && deviceInfo.class === "ddc") {
            return
        } else {
            brightnessGetProcess.command = ["brightnessctl", "-m", "-d", deviceName, "get"]
            brightnessGetProcess.running = true
        }
    }

    function refreshDevices() {
        deviceListProcess.running = true
    }

    function refreshDevicesInternal() {
        const allDevices = [...devices, ...ddcDevices]

        allDevices.sort((a, b) => {
            if (a.class === "backlight" && b.class !== "backlight")
                return -1
            if (a.class !== "backlight" && b.class === "backlight")
                return 1

            if (a.class === "ddc" && b.class !== "ddc" && b.class !== "backlight")
                return -1
            if (a.class !== "ddc" && b.class === "ddc" && a.class !== "backlight")
                return 1

            return a.name.localeCompare(b.name)
        })

        devices = allDevices

        if (devices.length > 0 && !currentDevice) {
            const lastDevice = SessionData.lastBrightnessDevice || ""
            const deviceExists = devices.some(d => d.name === lastDevice)
            if (deviceExists) {
                setCurrentDevice(lastDevice, false)
            } else {
                const nonKbdDevice = devices.find(d => !d.name.includes("kbd")) || devices[0]
                setCurrentDevice(nonKbdDevice.name, false)
            }
        }
    }

    function getDeviceBrightness(deviceName) {
        if (!deviceName) return 50
        
        const deviceInfo = getCurrentDeviceInfoByName(deviceName)
        if (!deviceInfo) return 50
        
        if (deviceInfo.class === "ddc") {
            return deviceBrightness[deviceName] || 50
        }
        
        return deviceBrightness[deviceName] || deviceInfo.percentage || 50
    }

    function getDefaultDevice() {
        for (const device of devices) {
            if (device.class === "backlight") {
                return device.name
            }
        }
        return devices.length > 0 ? devices[0].name : ""
    }

    function getCurrentDeviceInfo() {
        const deviceToUse = lastIpcDevice === "" ? getDefaultDevice() : (lastIpcDevice || currentDevice)
        if (!deviceToUse)
            return null

        for (const device of devices) {
            if (device.name === deviceToUse) {
                return device
            }
        }
        return null
    }

    function isCurrentDeviceReady() {
        const deviceToUse = lastIpcDevice === "" ? getDefaultDevice() : (lastIpcDevice || currentDevice)
        if (!deviceToUse)
            return false

        if (ddcPendingInit[deviceToUse]) {
            return false
        }

        return true
    }

    function getCurrentDeviceInfoByName(deviceName) {
        if (!deviceName)
            return null

        for (const device of devices) {
            if (device.name === deviceName) {
                return device
            }
        }
        return null
    }

    function processNextDdcInit() {
        if (ddcInitQueue.length === 0 || ddcInitialBrightnessProcess.running) {
            return
        }

        const displayId = ddcInitQueue.shift()
        ddcInitialBrightnessProcess.command = ["ddcutil", "getvcp", "-d", String(displayId), "10", "--brief"]
        ddcInitialBrightnessProcess.running = true
    }

    function checkDependencies() {
        gammaStepDetectionProcess.running = true
    }

    function testGammastepMethods() {
        console.log("DisplayService: Testing gamma adjustment support...")
        gammaTestProcess.running = true
    }
    
    function testGammaRampSupport() {
        console.log("DisplayService: Testing gamma ramp support with -p flag...")
        gammaRampTestProcess.running = true
    }

    function updateAutomationState() {
        if (SessionData.nightModeAutoEnabled && gammaStepAvailable) {
            startGammastepAutomation()
        } else {
            stopGammastepAutomation()
        }
    }

    function startGammastepAutomation() {
        console.log("DisplayService: Starting automation with mode:", SessionData.nightModeAutoMode)
        automationActive = true
        nightModeActive = false
        
        killGammastepProcess.running = true
        Qt.callLater(() => {
            gammaStepProcess.running = true
            
            // For time-based mode, start the timer and do initial update
            if (SessionData.nightModeAutoMode === "time") {
                nightModeTimer.start()
                // Do immediate update
                Qt.callLater(() => {
                    updateTimeBasedNightMode()
                })
            }
        })
        
        console.log("DisplayService: Started gammastep automation with mode:", SessionData.nightModeAutoMode)
    }

    function stopGammastepAutomation() {
        automationActive = false
        nightModeTimer.stop()
        gammaStepProcess.running = false
        killGammastepProcess.running = true
        console.log("DisplayService: Stopped gammastep automation")
    }

    function restartGammastep() {
        if (automationActive || nightModeActive) {
            gammaStepProcess.running = false
            killGammastepProcess.running = true
            Qt.callLater(() => {
                gammaStepProcess.running = true
                
                // For time-based automation, ensure timer is running and do immediate update
                if (automationActive && SessionData.nightModeAutoMode === "time") {
                    if (!nightModeTimer.running) {
                        nightModeTimer.start()
                    }
                    Qt.callLater(() => {
                        updateTimeBasedNightMode()
                    })
                }
            })
        }
    }

    function enableNightMode() {
        if (nightModeActive)
            return

        if (SessionData.nightModeAutoEnabled) {
            console.warn("DisplayService: Night mode automation is active, manual control disabled")
            return
        }

        if (!gammaStepAvailable) {
            console.warn("DisplayService: Gammastep not available")
            return
        }

        console.log("DisplayService: Enabling night mode")
        nightModeActive = true
        SessionData.setNightModeEnabled(true)
    }

    function updateNightModeTemperature(temperature) {
        SessionData.setNightModeTemperature(temperature)

        if (nightModeActive) {
            nightModeActive = false
            Qt.callLater(() => {
                if (SessionData.nightModeEnabled) {
                    nightModeActive = true
                }
            })
        }
    }

    function disableNightMode() {
        if (SessionData.nightModeAutoEnabled) {
            console.warn("DisplayService: Night mode automation is active, manual control disabled")
            return
        }

        nightModeActive = false
        SessionData.setNightModeEnabled(false)

        killGammastepProcess.running = true
    }

    function toggleNightMode() {
        if (nightModeActive) {
            disableNightMode()
        } else {
            enableNightMode()
        }
    }

    function buildGammastepCommand() {
        const temperature = SessionData.nightModeTemperature || 4500
        
        if (automationActive) {
            if (SessionData.nightModeAutoMode === "location") {
                const cmd = ["gammastep", "-m", "randr", "-l", "geoclue2", "-t", `6500:${temperature}`]
                console.log("DisplayService: Building location command:", cmd.join(" "))
                return cmd
            } else if (SessionData.nightModeAutoMode === "time") {
                // For time-based mode, just apply the current temperature based on time
                const shouldBeActive = isNightModeTimeActive()
                const currentTemp = shouldBeActive ? temperature : 6500
                const cmd = ["gammastep", "-m", "randr", "-O", String(currentTemp)]
                console.log("DisplayService: Building time-based command:", cmd.join(" "), "(night time:", shouldBeActive, ")")
                return cmd
            }
        }
        
        const cmd = ["gammastep", "-m", "randr", "-O", String(temperature)]
        console.log("DisplayService: Building manual command:", cmd.join(" "))
        return cmd
    }
    
    function isNightModeTimeActive() {
        const now = new Date()
        const currentTime = now.getHours() * 60 + now.getMinutes() // minutes since midnight
        
        const startTime = SessionData.nightModeStartTime || "20:00"
        const endTime = SessionData.nightModeEndTime || "06:00"
        
        // Parse start time
        const startParts = startTime.split(":")
        const startMinutes = parseInt(startParts[0]) * 60 + parseInt(startParts[1])
        
        // Parse end time  
        const endParts = endTime.split(":")
        const endMinutes = parseInt(endParts[0]) * 60 + parseInt(endParts[1])
        
        // Handle overnight periods (e.g., 20:00 to 06:00)
        if (startMinutes > endMinutes) {
            // Night period crosses midnight
            return currentTime >= startMinutes || currentTime <= endMinutes
        } else {
            // Night period within same day
            return currentTime >= startMinutes && currentTime <= endMinutes
        }
    }
    
    function updateTimeBasedNightMode() {
        if (!automationActive || SessionData.nightModeAutoMode !== "time") {
            return
        }
        
        const shouldBeActive = isNightModeTimeActive()
        const temperature = SessionData.nightModeTemperature || 4500
        const currentTemp = shouldBeActive ? temperature : 6500
        
        console.log("DisplayService: Time-based update - should be active:", shouldBeActive, "temp:", currentTemp)
        
        // Update gammastep with new temperature
        gammaStepProcess.running = false
        killGammastepProcess.running = true
        Qt.callLater(() => {
            gammaStepProcess.running = true
        })
    }

    Process {
        id: killGammastepProcess
        command: ["pkill", "gammastep"]
        running: false
        
        onExited: function(exitCode) {
            console.log("DisplayService: Killed existing gammastep processes")
        }
    }

    Process {
        id: ddcDetectionProcess
        command: ["which", "ddcutil"]
        running: false

        onExited: function (exitCode) {
            ddcAvailable = (exitCode === 0)
            if (ddcAvailable) {
                console.log("DisplayService: ddcutil detected")
                ddcDisplayDetectionProcess.running = true
            } else {
                console.log("DisplayService: ddcutil not available")
            }
        }
    }

    Process {
        id: ddcDisplayDetectionProcess
        command: ["bash", "-c", "ddcutil detect --brief 2>/dev/null | grep '^Display [0-9]' | awk '{print \"{\\\"display\\\":\" $2 \",\\\"name\\\":\\\"ddc-\" $2 \"\\\",\\\"class\\\":\\\"ddc\\\"}\"}' | tr '\\n' ',' | sed 's/,$//' | sed 's/^/[/' | sed 's/$/]/' || echo '[]'"]
        running: false

        stdout: StdioCollector {
            onStreamFinished: {
                if (!text.trim()) {
                    console.log("DisplayService: No DDC displays found")
                    ddcDevices = []
                    return
                }

                try {
                    const parsedDevices = JSON.parse(text.trim())
                    const newDdcDevices = []

                    for (const device of parsedDevices) {
                        if (device.display && device.class === "ddc") {
                            newDdcDevices.push({
                                "name": device.name,
                                "class": "ddc",
                                "current": 50,
                                "percentage": 50,
                                "max": 100,
                                "ddcDisplay": device.display
                            })
                        }
                    }

                    ddcDevices = newDdcDevices
                    console.log("DisplayService: Found", ddcDevices.length, "DDC displays")

                    ddcInitQueue = []
                    for (const device of ddcDevices) {
                        ddcInitQueue.push(device.ddcDisplay)
                        ddcPendingInit[device.name] = true
                    }

                    processNextDdcInit()
                    refreshDevicesInternal()

                    const lastDevice = SessionData.lastBrightnessDevice || ""
                    if (lastDevice) {
                        const deviceExists = devices.some(d => d.name === lastDevice)
                        if (deviceExists && (!currentDevice || currentDevice !== lastDevice)) {
                            setCurrentDevice(lastDevice, false)
                        }
                    }
                } catch (error) {
                    console.warn("DisplayService: Failed to parse DDC devices:", error)
                    ddcDevices = []
                }
            }
        }

        onExited: function (exitCode) {
            if (exitCode !== 0) {
                console.warn("DisplayService: Failed to detect DDC displays:", exitCode)
                ddcDevices = []
            }
        }
    }

    Process {
        id: deviceListProcess
        command: ["brightnessctl", "-m", "-l"]
        
        onExited: function (exitCode) {
            if (exitCode !== 0) {
                console.warn("DisplayService: Failed to list devices:", exitCode)
                brightnessAvailable = false
            }
        }

        stdout: StdioCollector {
            onStreamFinished: {
                if (!text.trim()) {
                    console.warn("DisplayService: No devices found")
                    return
                }
                const lines = text.trim().split("\n")
                const newDevices = []
                for (const line of lines) {
                    const parts = line.split(",")
                    if (parts.length >= 5)
                        newDevices.push({
                            "name": parts[0],
                            "class": parts[1],
                            "current": parseInt(parts[2]),
                            "percentage": parseInt(parts[3]),
                            "max": parseInt(parts[4])
                        })
                }
                
                const brightnessCtlDevices = newDevices
                devices = brightnessCtlDevices

                if (ddcDevices.length > 0) {
                    refreshDevicesInternal()
                } else if (devices.length > 0 && !currentDevice) {
                    const lastDevice = SessionData.lastBrightnessDevice || ""
                    const deviceExists = devices.some(d => d.name === lastDevice)
                    if (deviceExists) {
                        setCurrentDevice(lastDevice, false)
                    } else {
                        const nonKbdDevice = devices.find(d => !d.name.includes("kbd")) || devices[0]
                        setCurrentDevice(nonKbdDevice.name, false)
                    }
                }
            }
        }
    }

    Process {
        id: brightnessSetProcess
        running: false
        
        onExited: function (exitCode) {
            if (exitCode !== 0)
                console.warn("DisplayService: Failed to set brightness:", exitCode)
        }
    }

    Process {
        id: ddcBrightnessSetProcess
        running: false
        
        onExited: function (exitCode) {
            if (exitCode !== 0)
                console.warn("DisplayService: Failed to set DDC brightness:", exitCode)
        }
    }

    Process {
        id: ddcInitialBrightnessProcess
        running: false
        
        onExited: function (exitCode) {
            if (exitCode !== 0)
                console.warn("DisplayService: Failed to get initial DDC brightness:", exitCode)

            processNextDdcInit()
        }

        stdout: StdioCollector {
            onStreamFinished: {
                if (!text.trim())
                    return

                const parts = text.trim().split(" ")
                if (parts.length >= 5) {
                    const current = parseInt(parts[3]) || 50
                    const max = parseInt(parts[4]) || 100
                    const brightness = Math.round((current / max) * 100)

                    const commandParts = ddcInitialBrightnessProcess.command
                    if (commandParts && commandParts.length >= 4) {
                        const displayId = commandParts[3]
                        const deviceName = "ddc-" + displayId

                        var newBrightness = Object.assign({}, deviceBrightness)
                        newBrightness[deviceName] = brightness
                        deviceBrightness = newBrightness

                        var newPending = Object.assign({}, ddcPendingInit)
                        delete newPending[deviceName]
                        ddcPendingInit = newPending

                        console.log("DisplayService: Initial DDC Device", deviceName, "brightness:", brightness + "%")
                    }
                }
            }
        }
    }

    Process {
        id: brightnessGetProcess
        running: false
        
        onExited: function (exitCode) {
            if (exitCode !== 0)
                console.warn("DisplayService: Failed to get brightness:", exitCode)
        }

        stdout: StdioCollector {
            onStreamFinished: {
                if (!text.trim())
                    return

                const parts = text.trim().split(",")
                if (parts.length >= 5) {
                    const current = parseInt(parts[2])
                    const max = parseInt(parts[4])
                    maxBrightness = max
                    const brightness = Math.round((current / max) * 100)

                    if (currentDevice) {
                        var newBrightness = Object.assign({}, deviceBrightness)
                        newBrightness[currentDevice] = brightness
                        deviceBrightness = newBrightness
                    }

                    brightnessInitialized = true
                    console.log("DisplayService: Device", currentDevice, "brightness:", brightness + "%")
                    brightnessChanged()
                }
            }
        }
    }

    Process {
        id: gammaStepDetectionProcess
        command: ["which", "gammastep"]
        running: false

        onExited: function (exitCode) {
            if (exitCode === 0) {
                console.log("DisplayService: gammastep detected, testing compatibility...")
                gammaStepAvailable = true  // Set tentatively, will be updated by tests
                testGammastepMethods()
                geoClue2DetectionProcess.running = true
            } else {
                console.log("DisplayService: gammastep not available")
                gammaStepAvailable = false
                if (typeof ToastService !== "undefined" && ToastService.showWarning) {
                    ToastService.showWarning("Night mode not available\n\nGammastep is not installed")
                }
            }
        }
    }

    Process {
        id: methodTestProcess
        command: ["gammastep", "-m", "list"]
        running: false

        stdout: StdioCollector {
            onStreamFinished: {
                if (text && text.trim()) {
                    console.log("DisplayService: Available methods:", text.trim())
                    const methods = text.toLowerCase()
                    if (methods.includes("randr") || methods.includes("vidmode") || methods.includes("wayland")) {
                        console.log("DisplayService: Found compatible display methods")
                        // Skip gamma ramp test - basic gamma test already passed
                        console.log("DisplayService: Gamma adjustment confirmed working - skipping ramp test")
                        gammaStepAvailable = true
                    } else {
                        console.warn("DisplayService: No compatible display methods found")
                        gammaStepAvailable = false
                        if (typeof ToastService !== "undefined" && ToastService.showWarning) {
                            ToastService.showWarning("Night mode not available\n\nNo compatible display methods found")
                        }
                    }
                }
            }
        }

        stderr: StdioCollector {
            onStreamFinished: {
                if (text && text.trim()) {
                    console.warn("DisplayService: Method test stderr:", text.trim())
                }
            }
        }

        onExited: function (exitCode) {
            if (exitCode !== 0) {
                console.warn("DisplayService: Method test failed, disabling night mode")
                gammaStepAvailable = false
            }
        }
    }
    
    Process {
        id: gammaTestProcess
        command: ["gammastep", "-p", "-O", "6500"]
        running: false
        
        stdout: StdioCollector {
            onStreamFinished: {
                if (text && text.trim()) {
                    console.log("DisplayService: Gamma test output:", text.trim())
                }
            }
        }
        
        stderr: StdioCollector {
            onStreamFinished: {
                if (text && text.trim()) {
                    console.log("DisplayService: Gamma test stderr:", text.trim())
                }
            }
        }
        
        onExited: function (exitCode) {
            if (exitCode === 0) {
                console.log("DisplayService: Gamma adjustment test successful - auto-detect works")
                gammaStepAvailable = true
                methodTestProcess.running = true
            } else {
                console.log("DisplayService: Auto-detect failed, trying specific methods...")
                gammaFallbackTestProcess.running = true
            }
        }
    }
    
    Process {
        id: gammaFallbackTestProcess
        command: ["gammastep", "-m", "randr", "-p", "-O", "6500"]
        running: false
        
        onExited: function (exitCode) {
            if (exitCode === 0) {
                console.log("DisplayService: Gamma adjustment test successful - randr method works")
                gammaStepAvailable = true
                methodTestProcess.running = true
            } else {
                console.warn("DisplayService: All gamma methods failed - gamma adjustment not available")
                gammaStepAvailable = false
                if (typeof ToastService !== "undefined" && ToastService.showWarning) {
                    ToastService.showWarning("Night mode not supported\n\nYour display or graphics driver doesn't support gamma adjustment")
                }
            }
        }
    }
    
    Process {
        id: gammaRampTestProcess
        command: ["gammastep", "-m", "wayland", "-p", "-O", "4000"]
        running: false
        
        stdout: StdioCollector {
            onStreamFinished: {
                if (text && text.trim()) {
                    console.log("DisplayService: Gamma ramp test output:", text.trim())
                    // If we get parameters printed, gamma ramps are supported
                    if (text.includes("4000") || text.includes("Temp") || text.includes("Period")) {
                        console.log("DisplayService: Gamma ramps supported - parameters:", text.trim())
                        gammaStepAvailable = true
                    } else {
                        console.log("DisplayService: Unexpected gamma test output, assuming supported")
                        gammaStepAvailable = true
                    }
                }
            }
        }
        
        stderr: StdioCollector {
            onStreamFinished: {
                if (text && text.trim()) {
                    console.log("DisplayService: Gamma ramp test stderr:", text.trim())
                }
            }
        }
        
        onExited: function (exitCode) {
            if (exitCode === 0) {
                console.log("DisplayService: Gamma ramp test completed successfully")
                gammaStepAvailable = true
            } else {
                console.warn("DisplayService: Gamma ramp test failed with exit code:", exitCode, "but keeping gamma available since basic test passed")
            }
        }
    }

    Process {
        id: geoClue2DetectionProcess
        command: ["bash", "-c", "command -v geoclue-agent >/dev/null 2>&1 || ls /usr/lib*/geoclue* >/dev/null 2>&1 || systemctl --user is-active geoclue-agent >/dev/null 2>&1"]
        running: false

        onExited: function (exitCode) {
            geoClue2Available = (exitCode === 0)
            if (geoClue2Available) {
                console.log("DisplayService: geoclue2 support detected")
            } else {
                console.log("DisplayService: geoclue2 not available - location mode may not work")
            }
        }
    }

    Process {
        id: gammaStepTestProcess
        command: ["which", "gammastep"]
        running: false

        onExited: function (exitCode) {
            if (exitCode === 0) {
                console.log("DisplayService: Gammastep found, night mode can be enabled")
                // Don't auto-enable, just confirm availability
            } else {
                console.warn("DisplayService: gammastep not found")
                gammaStepAvailable = false
                if (typeof ToastService !== "undefined" && ToastService.showWarning) {
                    ToastService.showWarning("Night mode failed: gammastep not found")
                }
            }
        }
    }

    Process {
        id: gammaStepProcess
        command: buildGammastepCommand()
        running: nightModeActive || automationActive

        stderr: StdioCollector {
            onStreamFinished: {
                if (text && text.trim()) {
                    console.warn("DisplayService: Gammastep stderr:", text.trim())
                }
            }
        }

        onExited: function (exitCode) {
            if ((nightModeActive || automationActive) && exitCode !== 0) {
                console.warn("DisplayService: Gammastep process crashed with exit code:", exitCode)
                console.warn("DisplayService: Failed command was:", gammaStepProcess.command.join(" "))
                
                // Reset states first to prevent infinite restart loops
                const wasAutomationActive = automationActive
                const wasNightModeActive = nightModeActive
                
                if (exitCode === 15) {
                    console.warn("DisplayService: Exit code 15 suggests invalid arguments or missing dependencies")
                }
                
                // Try fallback methods only if we haven't tried them yet
                if (!gammaStepProcess.command.includes("-m")) {
                    console.log("DisplayService: Trying fallback with randr method")
                    gammaStepProcess.command = [...buildGammastepCommand(), "-m", "randr"]
                    Qt.callLater(() => {
                        if (wasAutomationActive || wasNightModeActive) {
                            gammaStepProcess.running = true
                        }
                    })
                } else if (gammaStepProcess.command.includes("randr")) {
                    console.log("DisplayService: Trying fallback with vidmode method")
                    const baseCommand = buildGammastepCommand()
                    gammaStepProcess.command = [...baseCommand, "-m", "vidmode"]
                    Qt.callLater(() => {
                        if (wasAutomationActive || wasNightModeActive) {
                            gammaStepProcess.running = true
                        }
                    })
                } else {
                    // All methods failed for this mode, but don't disable gamma entirely
                    console.error("DisplayService: All gammastep methods failed for current mode")
                    if (wasAutomationActive) {
                        automationActive = false
                        SessionData.setNightModeAutoEnabled(false)
                        if (typeof ToastService !== "undefined" && ToastService.showWarning) {
                            ToastService.showWarning("Night mode automation failed\n\nTry manual mode instead")
                        }
                    } else if (wasNightModeActive) {
                        nightModeActive = false
                        SessionData.setNightModeEnabled(false)
                        if (typeof ToastService !== "undefined" && ToastService.showWarning) {
                            ToastService.showWarning("Manual night mode failed\n\nTry automation mode instead")
                        }
                    }
                }
            } else if (exitCode === 0) {
                console.log("DisplayService: Gammastep process ended normally")
            }
        }
    }

    IpcHandler {
        function set(percentage: string, device: string): string {
            if (!root.brightnessAvailable)
                return "Brightness control not available"

            const value = parseInt(percentage)
            if (isNaN(value)) {
                return "Invalid brightness value: " + percentage
            }
            
            const clampedValue = Math.max(1, Math.min(100, value))
            const targetDevice = device || ""
            
            if (targetDevice && !root.devices.some(d => d.name === targetDevice)) {
                return "Device not found: " + targetDevice
            }
            
            root.lastIpcDevice = targetDevice
            if (targetDevice && targetDevice !== root.currentDevice) {
                root.setCurrentDevice(targetDevice, false)
            }
            root.setBrightness(clampedValue, targetDevice)
            
            if (targetDevice)
                return "Brightness set to " + clampedValue + "% on " + targetDevice
            else
                return "Brightness set to " + clampedValue + "%"
        }

        function increment(step: string, device: string): string {
            if (!root.brightnessAvailable)
                return "Brightness control not available"

            const targetDevice = device || ""
            const actualDevice = targetDevice === "" ? root.getDefaultDevice() : targetDevice
            
            if (actualDevice && !root.devices.some(d => d.name === actualDevice)) {
                return "Device not found: " + actualDevice
            }
            
            const currentLevel = actualDevice ? root.getDeviceBrightness(actualDevice) : root.brightnessLevel
            const stepValue = parseInt(step || "10")
            const newLevel = Math.max(1, Math.min(100, currentLevel + stepValue))
            
            root.lastIpcDevice = targetDevice
            if (targetDevice && targetDevice !== root.currentDevice) {
                root.setCurrentDevice(targetDevice, false)
            }
            root.setBrightness(newLevel, targetDevice)
            
            if (targetDevice)
                return "Brightness increased to " + newLevel + "% on " + targetDevice
            else
                return "Brightness increased to " + newLevel + "%"
        }

        function decrement(step: string, device: string): string {
            if (!root.brightnessAvailable)
                return "Brightness control not available"

            const targetDevice = device || ""
            const actualDevice = targetDevice === "" ? root.getDefaultDevice() : targetDevice
            
            if (actualDevice && !root.devices.some(d => d.name === actualDevice)) {
                return "Device not found: " + actualDevice
            }
            
            const currentLevel = actualDevice ? root.getDeviceBrightness(actualDevice) : root.brightnessLevel
            const stepValue = parseInt(step || "10")
            const newLevel = Math.max(1, Math.min(100, currentLevel - stepValue))
            
            root.lastIpcDevice = targetDevice
            if (targetDevice && targetDevice !== root.currentDevice) {
                root.setCurrentDevice(targetDevice, false)
            }
            root.setBrightness(newLevel, targetDevice)
            
            if (targetDevice)
                return "Brightness decreased to " + newLevel + "% on " + targetDevice
            else
                return "Brightness decreased to " + newLevel + "%"
        }

        function status(): string {
            if (!root.brightnessAvailable)
                return "Brightness control not available"

            return "Device: " + root.currentDevice + " - Brightness: " + root.brightnessLevel + "%"
        }

        function list(): string {
            if (!root.brightnessAvailable)
                return "No brightness devices available"

            let result = "Available devices:\n"
            for (const device of root.devices) {
                result += device.name + " (" + device.class + ")\n"
            }
            return result
        }

        function night_mode_toggle(): string {
            root.toggleNightMode()
            return root.nightModeActive ? "Night mode enabled" : "Night mode disabled"
        }

        function night_mode_enable(): string {
            root.enableNightMode()
            return "Night mode enabled"
        }

        function night_mode_disable(): string {
            root.disableNightMode()
            return "Night mode disabled"
        }

        function night_mode_status(): string {
            if (root.automationActive) {
                return "Night mode automation is active (" + SessionData.nightModeAutoMode + " mode)"
            }
            return root.nightModeActive ? "Night mode is enabled" : "Night mode is disabled"
        }

        function night_mode_temperature(value: string): string {
            if (!value) {
                return "Current temperature: " + SessionData.nightModeTemperature + "K"
            }

            const temp = parseInt(value)
            if (isNaN(temp)) {
                return "Invalid temperature. Use a value between 2500 and 6000 (in steps of 500)"
            }

            if (temp < 2500 || temp > 6000) {
                return "Temperature must be between 2500K and 6000K"
            }

            const rounded = Math.round(temp / 500) * 500
            SessionData.setNightModeTemperature(rounded)

            if (root.nightModeActive || root.automationActive) {
                root.restartGammastep()
            }

            if (rounded !== temp) {
                return "Night mode temperature set to " + rounded + "K (rounded from " + temp + "K)"
            } else {
                return "Night mode temperature set to " + rounded + "K"
            }
        }

        function night_mode_automation_enable(mode: string): string {
            if (!root.gammaStepAvailable) {
                return "Night mode automation not available - gammastep not found"
            }

            const validModes = ["time", "location"]
            if (!validModes.includes(mode)) {
                return "Invalid mode. Use 'time' or 'location'"
            }

            if (!root.geoClue2Available && mode === "location") {
                return "Location mode not available - geoclue2 not found"
            }

            SessionData.setNightModeAutoMode(mode)
            SessionData.setNightModeAutoEnabled(true)
            
            return "Night mode automation enabled (" + mode + " mode)"
        }

        function night_mode_automation_disable(): string {
            SessionData.setNightModeAutoEnabled(false)
            return "Night mode automation disabled"
        }

        function night_mode_automation_status(): string {
            if (SessionData.nightModeAutoEnabled) {
                return "Night mode automation is enabled (" + SessionData.nightModeAutoMode + " mode)"
            }
            return "Night mode automation is disabled"
        }

        function debug_time_status(): string {
            const isActive = root.isNightModeTimeActive()
            const now = new Date()
            const currentTime = now.getHours() + ":" + now.getMinutes().toString().padStart(2, "0")
            const startTime = SessionData.nightModeStartTime || "20:00"
            const endTime = SessionData.nightModeEndTime || "06:00"
            const temp = SessionData.nightModeTemperature || 4500
            
            return "Current time: " + currentTime + 
                   "\\nNight period: " + startTime + " to " + endTime +
                   "\\nShould be active: " + isActive +
                   "\\nTemperature: " + (isActive ? temp : 6500) + "K" +
                   "\\nAutomation active: " + root.automationActive +
                   "\\nTimer running: " + root.nightModeTimer.running
        }
        
        function test_gamma_support(): string {
            if (!root.gammaStepAvailable) {
                return "Gammastep not available - cannot test gamma support"
            }
            
            root.testGammastepMethods()
            return "Testing gamma support - check console output for results"
        }
        
        function gamma_status(): string {
            return "Gammastep available: " + root.gammaStepAvailable +
                   "\\nGeoclue2 available: " + root.geoClue2Available +
                   "\\nNight mode active: " + root.nightModeActive +
                   "\\nAutomation active: " + root.automationActive
        }
        
        function test_manual_gamma(temperature: string): string {
            if (!temperature) {
                return "Usage: test_manual_gamma <temperature>\\nExample: test_manual_gamma 4000"
            }
            
            const temp = parseInt(temperature)
            if (isNaN(temp) || temp < 1000 || temp > 10000) {
                return "Invalid temperature. Use value between 1000-10000K"
            }
            
            console.log("DisplayService: Testing manual gamma adjustment at", temp + "K")
            
            // Use a one-shot test to verify gamma works
            const testProcess = Qt.createQmlObject(`
                import QtQuick
                import Quickshell.Io
                Process {
                    command: ["gammastep", "-O", "${temp}", "-o"]
                    running: true
                    onExited: function(code) {
                        console.log("Manual gamma test finished with code:", code)
                        destroy()
                    }
                    Component.onDestruction: console.log("Test process destroyed")
                }
            `, root)
            
            return "Testing manual gamma at " + temp + "K - check console for results"
        }

        target: "brightness"
    }
}