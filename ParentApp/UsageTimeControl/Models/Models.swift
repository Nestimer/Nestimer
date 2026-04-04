import Foundation

// MARK: - Auth

struct LoginRequest: Encodable {
    let email: String
    let password: String
}

struct RegisterRequest: Encodable {
    let email: String
    let password: String
    let name: String
}

struct TokenResponse: Decodable {
    let accessToken: String
    let tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
    }
}

struct User: Decodable, Identifiable {
    let id: String
    let email: String
    let name: String
}

// MARK: - Devices

struct CreateDeviceRequest: Encodable {
    let name: String
    let childName: String

    enum CodingKeys: String, CodingKey {
        case name
        case childName = "child_name"
    }
}

struct Device: Decodable, Identifiable {
    let id: String
    let name: String
    let childName: String
    let apiToken: String?
    let sharedSecret: String?
    let lastSeen: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case childName = "child_name"
        case apiToken = "api_token"
        case sharedSecret = "shared_secret"
        case lastSeen = "last_seen"
        case createdAt = "created_at"
    }

    var isOnline: Bool {
        guard let lastSeen, let date = ISO8601DateFormatter().date(from: lastSeen) else { return false }
        return Date().timeIntervalSince(date) < 180 // 3 minutes
    }

    var lastSeenText: String {
        guard let lastSeen, let date = ISO8601DateFormatter().date(from: lastSeen) else { return "never" }
        let diff = Date().timeIntervalSince(date)
        if diff < 120 { return "just now" }
        if diff < 3600 { return "\(Int(diff / 60)) min ago" }
        if diff < 86400 { return "\(Int(diff / 3600)) hr ago" }
        return "\(Int(diff / 86400)) days ago"
    }
}

// MARK: - Policy

struct Policy: Decodable {
    let downtimeEnabled: Bool
    let downtimeStart: String
    let downtimeEnd: String
    let downtimeWeekdayStart: String?
    let downtimeWeekdayEnd: String?
    let downtimeWeekendStart: String?
    let downtimeWeekendEnd: String?
    let screenTimeEnabled: Bool
    let screenTimeLimitMinutes: Int
    let screenTimeWeekendLimitMinutes: Int?
    let screenTimeMonMinutes: Int?
    let screenTimeTueMinutes: Int?
    let screenTimeWedMinutes: Int?
    let screenTimeThuMinutes: Int?
    let screenTimeFriMinutes: Int?
    let screenTimeSatMinutes: Int?
    let screenTimeSunMinutes: Int?

    enum CodingKeys: String, CodingKey {
        case downtimeEnabled = "downtime_enabled"
        case downtimeStart = "downtime_start"
        case downtimeEnd = "downtime_end"
        case downtimeWeekdayStart = "downtime_weekday_start"
        case downtimeWeekdayEnd = "downtime_weekday_end"
        case downtimeWeekendStart = "downtime_weekend_start"
        case downtimeWeekendEnd = "downtime_weekend_end"
        case screenTimeEnabled = "screen_time_enabled"
        case screenTimeLimitMinutes = "screen_time_limit_minutes"
        case screenTimeWeekendLimitMinutes = "screen_time_weekend_limit_minutes"
        case screenTimeMonMinutes = "screen_time_mon_minutes"
        case screenTimeTueMinutes = "screen_time_tue_minutes"
        case screenTimeWedMinutes = "screen_time_wed_minutes"
        case screenTimeThuMinutes = "screen_time_thu_minutes"
        case screenTimeFriMinutes = "screen_time_fri_minutes"
        case screenTimeSatMinutes = "screen_time_sat_minutes"
        case screenTimeSunMinutes = "screen_time_sun_minutes"
    }
}

struct PolicyUpdate: Encodable {
    var downtimeEnabled: Bool?
    var downtimeStart: String?
    var downtimeEnd: String?
    var downtimeWeekdayStart: String?
    var downtimeWeekdayEnd: String?
    var downtimeWeekendStart: String?
    var downtimeWeekendEnd: String?
    var screenTimeEnabled: Bool?
    var screenTimeLimitMinutes: Int?
    var screenTimeWeekendLimitMinutes: Int?
    var screenTimeMonMinutes: Int?
    var screenTimeTueMinutes: Int?
    var screenTimeWedMinutes: Int?
    var screenTimeThuMinutes: Int?
    var screenTimeFriMinutes: Int?
    var screenTimeSatMinutes: Int?
    var screenTimeSunMinutes: Int?

    enum CodingKeys: String, CodingKey {
        case downtimeEnabled = "downtime_enabled"
        case downtimeStart = "downtime_start"
        case downtimeEnd = "downtime_end"
        case downtimeWeekdayStart = "downtime_weekday_start"
        case downtimeWeekdayEnd = "downtime_weekday_end"
        case downtimeWeekendStart = "downtime_weekend_start"
        case downtimeWeekendEnd = "downtime_weekend_end"
        case screenTimeEnabled = "screen_time_enabled"
        case screenTimeLimitMinutes = "screen_time_limit_minutes"
        case screenTimeWeekendLimitMinutes = "screen_time_weekend_limit_minutes"
        case screenTimeMonMinutes = "screen_time_mon_minutes"
        case screenTimeTueMinutes = "screen_time_tue_minutes"
        case screenTimeWedMinutes = "screen_time_wed_minutes"
        case screenTimeThuMinutes = "screen_time_thu_minutes"
        case screenTimeFriMinutes = "screen_time_fri_minutes"
        case screenTimeSatMinutes = "screen_time_sat_minutes"
        case screenTimeSunMinutes = "screen_time_sun_minutes"
    }
}

// MARK: - Usage

struct UsageEntry: Decodable, Identifiable {
    let date: String
    let totalMinutes: Double

    var id: String { date }

    enum CodingKeys: String, CodingKey {
        case date
        case totalMinutes = "total_minutes"
    }

    var formattedTime: String {
        let h = Int(totalMinutes) / 60
        let m = Int(totalMinutes) % 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    var dayLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let d = formatter.date(from: date) else { return date }
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "EE, d"
        return formatter.string(from: d)
    }
}

// MARK: - Activities

struct Activity: Decodable, Identifiable {
    let id: String
    let name: String
    let dayOfWeek: Int
    let startTime: String
    let endTime: String
    let bufferBeforeMinutes: Int
    let bufferAfterMinutes: Int
    let enabled: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, enabled
        case dayOfWeek = "day_of_week"
        case startTime = "start_time"
        case endTime = "end_time"
        case bufferBeforeMinutes = "buffer_before_minutes"
        case bufferAfterMinutes = "buffer_after_minutes"
    }

    var dayLabel: String {
        ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][max(0, min(6, dayOfWeek))]
    }
}

struct ActivityCreate: Encodable {
    let name: String
    let dayOfWeek: Int
    let startTime: String
    let endTime: String
    let bufferBeforeMinutes: Int
    let bufferAfterMinutes: Int
    let enabled: Bool

    enum CodingKeys: String, CodingKey {
        case name, enabled
        case dayOfWeek = "day_of_week"
        case startTime = "start_time"
        case endTime = "end_time"
        case bufferBeforeMinutes = "buffer_before_minutes"
        case bufferAfterMinutes = "buffer_after_minutes"
    }
}

struct ActivityUpdate: Encodable {
    var name: String?
    var dayOfWeek: Int?
    var startTime: String?
    var endTime: String?
    var bufferBeforeMinutes: Int?
    var bufferAfterMinutes: Int?
    var enabled: Bool?

    enum CodingKeys: String, CodingKey {
        case name, enabled
        case dayOfWeek = "day_of_week"
        case startTime = "start_time"
        case endTime = "end_time"
        case bufferBeforeMinutes = "buffer_before_minutes"
        case bufferAfterMinutes = "buffer_after_minutes"
    }
}

// MARK: - Helpers

func formatMinutes(_ m: Int) -> String {
    let h = m / 60
    let min = m % 60
    if h > 0 { return "\(h)h \(min)m" }
    return "\(min)m"
}
