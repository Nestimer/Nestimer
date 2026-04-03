import Foundation

/// Agent configuration — loaded from a plist or environment.
struct AgentConfig {
    /// URL of the API server (e.g. "https://your-server.com")
    let serverURL: String
    /// Device-specific API token (obtained when registering the device)
    let apiToken: String
    /// How often to poll the server for config updates (seconds)
    let pollInterval: TimeInterval

    static func load() -> AgentConfig {
        let configPath = "/etc/usagetime/config.plist"

        if let data = FileManager.default.contents(atPath: configPath),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            return AgentConfig(
                serverURL: plist["ServerURL"] as? String ?? "http://localhost:8000",
                apiToken: plist["APIToken"] as? String ?? "",
                pollInterval: plist["PollInterval"] as? TimeInterval ?? 60
            )
        }

        // Fallback to environment variables
        return AgentConfig(
            serverURL: ProcessInfo.processInfo.environment["UTC_SERVER_URL"] ?? "http://localhost:8000",
            apiToken: ProcessInfo.processInfo.environment["UTC_API_TOKEN"] ?? "",
            pollInterval: TimeInterval(ProcessInfo.processInfo.environment["UTC_POLL_INTERVAL"] ?? "60") ?? 60
        )
    }
}
