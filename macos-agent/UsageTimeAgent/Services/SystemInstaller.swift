import Foundation
import AppKit

/// Installs or updates the agent as a root-protected system service.
/// Uses bundled watchdog.sh and watchdog.plist from the app's Resources.
struct SystemInstaller {

    static let daemonPlistPath = "/Library/LaunchDaemons/com.usagetime.agent-watchdog.plist"
    static let installedAppPath = "/Applications/UsageTimeAgent.app"
    static let watchdogDst = "/usr/local/libexec/usagetime-watchdog.sh"

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: daemonPlistPath)
    }

    static var isRunningFromSystemLocation: Bool {
        Bundle.main.bundlePath == installedAppPath
    }

    @discardableResult
    static func promptAndInstallIfNeeded() -> Bool {
        if isInstalled && isRunningFromSystemLocation { return true }

        let isUpdate = isInstalled && !isRunningFromSystemLocation
        let alert = NSAlert()
        alert.messageText = isUpdate ? "Update NesTimer agent?" : "Install NesTimer as a protected service?"
        alert.informativeText = isUpdate
            ? "Replaces the installed agent and restarts.\nRequires admin password."
            : "Installs to /Applications with auto-start on boot.\nChild cannot disable without admin password.\nRequires admin password (one time)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: isUpdate ? "Update" : "Install")
        alert.addButton(withTitle: "Not now")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        return performInstall(isUpdate: isUpdate)
    }

    private static func performInstall(isUpdate: Bool) -> Bool {
        // Get paths to bundled resources
        guard let watchdogSrc = Bundle.main.path(forResource: "watchdog", ofType: "sh"),
              let plistSrc = Bundle.main.path(forResource: "watchdog", ofType: "plist") else {
            showError("Bundle resources missing (watchdog.sh / watchdog.plist)")
            return false
        }

        let appSrc = Bundle.main.bundlePath

        // Build shell commands — all single-quoted paths, no escaping needed
        var cmds = [
            "mkdir -p /usr/local/libexec /var/log/usagetime",
        ]

        if isUpdate {
            cmds += [
                "pkill -f '/Applications/UsageTimeAgent.app' || true",
                "sleep 1",
            ]
        }

        cmds += [
            "rm -rf '\(installedAppPath)'",
            "cp -R '\(appSrc)' '\(installedAppPath)'",
            "chown -R root:wheel '\(installedAppPath)'",
            "cp '\(watchdogSrc)' '\(watchdogDst)'",
            "chmod 755 '\(watchdogDst)'",
            "chown root:wheel '\(watchdogDst)'",
            "launchctl unload '\(daemonPlistPath)' 2>/dev/null || true",
            "cp '\(plistSrc)' '\(daemonPlistPath)'",
            "chown root:wheel '\(daemonPlistPath)'",
            "chmod 644 '\(daemonPlistPath)'",
            "launchctl load '\(daemonPlistPath)'",
        ]

        let script = cmds.joined(separator: " && ")
        NSLog("[SystemInstaller] Running: \(script)")

        let appleScript = "do shell script \"\(script)\" with administrator privileges"

        var error: NSDictionary?
        NSAppleScript(source: appleScript)?.executeAndReturnError(&error)

        if let error {
            let msg = (error["NSAppleScriptErrorMessage"] as? String) ?? "\(error)"
            NSLog("[SystemInstaller] FAILED: \(msg)")
            showError(msg)
            return false
        }

        NSLog("[SystemInstaller] \(isUpdate ? "Updated" : "Installed") ✓")

        // Quit — watchdog will start the /Applications copy within 15s
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
        return true
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Install failed"
        alert.informativeText = """
        \(message)

        If macOS blocked the admin prompt, try:
        1. Right-click the app → Open (first time only)
        2. Or run from Terminal:
           \(Bundle.main.bundlePath)/Contents/MacOS/UsageTimeAgent
        """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
