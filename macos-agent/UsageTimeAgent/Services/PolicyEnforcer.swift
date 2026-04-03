import Foundation
import AppKit

/// Core logic: decides whether to lock/unlock based on current policy and usage.
class PolicyEnforcer {
    private let lockScreen = LockScreenWindow()
    private let notifications: NotificationManager
    private var lastPolicyLimitMinutes: Int?
    /// Tracks which warning thresholds have been crossed (remaining went below this value).
    private var warningThresholdsCrossed: Set<Int> = []
    private var previousRemaining: Double?

    init(notificationManager: NotificationManager) {
        self.notifications = notificationManager
    }

    /// Enable dev mode on the lock screen (auto-unlock, emergency hotkey, lower window level).
    func configureDevMode(enabled: Bool, autoUnlockSeconds: TimeInterval = 10) {
        lockScreen.devMode = enabled
        lockScreen.devAutoUnlockSeconds = autoUnlockSeconds
        if enabled {
            NSLog("[UsageTimeAgent] PolicyEnforcer: dev mode enabled (auto-unlock: \(Int(autoUnlockSeconds))s)")
        }
    }

    /// Evaluate rules and enforce lock/unlock. Must be called on main thread.
    func evaluate(policy: ServerPolicy, usedMinutesToday: Double) {
        // Reset warnings if policy limit changed (parent granted more time)
        if let lastLimit = lastPolicyLimitMinutes, lastLimit != policy.screenTimeLimitMinutes {
            warningThresholdsCrossed.removeAll()
            previousRemaining = nil
        }
        lastPolicyLimitMinutes = policy.screenTimeLimitMinutes

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
                previousRemaining = remaining
                return
            }

            // Warnings when remaining crosses below a threshold
            for threshold in [15, 10, 5, 1] {
                let thresholdDouble = Double(threshold)
                if remaining <= thresholdDouble && !warningThresholdsCrossed.contains(threshold) {
                    warningThresholdsCrossed.insert(threshold)
                    notifications.showTimeWarning(remainingMinutes: threshold)
                }
            }

            // Reset if time was added (remaining went back up past all thresholds)
            if remaining > 15 {
                warningThresholdsCrossed.removeAll()
            }

            previousRemaining = remaining
        }

        // No restrictions active — unlock
        lockScreen.hide()
    }

    // MARK: - Downtime check

    private func isInDowntime(start: String, end: String) -> Bool {
        let startTotal = parseTimeToMinutes(start)
        let endTotal = parseTimeToMinutes(end)

        // start == end means no downtime window (not "24h lock")
        guard startTotal != endTotal else { return false }

        let now = Date()
        let calendar = Calendar.current
        let currentHour = calendar.component(.hour, from: now)
        let currentMinute = calendar.component(.minute, from: now)
        let currentTotal = currentHour * 60 + currentMinute

        if startTotal < endTotal {
            // Same day range (e.g., 13:00 - 15:00)
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
