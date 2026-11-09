import Foundation
@testable import NesTimerCore

enum Fx {
    static var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Kyiv")!
        return c
    }()

    /// 2026-11-09 is a Monday. `day` offsets from it.
    static func at(_ hour: Int, _ minute: Int = 0, day: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: 9 + day, hour: hour, minute: minute))!
    }

    static func policy(limit: Int = 120, limitEnabled: Bool = true, used: Double = 0, deviceUsed: Double = 0,
                       cap: Int? = nil, downtime: (String, String)? = nil, activities: [ScheduledActivity] = [],
                       bonusUntil: Date? = nil) -> ServerPolicy {
        var bonus: String?
        if let b = bonusUntil {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
            bonus = f.string(from: b)
        }
        return ServerPolicy(downtimeEnabled: downtime != nil, downtimeStart: downtime?.0 ?? "22:00",
                            downtimeEnd: downtime?.1 ?? "07:00", screenTimeEnabled: limitEnabled,
                            screenTimeLimitMinutes: limit, usedMinutesToday: used, activities: activities,
                            bonusUntil: bonus, deviceUsedMinutes: deviceUsed, deviceCapMinutes: cap)
    }
}
