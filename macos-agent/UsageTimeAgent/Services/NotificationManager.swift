import Foundation
import UserNotifications

/// Manages native macOS notifications for the agent.
class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                NSLog("[UsageTimeAgent] Notification permission error: \(error)")
            }
            NSLog("[UsageTimeAgent] Notifications \(granted ? "granted" : "denied")")
        }
    }

    /// Show a time warning notification.
    func showTimeWarning(remainingMinutes: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Screen Time"
        content.body = "\(remainingMinutes) minutes remaining"
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: "time-warning-\(remainingMinutes)",
            content: content,
            trigger: nil // immediate
        )
        center.add(request)
    }

    /// Show notification when time is up.
    func showTimeExpired() {
        let content = UNMutableNotificationContent()
        content.title = "Time's Up"
        content.body = "Screen time for today has ended"
        content.sound = .defaultCritical
        content.interruptionLevel = .critical

        let request = UNNotificationRequest(
            identifier: "time-expired",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    /// Show notification about upcoming downtime.
    func showDowntimeStarting(inMinutes minutes: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Downtime"
        content.body = "Downtime starts in \(minutes) minutes"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "downtime-warning",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    // Show notifications even when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
