import Foundation
import AppKit

/// Installs or updates the agent system-wide as a root LaunchDaemon (watchdog pattern).
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

    @discardableResult
    static func promptAndInstallIfNeeded() -> Bool {
        if isInstalled && isRunningFromSystemLocation {
            return true
        }

        let isUpdate = isInstalled && !isRunningFromSystemLocation
        let title = isUpdate ? "Update UsageTime agent?" : "Install UsageTime as a protected service?"
        let message = isUpdate
            ? "This will replace the installed agent with this new version and restart it.\n\nRequires admin password."
            : "This will install the agent in /Applications and set it to auto-start on boot.\nThe child will not be able to disable or remove it without the administrator password.\n\nRequires admin password (one time)."

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: isUpdate ? "Update" : "Install")
        alert.addButton(withTitle: "Not now")

        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        return performInstall(isUpdate: isUpdate)
    }

    private static func performInstall(isUpdate: Bool) -> Bool {
        let currentAppPath = Bundle.main.bundlePath

        // The full watchdog script with auto-update support
        let watchdogScript = Self.watchdogScriptContent()

        var script = "set -e\nmkdir -p /usr/local/libexec /var/log/usagetime\n"

        if isUpdate {
            script += """
            pkill -f '/Applications/UsageTimeAgent.app' 2>/dev/null || true
            sleep 1
            pkill -9 -f '/Applications/UsageTimeAgent.app' 2>/dev/null || true
            sleep 0.5
            """
        }

        // Escape the watchdog script for embedding in heredoc
        let escapedWatchdog = watchdogScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")

        script += """
        rm -rf "\(installedAppPath)"
        cp -R "\(currentAppPath)" "\(installedAppPath)"
        chown -R root:wheel "\(installedAppPath)"

        printf '%s' "\(escapedWatchdog)" > \(watchdogScriptPath)
        chmod 755 \(watchdogScriptPath)
        chown root:wheel \(watchdogScriptPath)

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
        return true
    }

    /// Returns the full watchdog shell script content (with auto-update).
    private static func watchdogScriptContent() -> String {
        return """
        #!/bin/bash
        # UsageTimeAgent Watchdog — restart + auto-update
        APP_PATH="/Applications/UsageTimeAgent.app"
        VERSION_FILE="/usr/local/libexec/usagetime-agent-version.txt"
        UPDATE_CHECK_MARKER="/tmp/usagetime-last-update-check"
        UPDATE_CHECK_INTERVAL=300

        log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [Watchdog] $1"; }

        # 1. Ensure agent is running
        if ! pgrep -f "UsageTimeAgent" > /dev/null 2>&1; then
            CONSOLE_USER=$(stat -f '%Su' /dev/console 2>/dev/null)
            if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ] && [ "$CONSOLE_USER" != "loginwindow" ]; then
                CONSOLE_UID=$(id -u "$CONSOLE_USER" 2>/dev/null)
                if [ -n "$CONSOLE_UID" ] && [ -d "$APP_PATH" ]; then
                    launchctl asuser "$CONSOLE_UID" open "$APP_PATH"
                    log "Agent started as $CONSOLE_USER"
                fi
            fi
        fi

        # 2. Auto-update (throttled to every 5 min)
        CONSOLE_USER=$(stat -f '%Su' /dev/console 2>/dev/null)
        [ -z "$CONSOLE_USER" ] || [ "$CONSOLE_USER" = "root" ] && exit 0

        if [ -f "$UPDATE_CHECK_MARKER" ]; then
            LAST_CHECK=$(stat -f '%m' "$UPDATE_CHECK_MARKER" 2>/dev/null || echo 0)
            NOW=$(date +%s)
            [ $((NOW - LAST_CHECK)) -lt "$UPDATE_CHECK_INTERVAL" ] && exit 0
        fi
        touch "$UPDATE_CHECK_MARKER"

        SERVER_URL=$(sudo -u "$CONSOLE_USER" defaults read com.usagetime.agent ServerURL 2>/dev/null)
        [ -z "$SERVER_URL" ] && exit 0

        UPDATE_INFO=$(curl -s --connect-timeout 5 --max-time 10 "$SERVER_URL/api/v1/agent/update/check" 2>/dev/null)
        [ -z "$UPDATE_INFO" ] && exit 0

        REMOTE_VERSION=$(echo "$UPDATE_INFO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('version') or '')" 2>/dev/null)
        REMOTE_SHA256=$(echo "$UPDATE_INFO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('sha256') or '')" 2>/dev/null)
        [ -z "$REMOTE_VERSION" ] || [ "$REMOTE_VERSION" = "None" ] && exit 0

        LOCAL_VERSION=""
        [ -f "$VERSION_FILE" ] && LOCAL_VERSION=$(cat "$VERSION_FILE")
        [ "$REMOTE_VERSION" = "$LOCAL_VERSION" ] && exit 0

        log "Update available: $LOCAL_VERSION -> $REMOTE_VERSION"

        FAIL_FILE="/tmp/usagetime-update-fails-$REMOTE_VERSION"
        FAIL_COUNT=0
        [ -f "$FAIL_FILE" ] && FAIL_COUNT=$(cat "$FAIL_FILE")
        [ "$FAIL_COUNT" -ge 3 ] && { log "Skipping — failed $FAIL_COUNT times"; exit 0; }

        TMPDIR=$(mktemp -d)
        ZIPFILE="$TMPDIR/UsageTimeAgent.zip"
        curl -s --connect-timeout 10 --max-time 120 -o "$ZIPFILE" "$SERVER_URL/api/v1/agent/update/download"

        if [ ! -f "$ZIPFILE" ] || [ ! -s "$ZIPFILE" ]; then
            log "Download failed"; echo $((FAIL_COUNT+1)) > "$FAIL_FILE"; rm -rf "$TMPDIR"; exit 1
        fi

        ACTUAL_SHA256=$(shasum -a 256 "$ZIPFILE" | awk '{print $1}')
        if [ "$ACTUAL_SHA256" != "$REMOTE_SHA256" ]; then
            log "SHA256 mismatch"; echo $((FAIL_COUNT+1)) > "$FAIL_FILE"; rm -rf "$TMPDIR"; exit 1
        fi

        cd "$TMPDIR" && unzip -qo "$ZIPFILE" -d "$TMPDIR"
        if [ ! -d "$TMPDIR/UsageTimeAgent.app" ]; then
            log "Invalid zip"; echo $((FAIL_COUNT+1)) > "$FAIL_FILE"; rm -rf "$TMPDIR"; exit 1
        fi

        pkill -f '/Applications/UsageTimeAgent.app' 2>/dev/null || true
        sleep 1
        pkill -9 -f '/Applications/UsageTimeAgent.app' 2>/dev/null || true
        sleep 0.5

        rm -rf "$APP_PATH"
        mv "$TMPDIR/UsageTimeAgent.app" "$APP_PATH"
        chown -R root:wheel "$APP_PATH"
        echo "$REMOTE_VERSION" > "$VERSION_FILE"
        rm -f "$FAIL_FILE"
        rm -rf "$TMPDIR"

        log "Updated to $REMOTE_VERSION — restarting"
        CONSOLE_UID=$(id -u "$CONSOLE_USER" 2>/dev/null)
        [ -n "$CONSOLE_UID" ] && launchctl asuser "$CONSOLE_UID" open "$APP_PATH"
        """
    }
}
