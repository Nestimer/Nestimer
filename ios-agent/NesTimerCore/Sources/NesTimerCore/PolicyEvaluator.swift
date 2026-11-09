import Foundation

public enum ShieldReason: Equatable, Sendable, Codable {
    case downtime(until: String)
    case timeExpired
    case deviceCapReached
    /// The phone's date/time disagrees with the server's (or went backwards).
    case clockChanged
    /// Usage events couldn't be armed, so no lock would ever fire.
    case agentError
}

public enum OpenReason: Equatable, Sendable {
    case activity(endsAt: String)
    case temporaryUnlock
    case bonus
    case withinLimit
    case noLimit
}

public enum Decision: Equatable, Sendable {
    /// `remainingMinutes` is nil when screen time is not limited today.
    case open(remainingMinutes: Double?, why: OpenReason)
    case shield(ShieldReason)

    public var isShielded: Bool { if case .shield = self { return true } else { return false } }
}

/// The Mac agent's `PolicyEnforcer.evaluate` order, as a pure function:
/// activity → TOTP unlock → bonus → downtime → remaining < 1 → open.
public enum PolicyEvaluator {
    /// `deviceUsedMinutes` is the phone's own count for today (local, fresher than the
    /// snapshot). Other devices' usage comes from the server snapshot.
    public static func evaluate(policy: ServerPolicy, deviceUsedMinutes: Double, unlockUntil: Date?,
                                now: Date, calendar: Calendar) -> Decision {
        let remaining = remainingMinutes(policy: policy, deviceUsedMinutes: deviceUsedMinutes)

        if let endsAt = activeActivityEnd(policy.activities ?? [], now: now, calendar: calendar) {
            return .open(remainingMinutes: remaining, why: .activity(endsAt: endsAt))
        }
        if let until = unlockUntil, now < until {
            return .open(remainingMinutes: remaining, why: .temporaryUnlock)
        }
        if let until = policy.bonusUntilDate, now < until {
            return .open(remainingMinutes: remaining, why: .bonus)
        }
        if policy.downtimeEnabled,
           isInDowntime(start: policy.downtimeStart, end: policy.downtimeEnd, now: now, calendar: calendar) {
            return .shield(.downtime(until: policy.downtimeEnd))
        }
        guard let left = remaining else { return .open(remainingMinutes: nil, why: .noLimit) }
        if left < 1 {
            let source = RemainingTime.binding(limitMinutes: policy.screenTimeLimitMinutes,
                                               childUsedMinutes: childUsed(policy, deviceUsedMinutes),
                                               deviceCapMinutes: policy.deviceCapMinutes,
                                               deviceUsedMinutes: deviceUsedMinutes)
            return .shield(source == .deviceCap ? .deviceCapReached : .timeExpired)
        }
        return .open(remainingMinutes: left, why: .withinLimit)
    }

    public static func remainingMinutes(policy: ServerPolicy, deviceUsedMinutes: Double) -> Double? {
        guard policy.screenTimeEnabled else { return nil }
        return RemainingTime.minutes(limitMinutes: policy.screenTimeLimitMinutes,
                                     childUsedMinutes: childUsed(policy, deviceUsedMinutes),
                                     deviceCapMinutes: policy.deviceCapMinutes,
                                     deviceUsedMinutes: deviceUsedMinutes)
    }

    static func childUsed(_ policy: ServerPolicy, _ deviceUsed: Double) -> Double {
        policy.otherDevicesUsed + deviceUsed
    }

    // MARK: - Ported from PolicyEnforcer (now/calendar injected)

    static func parseTimeToMinutes(_ time: String) -> Int {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return 0 }
        return parts[0] * 60 + parts[1]
    }

    static func minuteOfDay(_ now: Date, _ calendar: Calendar) -> Int {
        calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
    }

    static func isInDowntime(start: String, end: String, now: Date, calendar: Calendar) -> Bool {
        let s = parseTimeToMinutes(start), e = parseTimeToMinutes(end)
        guard s != e else { return false }  // start == end means no downtime, not a 24 h lock
        let t = minuteOfDay(now, calendar)
        return s < e ? (t >= s && t < e) : (t >= s || t < e)
    }

    /// End time ("HH:MM") of the activity window (with buffers) covering `now`, if any.
    static func activeActivityEnd(_ activities: [ScheduledActivity], now: Date, calendar: Calendar) -> String? {
        let mondayBased = (calendar.component(.weekday, from: now) + 5) % 7  // Sun=1…Sat=7 → Mon=0…Sun=6
        let yesterday = (mondayBased + 6) % 7
        let t = minuteOfDay(now, calendar)

        for a in activities where a.enabled {
            let start = max(0, parseTimeToMinutes(a.startTime) - a.bufferBeforeMinutes)
            var end = parseTimeToMinutes(a.endTime) + a.bufferAfterMinutes
            if parseTimeToMinutes(a.endTime) <= parseTimeToMinutes(a.startTime) { end += 1440 }  // overnight
            var active = false
            if a.dayOfWeek == mondayBased {
                active = end <= 1440 ? (t >= start && t < end) : t >= start
            } else if a.dayOfWeek == yesterday && end > 1440 {
                active = t < end - 1440
            }
            if active {
                let shown = end > 1440 ? end - 1440 : end
                return String(format: "%02d:%02d", (shown / 60) % 24, shown % 60)
            }
        }
        return nil
    }
}
