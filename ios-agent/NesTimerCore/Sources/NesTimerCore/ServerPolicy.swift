import Foundation

// Wire models for /api/v1/agent/*. Copied from macos-agent/NesTimerAgent/Services/APIClient.swift
// (keep the two in sync); made public/Sendable/Equatable so the snapshot can be stored.

/// Response from GET /api/v1/agent/config
public struct ScheduledActivity: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let dayOfWeek: Int
    public let startTime: String
    public let endTime: String
    public let bufferBeforeMinutes: Int
    public let bufferAfterMinutes: Int
    public let enabled: Bool

    public init(id: String, name: String, dayOfWeek: Int, startTime: String, endTime: String,
                bufferBeforeMinutes: Int = 5, bufferAfterMinutes: Int = 5, enabled: Bool = true) {
        self.id = id; self.name = name; self.dayOfWeek = dayOfWeek
        self.startTime = startTime; self.endTime = endTime
        self.bufferBeforeMinutes = bufferBeforeMinutes; self.bufferAfterMinutes = bufferAfterMinutes
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey {
        case id, name, enabled
        case dayOfWeek = "day_of_week"
        case startTime = "start_time"
        case endTime = "end_time"
        case bufferBeforeMinutes = "buffer_before_minutes"
        case bufferAfterMinutes = "buffer_after_minutes"
    }
}

public struct ServerPolicy: Codable, Equatable, Sendable {
    public let downtimeEnabled: Bool
    public let downtimeStart: String
    public let downtimeEnd: String
    public let screenTimeEnabled: Bool
    public let screenTimeLimitMinutes: Int
    public let usedMinutesToday: Double
    public let activities: [ScheduledActivity]?
    /// Parent-granted bonus window (ISO8601 UTC). Decoded into `bonusUntilDate`.
    public let bonusUntil: String?
    /// This device's own usage today, exactly as the wire carried it — nil when the server
    /// omitted the field, i.e. any server older than the shared-budget release. Nil is NOT
    /// the same as 0: it means `usedMinutesToday` is this device's own total rather than the
    /// child's combined one, so nothing may be subtracted out of it (see `otherDevicesUsed`).
    private let deviceUsedMinutesReported: Double?
    /// Per-device ceiling within the shared budget. Nil means no ceiling.
    public let deviceCapMinutes: Int?

    /// This device's own usage today; 0 when the server doesn't report it.
    public var deviceUsedMinutes: Double { deviceUsedMinutesReported ?? 0 }

    /// True when the server breaks usage down per device, i.e. `usedMinutesToday` is the
    /// child's combined total across all their devices rather than just this one's.
    public var reportsDeviceUsage: Bool { deviceUsedMinutesReported != nil }

    /// What the agent's local counter — which holds THIS device's own usage — must be
    /// reconciled against. On a server that reports the per-device breakdown that is
    /// `deviceUsedMinutes`; on an older one there is no breakdown and `usedMinutesToday`
    /// IS this device's own total, so reconciling against `deviceUsedMinutes` (0 there)
    /// would wipe the counter on the first sync and re-zero it on every one after —
    /// UsageTracker reads a value that far below the local one as a parent reset — and
    /// the child's screen time would never accumulate at all.
    public var deviceUsedMinutesForReconciliation: Double {
        reportsDeviceUsage ? deviceUsedMinutes : usedMinutesToday
    }

    /// Usage the child racked up on their OTHER devices, per the server's snapshot.
    /// Against a pre-shared-budget server (no per-device breakdown) this is 0 and
    /// `usedMinutesToday` is treated as this device's own total — never double-counted.
    public var otherDevicesUsed: Double {
        guard let own = deviceUsedMinutesReported else { return 0 }
        return max(0, usedMinutesToday - own)
    }

    public init(
        downtimeEnabled: Bool,
        downtimeStart: String,
        downtimeEnd: String,
        screenTimeEnabled: Bool,
        screenTimeLimitMinutes: Int,
        usedMinutesToday: Double,
        activities: [ScheduledActivity]? = nil,
        bonusUntil: String? = nil,
        deviceUsedMinutes: Double? = nil,
        deviceCapMinutes: Int? = nil
    ) {
        self.downtimeEnabled = downtimeEnabled
        self.downtimeStart = downtimeStart
        self.downtimeEnd = downtimeEnd
        self.screenTimeEnabled = screenTimeEnabled
        self.screenTimeLimitMinutes = screenTimeLimitMinutes
        self.usedMinutesToday = usedMinutesToday
        self.activities = activities
        self.bonusUntil = bonusUntil
        self.deviceUsedMinutesReported = deviceUsedMinutes
        self.deviceCapMinutes = deviceCapMinutes
    }

    enum CodingKeys: String, CodingKey {
        case downtimeEnabled = "downtime_enabled"
        case downtimeStart = "downtime_start"
        case downtimeEnd = "downtime_end"
        case screenTimeEnabled = "screen_time_enabled"
        case screenTimeLimitMinutes = "screen_time_limit_minutes"
        case usedMinutesToday = "used_minutes_today"
        case activities
        case bonusUntil = "bonus_until"
        case deviceUsedMinutesReported = "device_used_minutes"
        case deviceCapMinutes = "device_cap_minutes"
    }

    /// Custom decoder: `deviceUsedMinutes`/`deviceCapMinutes` are optional on the wire
    /// because a server older than the shared-budget release omits them entirely.
    /// Decoding must NOT throw in that case — a throw here would leave the device
    /// unmanaged (PolicyEnforcer never runs) until the server is upgraded.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        downtimeEnabled = try c.decode(Bool.self, forKey: .downtimeEnabled)
        downtimeStart = try c.decode(String.self, forKey: .downtimeStart)
        downtimeEnd = try c.decode(String.self, forKey: .downtimeEnd)
        screenTimeEnabled = try c.decode(Bool.self, forKey: .screenTimeEnabled)
        screenTimeLimitMinutes = try c.decode(Int.self, forKey: .screenTimeLimitMinutes)
        usedMinutesToday = try c.decode(Double.self, forKey: .usedMinutesToday)
        activities = try c.decodeIfPresent([ScheduledActivity].self, forKey: .activities)
        bonusUntil = try c.decodeIfPresent(String.self, forKey: .bonusUntil)
        deviceUsedMinutesReported = try c.decodeIfPresent(Double.self, forKey: .deviceUsedMinutesReported)
        deviceCapMinutes = try c.decodeIfPresent(Int.self, forKey: .deviceCapMinutes)
    }

    public var bonusUntilDate: Date? {
        guard let s = bonusUntil else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }
}

/// Payload for POST /api/v1/agent/usage
public struct UsageReport: Codable, Equatable, Sendable {
    public let date: String
    public let totalMinutes: Double

    public init(date: String, totalMinutes: Double) { self.date = date; self.totalMinutes = totalMinutes }

    enum CodingKeys: String, CodingKey {
        case date
        case totalMinutes = "total_minutes"
    }
}
