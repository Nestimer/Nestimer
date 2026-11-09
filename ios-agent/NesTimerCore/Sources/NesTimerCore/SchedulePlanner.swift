import Foundation

public struct PlannedWindow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case downtime, activity, bonusEnd, heartbeat }
    public let name: String
    public let start: Date
    public let end: Date
    public let kind: Kind

    public init(name: String, start: Date, end: Date, kind: Kind) {
        self.name = name; self.start = start; self.end = end; self.kind = kind
    }
}

/// Downtime and activity windows to register as DeviceActivity schedules, so the monitor
/// extension wakes at their boundaries. The *decision* at each wake is still made by
/// PolicyEvaluator from the real times; these windows only provide the wake-ups.
public enum SchedulePlanner {
    /// DeviceActivity rejects intervals shorter than 15 minutes.
    public static let minimumLength: TimeInterval = 15 * 60
    /// iOS allows ~20 activities: daily counting, heartbeat and bonus end leave 17.
    public static let maxWindows = 17
    /// How often the heartbeat wakes the monitor even with no usage and no schedule edge.
    public static let heartbeatInterval: TimeInterval = 15 * 60

    /// A window ending at the next quarter hour that is more than a minute away (iOS may
    /// not deliver an edge that close), so a stale decision heals itself within 15 minutes
    /// and parent changes reach a locked phone. The name is stable within a slot, so
    /// re-planning doesn't restart it.
    public static func heartbeat(now: Date) -> PlannedWindow {
        let q = heartbeatInterval
        let end = Date(timeIntervalSince1970: ((now.timeIntervalSince1970 + 60) / q).rounded(.down) * q + q)
        return PlannedWindow(name: "heartbeat-\(Int(end.timeIntervalSince1970))",
                             start: end.addingTimeInterval(-q), end: end, kind: .heartbeat)
    }

    public static func plan(policy: ServerPolicy, now: Date, calendar: Calendar,
                            horizon: TimeInterval = 24 * 3600) -> [PlannedWindow] {
        let limit = now.addingTimeInterval(horizon)
        let today = calendar.startOfDay(for: now)
        var out: [PlannedWindow] = []

        for dayOffset in -1...1 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }

            // Downtime: today's times as resolved by the server, laid on each nearby day.
            if policy.downtimeEnabled,
               let w = window(day: day, start: PolicyEvaluator.parseTimeToMinutes(policy.downtimeStart),
                              end: PolicyEvaluator.parseTimeToMinutes(policy.downtimeEnd), calendar: calendar) {
                out.append(PlannedWindow(name: "downtime-\(stamp(w.0, calendar))-\(stamp(w.1, calendar))", start: w.0, end: w.1, kind: .downtime))
            }

            let mondayBased = (calendar.component(.weekday, from: day) + 5) % 7
            for a in (policy.activities ?? []) where a.enabled && a.dayOfWeek == mondayBased {
                let s = PolicyEvaluator.parseTimeToMinutes(a.startTime)
                var e = PolicyEvaluator.parseTimeToMinutes(a.endTime)
                if e <= s { e += 1440 }
                if let w = window(day: day, start: s - a.bufferBeforeMinutes, end: e + a.bufferAfterMinutes,
                                  calendar: calendar, overnightAllowed: false) {
                    out.append(PlannedWindow(name: "activity-\(a.id)-\(stamp(w.0, calendar))-\(stamp(w.1, calendar))", start: w.0, end: w.1, kind: .activity))
                }
            }
        }

        return Array(out
            .filter { $0.end > now && $0.start < limit }
            .map(padded)
            .sorted { $0.start < $1.start }
            .prefix(maxWindows))
    }

    /// `start`/`end` in minutes from `day`'s midnight. With `overnightAllowed`, end <= start
    /// means the window ends the next day (downtime); start == end means no window.
    private static func window(day: Date, start: Int, end: Int, calendar: Calendar,
                               overnightAllowed: Bool = true) -> (Date, Date)? {
        guard start != end else { return nil }
        var endMinutes = end
        if overnightAllowed && end < start { endMinutes += 1440 }
        guard endMinutes > start,
              let s = calendar.date(byAdding: .minute, value: start, to: day),
              let e = calendar.date(byAdding: .minute, value: endMinutes, to: day) else { return nil }
        return (s, e)
    }

    private static func padded(_ w: PlannedWindow) -> PlannedWindow {
        guard w.end.timeIntervalSince(w.start) < minimumLength else { return w }
        return PlannedWindow(name: w.name, start: w.start, end: w.start.addingTimeInterval(minimumLength), kind: w.kind)
    }

    private static func stamp(_ d: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        return String(format: "%04d%02d%02d%02d%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!)
    }
}
