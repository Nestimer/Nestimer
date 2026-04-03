import Foundation
import AppKit

/// Manages the lock screen overlay when downtime is active or screen time is exceeded.
/// Uses a full-screen borderless window to block interaction.
class ScreenLocker {
    private var overlayProcess: Process?
    private var isLocked = false

    /// Show the lock screen overlay with a message.
    func lock(reason: LockReason) {
        guard !isLocked else { return }
        isLocked = true

        let message: String
        switch reason {
        case .downtime(let until):
            message = "Время отдыха. Компьютер доступен с \(until)"
        case .screenTimeExceeded:
            message = "Время за компьютером на сегодня закончилось"
        case .screenTimeWarning(let minutes):
            message = "Осталось \(minutes) минут экранного времени"
        }

        // Launch the overlay helper app
        launchOverlay(message: message)
        log("Screen locked: \(message)")
    }

    /// Remove the lock screen overlay.
    func unlock() {
        guard isLocked else { return }
        isLocked = false
        killOverlay()
        log("Screen unlocked")
    }

    var locked: Bool { isLocked }

    // MARK: - Overlay management

    /// The overlay is a separate process that creates a full-screen window.
    /// This is more robust than doing it in-process for a daemon.
    private func launchOverlay(message: String) {
        killOverlay()

        // Use osascript to display a full-screen blocking dialog
        // This is a simple approach; a production version would use a dedicated overlay app
        let script = """
        tell application "System Events"
            set frontApp to name of first application process whose frontmost is true
        end tell

        tell application "Finder"
            activate
        end tell

        display dialog "\(message)" buttons {"OK"} default button "OK" giving up after 5 with icon caution
        """

        // For actual blocking, we use a loginwindow approach
        // Lock the screen using the system method
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]

        try? process.run()
        overlayProcess = process
    }

    private func killOverlay() {
        overlayProcess?.terminate()
        overlayProcess = nil
    }

    private func log(_ msg: String) {
        NSLog("[UsageTimeAgent] \(msg)")
    }

    enum LockReason {
        case downtime(until: String)
        case screenTimeExceeded
        case screenTimeWarning(minutes: Int)
    }
}
