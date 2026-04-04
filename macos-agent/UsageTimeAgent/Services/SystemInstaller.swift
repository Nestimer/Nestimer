import Foundation
import AppKit

/// Installs the agent system-wide as a root LaunchDaemon (watchdog pattern).
/// Requires one-time admin password — after install, the child cannot disable it.
struct SystemInstaller {

    static let daemonLabel = "com.usagetime.agent-watchdog"
    static let daemonPlistPath = "/Library/LaunchDaemons/\(daemonLabel).plist"
    static let installedAppPath = "/Applications/UsageTimeAgent.app"
    static let watchdogScriptPath = "/usr/local/libexec/usagetime-watchdog.sh"

    /// True if the daemon plist is installed.
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: daemonPlistPath)
    }

    /// True if the currently-running app is the installed copy in /Applications.
    static var isRunningFromSystemLocation: Bool {
        Bundle.main.bundlePath == installedAppPath
    }

    /// Show a dialog asking to install, then run the admin install if confirmed.
    /// Returns true if install completed; false if user declined or install failed.
    @discardableResult
    static func promptAndInstallIfNeeded() -> Bool {
        if isInstalled && isRunningFromSystemLocation {
            return true
        }

        let alert = NSAlert()
        alert.messageText = "Install UsageTime as a protected service?"
        alert.informativeText = """
        This will install the agent in /Applications and set it to auto-start on boot.
        The child will not be able to disable or remove it without the administrator password.

        Requires admin password (one time).
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Not now")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return false
        }

        return performInstall()
    }

    /// Runs the install with admin privileges via AppleScript.
    private static func performInstall() -> Bool {
        let currentAppPath = Bundle.main.bundlePath

        // Build a shell script that:
        //  1. Copies app to /Applications (if not already there)
        //  2. Writes the watchdog shell script
        //  3. Writes the LaunchDaemon plist (running as root, KeepAlive, RunAtLoad)
        //  4. Loads the daemon
        let script = """
        set -e
        mkdir -p /usr/local/libexec /var/log/usagetime

        # 1. Copy app to /Applications (if not already)
        if [ "\(currentAppPath)" != "\(installedAppPath)" ]; then
            rm -rf "\(installedAppPath)"
            cp -R "\(currentAppPath)" "\(installedAppPath)"
        fi
        chown -R root:wheel "\(installedAppPath)"

        # 2. Watchdog script — ensures agent is running for the console user
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

        # 3. LaunchDaemon plist
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

        # 4. Load the daemon
        launchctl unload \(daemonPlistPath) 2>/dev/null || true
        launchctl load \(daemonPlistPath)
        """

        // Run via AppleScript with admin privileges (shows standard admin password dialog)
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\")
                             .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"

        var error: NSDictionary?
        let scriptObj = NSAppleScript(source: appleScript)
        _ = scriptObj?.executeAndReturnError(&error)

        if let error {
            NSLog("[UsageTimeAgent] SystemInstaller failed: \(error)")
            let alert = NSAlert()
            alert.messageText = "Install failed"
            alert.informativeText = (error["NSAppleScriptErrorMessage"] as? String) ?? "Unknown error"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return false
        }

        NSLog("[UsageTimeAgent] SystemInstaller: installed ✓")
        // If we're not already running from /Applications, relaunch from there and quit
        if !isRunningFromSystemLocation {
            NSWorkspace.shared.open(URL(fileURLWithPath: installedAppPath))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.terminate(nil)
            }
        }
        return true
    }
}
