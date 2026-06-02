import Foundation
import AppKit

/// Manages notifications for the agent.
/// Uses AppleScript `display notification` as a fallback for unsigned apps
/// where UNUserNotificationCenter silently fails.
class NotificationManager {

    func requestPermission() {
        // AppleScript notifications don't need permission
        NSLog("[NesTimer] Notifications: using AppleScript (no permission needed)")
    }

    func showTimeWarning(remainingMinutes: Int) {
        notify(title: "Screen Time", body: "\(remainingMinutes) minutes remaining", sound: true)
    }

    func showTimeExpired() {
        notify(title: "Time's Up", body: "Screen time for today has ended", sound: true)
    }

    func showDowntimeStarting(inMinutes minutes: Int) {
        notify(title: "Downtime", body: "Downtime starts in \(minutes) minutes", sound: true)
    }

    private func notify(title: String, body: String, sound: Bool) {
        let soundClause = sound ? " sound name \"Blow\"" : ""
        let escaped = body.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "display notification \"\(escaped)\" with title \"\(escapedTitle)\"\(soundClause)"

        DispatchQueue.global(qos: .utility).async {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error {
                NSLog("[NesTimer] Notification failed: \(error)")
            }
        }
    }
}
