pragma Singleton
pragma ComponentBehavior: Bound

import QtCore
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common

Singleton {
    id: root

    property bool automationActive: false
    property bool gammaStepAvailable: false
    property bool geoClue2Available: false
    property string configPath: ""

    Component.onCompleted: {
        // Set up config path using environment variable
        setupConfigPath()
        checkDependencies()
        updateAutomationState()
    }

    function setupConfigPath() {
        // Use shell to get config path
        configPathProcess.running = true
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
                writeGammastepConfig()
                restartGammastep()
            }
        }

        function onNightModeEndTimeChanged() {
            if (SessionData.nightModeAutoMode === "time" && SessionData.nightModeAutoEnabled) {
                writeGammastepConfig()
                restartGammastep()
            }
        }

        function onNightModeTemperatureChanged() {
            if (SessionData.nightModeAutoEnabled) {
                writeGammastepConfig()
                restartGammastep()
            }
        }
    }

    function checkDependencies() {
        gammaStepDetectionProcess.running = true
    }

    function testGammastepMethods() {
        // Test which adjustment methods are available
        methodTestProcess.running = true
    }

    function updateAutomationState() {
        if (SessionData.nightModeAutoEnabled && gammaStepAvailable) {
            startGammastepAutomation()
        } else {
            stopGammastepAutomation()
        }
    }

    function startGammastepAutomation() {
        console.log("NightModeAutomation: Starting automation with mode:", SessionData.nightModeAutoMode)
        console.log("NightModeAutomation: Config path:", configPath)
        writeGammastepConfig()
        automationActive = true
        gammaStepProcess.running = true
        console.log("NightModeAutomation: Started gammastep with mode:", SessionData.nightModeAutoMode)
    }

    function stopGammastepAutomation() {
        automationActive = false
        gammaStepProcess.running = false
        Quickshell.execDetached(["pkill", "gammastep"])
        console.log("NightModeAutomation: Stopped gammastep automation")
    }

    function restartGammastep() {
        if (automationActive) {
            gammaStepProcess.running = false
            Qt.callLater(() => {
                gammaStepProcess.running = true
            })
        }
    }

    function writeGammastepConfig() {
        writeGammastepConfigWithMethod(null)
    }

    function writeGammastepConfigWithMethod(method) {
        if (!gammaStepAvailable) return

        let configContent = "[general]\n"
        
        // Temperature settings
        configContent += `temp-day=6500\n`
        configContent += `temp-night=${SessionData.nightModeTemperature}\n`
        
        // Fade transitions
        configContent += "fade=1\n"
        
        // Method settings
        if (method) {
            configContent += `adjustment-method=${method}\n`
        }
        
        if (SessionData.nightModeAutoMode === "location") {
            // Location-based using geoclue2
            configContent += "location-provider=geoclue2\n"
        } else if (SessionData.nightModeAutoMode === "time") {
            // Time-based scheduling
            configContent += "location-provider=manual\n"
            configContent += `dawn-time=${SessionData.nightModeEndTime}\n`
            configContent += `dusk-time=${SessionData.nightModeStartTime}\n`
            
            // Set a default location for manual time mode
            configContent += "\n[manual]\n"
            configContent += "lat=0.0\n"
            configContent += "lon=0.0\n"
        }

        if (!configPath) {
            console.warn("NightModeAutomation: Config path not set yet")
            return
        }

        // Ensure config directory exists and write config
        writeConfigProcess.command = ["bash", "-c", `mkdir -p "$(dirname "${configPath}")" && cat > "${configPath}" << 'EOF'
${configContent}EOF`]
        writeConfigProcess.running = true
    }

    Process {
        id: configPathProcess
        command: ["sh", "-c", "echo ${XDG_CONFIG_HOME:-$HOME/.config}/gammastep/config.ini"]
        running: false

        stdout: StdioCollector {
            onStreamFinished: {
                if (text && text.trim()) {
                    configPath = text.trim()
                    console.log("NightModeAutomation: Config path set to:", configPath)
                } else {
                    console.warn("NightModeAutomation: Failed to get config path")
                }
            }
        }

        onExited: function (exitCode) {
            if (exitCode !== 0) {
                console.warn("NightModeAutomation: Failed to get config path, exit code:", exitCode)
            }
        }
    }

    Process {
        id: gammaStepDetectionProcess
        command: ["which", "gammastep"]
        running: false

        onExited: function (exitCode) {
            gammaStepAvailable = (exitCode === 0)
            if (gammaStepAvailable) {
                console.log("NightModeAutomation: gammastep detected")
                // Test which methods work before enabling
                testGammastepMethods()
                // Check for geoclue2 availability
                geoClue2DetectionProcess.running = true
            } else {
                console.log("NightModeAutomation: gammastep not available")
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
                    console.log("NightModeAutomation: Available methods:", text.trim())
                    // Check if any useful methods are available
                    const methods = text.toLowerCase()
                    if (methods.includes("randr") || methods.includes("vidmode") || methods.includes("wayland")) {
                        console.log("NightModeAutomation: Found compatible display methods")
                    } else {
                        console.warn("NightModeAutomation: No compatible display methods found")
                        gammaStepAvailable = false
                    }
                }
            }
        }

        stderr: StdioCollector {
            onStreamFinished: {
                if (text && text.trim()) {
                    console.warn("NightModeAutomation: Method test stderr:", text.trim())
                }
            }
        }

        onExited: function (exitCode) {
            if (exitCode !== 0) {
                console.warn("NightModeAutomation: Method test failed, but continuing anyway")
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
                console.log("NightModeAutomation: geoclue2 support detected")
            } else {
                console.log("NightModeAutomation: geoclue2 not available - location mode may not work")
            }
        }
    }

    Process {
        id: writeConfigProcess
        running: false

        stdout: StdioCollector {
            onStreamFinished: {
                if (text && text.trim()) {
                    console.log("NightModeAutomation: Config write output:", text.trim())
                }
            }
        }

        stderr: StdioCollector {
            onStreamFinished: {
                if (text && text.trim()) {
                    console.warn("NightModeAutomation: Config write error:", text.trim())
                }
            }
        }

        onExited: function (exitCode) {
            if (exitCode !== 0) {
                console.warn("NightModeAutomation: Failed to write gammastep config with exit code:", exitCode)
                if (typeof ToastService !== "undefined" && ToastService.showWarning) {
                    ToastService.showWarning("Failed to write gammastep configuration")
                }
            } else {
                console.log("NightModeAutomation: Successfully wrote gammastep config to:", configPath)
            }
        }
    }

    Process {
        id: gammaStepProcess
        command: ["bash", "-c", `gammastep -c "${configPath}"`]
        running: false

        stderr: StdioCollector {
            onStreamFinished: {
                if (text && text.trim()) {
                    console.warn("NightModeAutomation: Gammastep stderr:", text.trim())
                    
                    // Check for the "zero outputs" issue
                    if (text.includes("Zero outputs support gamma adjustment") || 
                        text.includes("do not support gamma adjustment")) {
                        console.warn("NightModeAutomation: Display does not support gamma adjustment")
                        automationActive = false
                        gammaStepAvailable = false
                        if (typeof ToastService !== "undefined" && ToastService.showWarning) {
                            ToastService.showWarning("Night mode not supported - display does not support gamma adjustment")
                        }
                    }
                }
            }
        }

        onExited: function (exitCode) {
            if (automationActive && exitCode !== 0) {
                console.warn("NightModeAutomation: Gammastep process crashed with exit code:", exitCode)
                
                // If gammastep failed and we haven't tried randr yet
                if (!gammaStepProcess.command[2].includes("randr") && !gammaStepProcess.command[2].includes("vidmode")) {
                    console.log("NightModeAutomation: Trying fallback with randr method")
                    writeGammastepConfigWithMethod("randr")
                    Qt.callLater(() => {
                        gammaStepProcess.running = true
                    })
                } else if (!gammaStepProcess.command[2].includes("vidmode")) {
                    console.log("NightModeAutomation: Trying fallback with vidmode method")
                    writeGammastepConfigWithMethod("vidmode")
                    Qt.callLater(() => {
                        gammaStepProcess.running = true
                    })
                } else {
                    automationActive = false
                    gammaStepAvailable = false
                    if (typeof ToastService !== "undefined" && ToastService.showWarning) {
                        ToastService.showWarning("Night mode automation failed - display does not support gamma adjustment")
                    }
                }
            } else if (exitCode === 0) {
                console.log("NightModeAutomation: Gammastep process ended normally")
            }
        }
    }
}