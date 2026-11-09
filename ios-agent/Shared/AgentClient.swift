import Foundation
import NesTimerCore

/// /api/v1/agent/* over URLSession — same paths, headers and query as the Mac agent's APIClient.
struct AgentClient: AgentAPI {
    struct NotPaired: Error {}
    struct Unreachable: Error {}

    private var base: String? { Keychain.get(.serverURL) }
    private var token: String? { Keychain.get(.apiToken) }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    private func request(_ path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard let base, let token, let url = URL(string: base + path) else { throw NotPaired() }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown" }

    func fetchConfig(localDate: String) async throws -> ServerPolicy {
        let (data, resp) = try await Self.session.data(for: request("/api/v1/agent/config?date=\(localDate)&version=ios-\(Self.version)"))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Unreachable() }
        return try JSONDecoder().decode(ServerPolicy.self, from: data)
    }

    func reportUsage(date: String, totalMinutes: Double) async throws {
        let body = try JSONEncoder().encode(UsageReport(date: date, totalMinutes: totalMinutes))
        let (_, resp) = try await Self.session.data(for: request("/api/v1/agent/usage", method: "POST", body: body))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Unreachable() }
    }

    func verifyTOTP(code: String) async throws -> Bool {
        let body = try JSONSerialization.data(withJSONObject: ["code": code])
        // A transport error throws (→ offline fallback); any HTTP answer is final.
        let (data, resp) = try await Self.session.data(for: request("/api/v1/agent/verify-totp", method: "POST", body: body))
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return obj["valid"] as? Bool ?? false
    }

    /// One-time fetch at pairing.
    func fetchTOTPSecret() async throws -> String? {
        let (data, resp) = try await Self.session.data(for: request("/api/v1/agent/totp-secret"))
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["shared_secret"] as? String
    }
}
