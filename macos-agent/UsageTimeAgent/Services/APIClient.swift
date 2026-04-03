import Foundation

/// Response from GET /api/v1/agent/config
struct ServerPolicy: Codable {
    let downtimeEnabled: Bool
    let downtimeStart: String
    let downtimeEnd: String
    let screenTimeEnabled: Bool
    let screenTimeLimitMinutes: Int
    let usedMinutesToday: Double

    enum CodingKeys: String, CodingKey {
        case downtimeEnabled = "downtime_enabled"
        case downtimeStart = "downtime_start"
        case downtimeEnd = "downtime_end"
        case screenTimeEnabled = "screen_time_enabled"
        case screenTimeLimitMinutes = "screen_time_limit_minutes"
        case usedMinutesToday = "used_minutes_today"
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

    func fetchConfig() async throws -> ServerPolicy {
        let url = URL(string: "\(serverURL)/api/v1/agent/config")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.badResponse
        }
        return try JSONDecoder().decode(ServerPolicy.self, from: data)
    }

    func reportUsage(date: String, totalMinutes: Double) async throws {
        let url = URL(string: "\(serverURL)/api/v1/agent/usage")!
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

    enum APIError: Error {
        case badResponse
    }
}
