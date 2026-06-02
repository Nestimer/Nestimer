import Foundation
import AppKit

/// Self-protection mechanisms to prevent the child from killing the agent.
/// Works in combination with the external LaunchDaemon watchdog.
class SelfProtection {

    func start() {
        // 1. Register for termination notification to log attempts
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )

        // 2. Disable Cmd+Q (the app shouldn't have a Quit menu item since it's LSUIElement)
        // But we also intercept it just in case
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Block Cmd+Q
            // Block Cmd+Q and Cmd+Shift+Q (logout shortcut)
            if event.modifierFlags.contains(.command),
               let chars = event.charactersIgnoringModifiers?.lowercased(),
               chars == "q" {
                NSLog("[UsageTimeAgent] Cmd+Q blocked")
                return nil // swallow the event
            }
            return event
        }

        // 3. Prevent termination via NSProcessInfo
        // On macOS 13+, we can disable sudden termination
        ProcessInfo.processInfo.disableSuddenTermination()
        ProcessInfo.processInfo.disableAutomaticTermination("UsageTimeAgent must keep running")

        NSLog("[UsageTimeAgent] Self-protection enabled")
    }

    @objc private func appWillTerminate(_ notification: Notification) {
        NSLog("[UsageTimeAgent] WARNING: App is being terminated! Watchdog should restart us.")
    }
}
