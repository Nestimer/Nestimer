import Foundation
import AppKit

/// Core logic: decides whether to lock/unlock based on current policy and usage.
class PolicyEnforcer {
    private let lockScreen = LockScreenWindow()
    private let notifications: NotificationManager
    private let mediaController = MediaController()
    private var lastPolicyLimitMinutes: Int?
    /// Tracks which warning thresholds have been crossed (remaining went below this value).
    private var warningThresholdsCrossed: Set<Int> = []
    private var previousRemaining: Double?
    /// Temporary unlock granted via TOTP code.
    private var temporaryUnlockUntil: Date?
    /// Whether the lock screen is currently visible (used to drive fast sync).
    private(set) var isLocked: Bool = false

    /// True while a TOTP-granted temporary unlock window is active.
    var isTemporaryUnlockActive: Bool {
        guard let until = temporaryUnlockUntil else { return false }
        return Date() < until
    }

    init(notificationManager: NotificationManager) {
        self.notifications = notificationManager
    }

    /// Set a callback for when a TOTP code is submitted on the lock screen.
    func setCodeHandler(_ handler: @escaping (String) -> Void) {
        lockScreen.onCodeSubmitted = handler
    }

    /// Grant temporary access (e.g. 30 minutes) — hides lock screen immediately.
    func grantTemporaryAccess(minutes: Int = 30) {
        temporaryUnlockUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
        lockScreen.hide()
        transitionToUnlocked()
        NSLog("[UsageTimeAgent] Temporary access granted for \(minutes) minutes (until \(temporaryUnlockUntil!))")
    }

    // MARK: - Lock state transitions (media control)

    private func transitionToLocked() {
        guard !isLocked else { return }
        isLocked = true
        mediaController.onLock()
    }

    private func transitionToUnlocked() {
        guard isLocked else { return }
        isLocked = false
        mediaController.onUnlock()
    }

    /// Enable dev mode on the lock screen (auto-unlock, emergency hotkey, lower window level).
    func configureDevMode(enabled: Bool, autoUnlockSeconds: TimeInterval = 10) {
        lockScreen.devMode = enabled
        lockScreen.devAutoUnlockSeconds = autoUnlockSeconds
        if enabled {
            NSLog("[UsageTimeAgent] PolicyEnforcer: dev mode enabled (auto-unlock: \(Int(autoUnlockSeconds))s)")
        }
    }

    /// The activity currently active (with buffer), if any. Updated on each evaluate().
    private(set) var activeActivity: ScheduledActivity?
    /// End time (HH:MM) of current activity window (including buffer), for status bar display.
    private(set) var activeActivityEndsAt: String?

    /// Evaluate rules and enforce lock/unlock. Must be called on main thread.
    func evaluate(policy: ServerPolicy, usedMinutesToday: Double) {
        // 0. Check scheduled activities (highest priority — bypasses downtime + limit)
        let (active, endsAt) = findActiveActivity(in: policy.activities ?? [])
        activeActivity = active
        activeActivityEndsAt = endsAt
        if active != nil {
            lockScreen.hide()
            transitionToUnlocked()
            return
        }

        // Check temporary unlock (granted via TOTP code)
        if let unlockUntil = temporaryUnlockUntil {
            if Date() < unlockUntil {
                lockScreen.hide()
                transitionToUnlocked()
                return  // Temporary override active
            } else {
                temporaryUnlockUntil = nil  // Expired
            }
        }

        // Reset warnings if policy limit changed (parent granted more time)
        if let lastLimit = lastPolicyLimitMinutes, lastLimit != policy.screenTimeLimitMinutes {
            warningThresholdsCrossed.removeAll()
            previousRemaining = nil
        }
        lastPolicyLimitMinutes = policy.screenTimeLimitMinutes

        // 1. Check downtime
        if policy.downtimeEnabled && isInDowntime(start: policy.downtimeStart, end: policy.downtimeEnd) {
            lockScreen.show(reason: .downtime(until: policy.downtimeEnd))
            transitionToLocked()
            return
        }

        // 2. Check screen time limit
        if policy.screenTimeEnabled {
            let limitMinutes = Double(policy.screenTimeLimitMinutes)
            let remaining = limitMinutes - usedMinutesToday

            // Lock when less than 1 minute remaining (menu shows 0m at this point)
            if remaining < 1 {
                notifications.showTimeExpired()
                lockScreen.show(reason: .timeExpired)
                previousRemaining = remaining
                transitionToLocked()
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
        transitionToUnlocked()
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

    // MARK: - Activity check

    /// Returns the currently active activity (considering buffer) and its end time, if any.
    private func findActiveActivity(in activities: [ScheduledActivity]) -> (ScheduledActivity?, String?) {
        let now = Date()
        let calendar = Calendar.current
        // Swift weekday: Sun=1..Sat=7 → convert to Mon=0..Sun=6
        let swiftWeekday = calendar.component(.weekday, from: now)
        let mondayBased = (swiftWeekday + 5) % 7
        let currentTotal = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)

        for activity in activities where activity.enabled {
            let rawStart = parseTimeToMinutes(activity.startTime) - activity.bufferBeforeMinutes
            let rawEnd = parseTimeToMinutes(activity.endTime) + activity.bufferAfterMinutes
            let start = max(0, rawStart)
            let end = rawEnd  // can exceed 1440 for overnight

            // Check if this activity matches today (or yesterday for overnight)
            let isToday = activity.dayOfWeek == mondayBased
            let yesterday = (mondayBased + 6) % 7
            let isOvernightFromYesterday = activity.dayOfWeek == yesterday && end > 1440

            var active = false
            if isToday {
                if end <= 1440 {
                    // Normal same-day activity
                    active = currentTotal >= start && currentTotal < end
                } else {
                    // Overnight: starts today, extends past midnight
                    active = currentTotal >= start
                }
            } else if isOvernightFromYesterday {
                // We're in the early morning part of an overnight activity from yesterday
                let overflowEnd = end - 1440
                active = currentTotal < overflowEnd
            }

            if active {
                let displayEnd = end > 1440 ? end - 1440 : end
                let endH = displayEnd / 60
                let endM = displayEnd % 60
                let endStr = String(format: "%02d:%02d", endH % 24, endM)
                return (activity, endStr)
            }
        }
        return (nil, nil)
    }
}
