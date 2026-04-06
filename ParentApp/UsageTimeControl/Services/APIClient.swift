import Foundation

/// API client for communicating with the UsageTimeController server.
actor APIClient {
    static let shared = APIClient()

    private var baseURL: String {
        KeychainHelper.getServerURL()
    }

    private var token: String? {
        KeychainHelper.getToken()
    }

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    // MARK: - Auth

    func register(name: String, email: String, password: String) async throws -> TokenResponse {
        let body = RegisterRequest(email: email, password: password, name: name)
        let response: TokenResponse = try await post("/api/v1/auth/register", body: body, auth: false)
        KeychainHelper.saveToken(response.accessToken)
        return response
    }

    func login(email: String, password: String) async throws -> TokenResponse {
        let body = LoginRequest(email: email, password: password)
        let response: TokenResponse = try await post("/api/v1/auth/login", body: body, auth: false)
        KeychainHelper.saveToken(response.accessToken)
        return response
    }

    func me() async throws -> User {
        try await get("/api/v1/auth/me")
    }

    func logout() {
        KeychainHelper.deleteToken()
    }

    // MARK: - Devices

    func listDevices() async throws -> [Device] {
        try await get("/api/v1/devices")
    }

    func getDevice(_ id: String) async throws -> Device {
        try await get("/api/v1/devices/\(id)")
    }

    func createDevice(name: String, childName: String) async throws -> Device {
        let body = CreateDeviceRequest(name: name, childName: childName)
        return try await post("/api/v1/devices", body: body)
    }

    func updateDevice(_ id: String, update: DeviceUpdateRequest) async throws -> Device {
        try await request("PATCH", path: "/api/v1/devices/\(id)", body: update)
    }

    func deleteDevice(_ id: String) async throws {
        let _: [String: Bool] = try await request("DELETE", path: "/api/v1/devices/\(id)")
    }

    // MARK: - Policy

    func getPolicy(deviceId: String) async throws -> Policy {
        try await get("/api/v1/devices/\(deviceId)/policy")
    }

    func updatePolicy(deviceId: String, update: PolicyUpdate) async throws -> Policy {
        try await request("PUT", path: "/api/v1/devices/\(deviceId)/policy", body: update)
    }

    // MARK: - Usage

    func getUsage(deviceId: String, days: Int = 7) async throws -> [UsageEntry] {
        try await get("/api/v1/devices/\(deviceId)/usage?days=\(days)")
    }

    // MARK: - Activities

    func listActivities(deviceId: String) async throws -> [Activity] {
        try await get("/api/v1/devices/\(deviceId)/activities")
    }

    func createActivity(deviceId: String, activity: ActivityCreate) async throws -> Activity {
        try await post("/api/v1/devices/\(deviceId)/activities", body: activity)
    }

    func updateActivity(deviceId: String, activityId: String, update: ActivityUpdate) async throws -> Activity {
        try await request("PUT", path: "/api/v1/devices/\(deviceId)/activities/\(activityId)", body: update)
    }

    func deleteActivity(deviceId: String, activityId: String) async throws {
        let _: [String: Bool] = try await request("DELETE", path: "/api/v1/devices/\(deviceId)/activities/\(activityId)")
    }

    // MARK: - Networking

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await request("GET", path: path)
    }

    private func post<T: Decodable, B: Encodable>(_ path: String, body: B, auth: Bool = true) async throws -> T {
        try await request("POST", path: path, body: body, auth: auth)
    }

    private func request<T: Decodable>(
        _ method: String,
        path: String,
        body: (any Encodable)? = nil,
        auth: Bool = true
    ) async throws -> T {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if auth, let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.httpBody = try encoder.encode(body)
        }

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        if http.statusCode == 401 {
            KeychainHelper.deleteToken()
            throw APIError.unauthorized
        }

        guard (200...299).contains(http.statusCode) else {
            if let error = try? decoder.decode(ErrorResponse.self, from: data) {
                throw APIError.server(error.detail)
            }
            throw APIError.httpError(http.statusCode)
        }

        return try decoder.decode(T.self, from: data)
    }
}

struct ErrorResponse: Decodable {
    let detail: String
}

enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case unauthorized
    case httpError(Int)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .invalidResponse: return "Invalid server response"
        case .unauthorized: return "Session expired, please sign in again"
        case .httpError(let code): return "Server error: \(code)"
        case .server(let msg): return msg
        }
    }
}
