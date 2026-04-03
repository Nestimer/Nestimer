import Foundation

/// Core logic: decides whether to lock/unlock based on current policy and usage.
class PolicyEnforcer {
    private let screenLocker = ScreenLocker()
    private var currentPolicy: ServerPolicy?
    private var warningShown = false

    /// Evaluate rules and enforce lock/unlock.
    func evaluate(policy: ServerPolicy, usedMinutesToday: Double) {
        currentPolicy = policy

        // 1. Check downtime
        if policy.downtimeEnabled && isInDowntime(start: policy.downtimeStart, end: policy.downtimeEnd) {
            screenLocker.lock(reason: .downtime(until: policy.downtimeEnd))
            return
        }

        // 2. Check screen time limit
        if policy.screenTimeEnabled {
            let limitMinutes = Double(policy.screenTimeLimitMinutes)
            let remaining = limitMinutes - usedMinutesToday

            if remaining <= 0 {
                screenLocker.lock(reason: .screenTimeExceeded)
                return
            }

            // Warning at 15 minutes remaining
            if remaining <= 15 && !warningShown {
                warningShown = true
                showNotification(
                    title: "Экранное время",
                    body: "Осталось \(Int(remaining)) минут"
                )
            }

            // Reset warning flag if more time was added
            if remaining > 15 {
                warningShown = false
            }
        }

        // No restrictions active — unlock if locked
        screenLocker.unlock()
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
            // Same day range (e.g., 13:00 - 15:00)
            return currentTotal >= startTotal && currentTotal < endTotal
        } else {
            // Overnight range (e.g., 22:00 - 08:00)
            return currentTotal >= startTotal || currentTotal < endTotal
        }
    }

    private func parseTimeToMinutes(_ time: String) -> Int {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return 0 }
        return parts[0] * 60 + parts[1]
    }

    // MARK: - Notifications

    private func showNotification(title: String, body: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "display notification \"\(body)\" with title \"\(title)\""
        ]
        try? process.run()
    }
}
