import Foundation
import AppKit

/// Core logic: decides whether to lock/unlock based on current policy and usage.
class PolicyEnforcer {
    private let lockScreen = LockScreenWindow()
    private let notifications: NotificationManager
    private var currentPolicy: ServerPolicy?
    private var warningShownAt: Set<Int> = []  // track which warnings we've shown

    init(notificationManager: NotificationManager) {
        self.notifications = notificationManager
    }

    /// Evaluate rules and enforce lock/unlock. Must be called on main thread.
    func evaluate(policy: ServerPolicy, usedMinutesToday: Double) {
        currentPolicy = policy

        // 1. Check downtime
        if policy.downtimeEnabled && isInDowntime(start: policy.downtimeStart, end: policy.downtimeEnd) {
            lockScreen.show(reason: .downtime(until: policy.downtimeEnd))
            return
        }

        // 2. Check screen time limit
        if policy.screenTimeEnabled {
            let limitMinutes = Double(policy.screenTimeLimitMinutes)
            let remaining = limitMinutes - usedMinutesToday

            if remaining <= 0 {
                notifications.showTimeExpired()
                lockScreen.show(reason: .timeExpired)
                return
            }

            // Warnings at 15, 10, 5, 1 minute marks
            for threshold in [15, 10, 5, 1] {
                if remaining <= Double(threshold) && remaining > Double(threshold - 1) {
                    if !warningShownAt.contains(threshold) {
                        warningShownAt.insert(threshold)
                        notifications.showTimeWarning(remainingMinutes: threshold)
                    }
                }
            }

            // Reset warnings if time was added
            if remaining > 15 {
                warningShownAt.removeAll()
            }
        }

        // No restrictions active — unlock
        lockScreen.hide()
    }

    // MARK: - Downtime check

    private func isInDowntime(start: String, end: String) -> Bool {
        let now = Date()
        let calendar = Calendar.current
        let currentHour = calendar.component(.hour, from: now)
        let currentMinute = calendar.component(.minute, from: now)
        let currentTotal = currentHour * 60 + currentMinute

        let startTotal = parseTimeToMinutes(start)
        let endTotal = parseTimeToMinutes(end)

        if startTotal <= endTotal {
            return currentTotal >= startTotal && currentTotal < endTotal
        } else {
            // Overnight (e.g., 22:00 - 08:00)
            return currentTotal >= startTotal || currentTotal < endTotal
        }
    }

    private func parseTimeToMinutes(_ time: String) -> Int {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return 0 }
        return parts[0] * 60 + parts[1]
    }
}
