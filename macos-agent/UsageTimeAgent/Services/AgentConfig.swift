import Foundation

/// Agent configuration — loaded from plist or environment.
struct AgentConfig {
    let serverURL: String
    let apiToken: String
    let pollInterval: TimeInterval

    static let configPath = "/etc/usagetime/config.plist"

    static func load() -> AgentConfig {
        // Try plist first
        if let data = FileManager.default.contents(atPath: configPath),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            return AgentConfig(
                serverURL: plist["ServerURL"] as? String ?? "http://localhost:8000",
                apiToken: plist["APIToken"] as? String ?? "",
                pollInterval: plist["PollInterval"] as? TimeInterval ?? 60
            )
        }

        // Fallback: UserDefaults (set via `defaults write com.usagetime.agent`)
        let defaults = UserDefaults.standard
        if let token = defaults.string(forKey: "APIToken"), !token.isEmpty {
            return AgentConfig(
                serverURL: defaults.string(forKey: "ServerURL") ?? "http://localhost:8000",
                apiToken: token,
                pollInterval: defaults.double(forKey: "PollInterval").nonZero ?? 60
            )
        }

        // Fallback: environment
        return AgentConfig(
            serverURL: ProcessInfo.processInfo.environment["UTC_SERVER_URL"] ?? "http://localhost:8000",
            apiToken: ProcessInfo.processInfo.environment["UTC_API_TOKEN"] ?? "",
            pollInterval: TimeInterval(ProcessInfo.processInfo.environment["UTC_POLL_INTERVAL"] ?? "60") ?? 60
        )
    }
}

private extension Double {
    var nonZero: Double? {
        self > 0 ? self : nil
    }
}
