import Foundation

/// Response from GET /api/v1/agent/config
struct ScheduledActivity: Codable {
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
}

struct ServerPolicy: Codable {
    let downtimeEnabled: Bool
    let downtimeStart: String
    let downtimeEnd: String
    let screenTimeEnabled: Bool
    let screenTimeLimitMinutes: Int
    let usedMinutesToday: Double
    let activities: [ScheduledActivity]?
    /// Parent-granted bonus window (ISO8601 UTC). Decoded into `bonusUntilDate`.
    let bonusUntil: String?
    /// This device's own usage today, exactly as the wire carried it — nil when the server
    /// omitted the field, i.e. any server older than the shared-budget release. Nil is NOT
    /// the same as 0: it means `usedMinutesToday` is this device's own total rather than the
    /// child's combined one, so nothing may be subtracted out of it (see `otherDevicesUsed`).
    private let deviceUsedMinutesReported: Double?
    /// Per-device ceiling within the shared budget. Nil means no ceiling.
    let deviceCapMinutes: Int?

    /// This device's own usage today; 0 when the server doesn't report it.
    var deviceUsedMinutes: Double { deviceUsedMinutesReported ?? 0 }

    /// True when the server breaks usage down per device, i.e. `usedMinutesToday` is the
    /// child's combined total across all their devices rather than just this one's.
    var reportsDeviceUsage: Bool { deviceUsedMinutesReported != nil }

    /// Usage the child racked up on their OTHER devices, per the server's snapshot.
    /// Against a pre-shared-budget server (no per-device breakdown) this is 0 and
    /// `usedMinutesToday` is treated as this device's own total — never double-counted.
    var otherDevicesUsed: Double {
        guard let own = deviceUsedMinutesReported else { return 0 }
        return max(0, usedMinutesToday - own)
    }

    init(
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
    init(from decoder: Decoder) throws {
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

    var bonusUntilDate: Date? {
        guard let s = bonusUntil else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }
}

/// Payload for POST /api/v1/agent/usage
struct UsageReport: Codable {
    let date: String
    let totalMinutes: Double

    enum CodingKeys: String, CodingKey {
        case date
        case totalMinutes = "total_minutes"
    }
}

class APIClient {
    private let serverURL: String
    private let apiToken: String
    private let session: URLSession

    init(serverURL: String, apiToken: String) {
        self.serverURL = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.apiToken = apiToken
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    func fetchConfig(localDate: String) async throws -> ServerPolicy {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        guard let url = URL(string: "\(serverURL)/api/v1/agent/config?date=\(localDate)&version=\(appVersion)") else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.badResponse
        }
        return try JSONDecoder().decode(ServerPolicy.self, from: data)
    }

    func reportUsage(date: String, totalMinutes: Double) async throws {
        guard let url = URL(string: "\(serverURL)/api/v1/agent/usage") else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = UsageReport(date: date, totalMinutes: totalMinutes)
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.badResponse
        }
    }

    func fetchTOTPSecret() async throws -> String? {
        guard let url = URL(string: "\(serverURL)/api/v1/agent/totp-secret") else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        struct SecretResponse: Codable { let sharedSecret: String
            enum CodingKeys: String, CodingKey { case sharedSecret = "shared_secret" }
        }
        return try? JSONDecoder().decode(SecretResponse.self, from: data).sharedSecret
    }

    enum APIError: Error {
        case badResponse
        case invalidURL
    }
}
