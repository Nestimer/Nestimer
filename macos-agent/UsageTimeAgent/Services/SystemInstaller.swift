import Foundation
import AppKit

/// Installs or updates the agent system-wide as a root LaunchDaemon (watchdog pattern).
/// On first launch: asks for admin password, copies to /Applications, installs watchdog.
/// On update: new binary detects old install, kills old, replaces, watchdog restarts.
struct SystemInstaller {

    static let daemonLabel = "com.usagetime.agent-watchdog"
    static let daemonPlistPath = "/Library/LaunchDaemons/\(daemonLabel).plist"
    static let installedAppPath = "/Applications/UsageTimeAgent.app"
    static let watchdogScriptPath = "/usr/local/libexec/usagetime-watchdog.sh"

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: daemonPlistPath)
    }

    static var isRunningFromSystemLocation: Bool {
        Bundle.main.bundlePath == installedAppPath
    }

    /// Main entry point. Call from AppDelegate on launch.
    /// Handles three scenarios:
    ///   1. Running from /Applications and daemon exists → nothing to do
    ///   2. Running NOT from /Applications, daemon exists → UPDATE
    ///   3. No daemon installed → FRESH INSTALL
    @discardableResult
    static func promptAndInstallIfNeeded() -> Bool {
        // Already running from /Applications with daemon — nothing to do
        if isInstalled && isRunningFromSystemLocation {
            return true
        }

        // Decide the action
        let isUpdate = isInstalled && !isRunningFromSystemLocation
        let title = isUpdate ? "Update UsageTime agent?" : "Install UsageTime as a protected service?"
        let message = isUpdate
            ? "This will replace the installed agent with this new version and restart it.\n\nRequires admin password."
            : "This will install the agent in /Applications and set it to auto-start on boot.\nThe child will not be able to disable or remove it without the administrator password.\n\nRequires admin password (one time)."
        let buttonTitle = isUpdate ? "Update" : "Install"

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: buttonTitle)
        alert.addButton(withTitle: "Not now")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return false
        }

        return performInstall(isUpdate: isUpdate)
    }

    private static func performInstall(isUpdate: Bool) -> Bool {
        let currentAppPath = Bundle.main.bundlePath

        // Shell script that runs with admin privileges
        var script = """
        set -e
        mkdir -p /usr/local/libexec /var/log/usagetime
        """

        // On update: kill old agent first, wait for it to exit
        if isUpdate {
            script += """

            # Kill existing agent
            pkill -f '/Applications/UsageTimeAgent.app' 2>/dev/null || true
            sleep 1
            pkill -9 -f '/Applications/UsageTimeAgent.app' 2>/dev/null || true
            sleep 0.5
            """
        }

        // Copy app (always — both install and update)
        script += """

        # Copy app to /Applications
        rm -rf "\(installedAppPath)"
        cp -R "\(currentAppPath)" "\(installedAppPath)"
        chown -R root:wheel "\(installedAppPath)"

        # Watchdog script
        cat > \(watchdogScriptPath) <<'WATCHDOG'
        #!/bin/bash
        APP_PATH="\(installedAppPath)"
        if ! pgrep -f "UsageTimeAgent" > /dev/null 2>&1; then
            CONSOLE_USER=$(stat -f '%Su' /dev/console 2>/dev/null)
            if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ] && [ "$CONSOLE_USER" != "loginwindow" ]; then
                CONSOLE_UID=$(id -u "$CONSOLE_USER" 2>/dev/null)
                if [ -n "$CONSOLE_UID" ] && [ -d "$APP_PATH" ]; then
                    launchctl asuser "$CONSOLE_UID" open "$APP_PATH"
                fi
            fi
        fi
        WATCHDOG
        chmod 755 \(watchdogScriptPath)
        chown root:wheel \(watchdogScriptPath)

        # LaunchDaemon plist
        launchctl unload \(daemonPlistPath) 2>/dev/null || true
        cat > \(daemonPlistPath) <<'PLIST'
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(daemonLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/bin/bash</string>
                <string>\(watchdogScriptPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>StartInterval</key>
            <integer>15</integer>
            <key>ThrottleInterval</key>
            <integer>5</integer>
            <key>StandardOutPath</key>
            <string>/var/log/usagetime/watchdog.log</string>
            <key>StandardErrorPath</key>
            <string>/var/log/usagetime/watchdog-error.log</string>
        </dict>
        </plist>
        PLIST
        chown root:wheel \(daemonPlistPath)
        chmod 644 \(daemonPlistPath)
        launchctl load \(daemonPlistPath)
        """

        // Run via AppleScript with admin privileges
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\")
                             .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"

        var error: NSDictionary?
        let scriptObj = NSAppleScript(source: appleScript)
        _ = scriptObj?.executeAndReturnError(&error)

        if let error {
            NSLog("[UsageTimeAgent] SystemInstaller failed: \(error)")
            let errAlert = NSAlert()
            errAlert.messageText = isUpdate ? "Update failed" : "Install failed"
            errAlert.informativeText = (error["NSAppleScriptErrorMessage"] as? String) ?? "Unknown error"
            errAlert.alertStyle = .warning
            errAlert.addButton(withTitle: "OK")
            errAlert.runModal()
            return false
        }

        NSLog("[UsageTimeAgent] SystemInstaller: \(isUpdate ? "updated" : "installed") ✓")

        // Quit this instance — watchdog will launch the new /Applications version within 15s
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
        return true
    }
}
