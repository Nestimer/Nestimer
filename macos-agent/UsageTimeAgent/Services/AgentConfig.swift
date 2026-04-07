import Foundation

/// Agent configuration — loaded from plist or environment.
struct AgentConfig {
    let serverURL: String
    let apiToken: String
    let pollInterval: TimeInterval
    /// Dev mode: emergency unlock hotkey, auto-unlock after timeout, quit allowed, no self-protection.
    /// Activate via config plist key "DevMode", UserDefaults, or env var UTC_DEV_MODE=1.
    let devMode: Bool
    /// In dev mode, lock screen auto-dismisses after this many seconds (default 10).
    let devAutoUnlockSeconds: TimeInterval

    static let configPath = "/etc/usagetime/config.plist"

    /// True when running a Debug build (from Xcode or DerivedData).
    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Migrate old IP-based URLs to the HTTPS domain.
    static func migrateServerURL(_ url: String) -> String {
        // http://134.209.8.62:8000 → https://my.nestimer.com
        if url.contains("134.209.8.62") {
            let migrated = "https://my.nestimer.com"
            UserDefaults.standard.set(migrated, forKey: "ServerURL")
            NSLog("[NesTimer] Migrated server URL: \(url) → \(migrated)")
            return migrated
        }
        return url
    }

    static func load() -> AgentConfig {
        // Try plist first
        if let data = FileManager.default.contents(atPath: configPath),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            return AgentConfig(
                serverURL: migrateServerURL(plist["ServerURL"] as? String ?? "https://my.nestimer.com"),
                apiToken: plist["APIToken"] as? String ?? "",
                pollInterval: plist["PollInterval"] as? TimeInterval ?? 20,
                devMode: (plist["DevMode"] as? Bool ?? false) || isDebugBuild,
                devAutoUnlockSeconds: plist["DevAutoUnlockSeconds"] as? TimeInterval ?? 10
            )
        }

        // Fallback: UserDefaults (set via `defaults write com.usagetime.agent`)
        let defaults = UserDefaults.standard
        if let token = defaults.string(forKey: "APIToken"), !token.isEmpty {
            return AgentConfig(
                serverURL: migrateServerURL(defaults.string(forKey: "ServerURL") ?? "https://my.nestimer.com"),
                apiToken: token,
                pollInterval: defaults.double(forKey: "PollInterval").nonZero ?? 20,
                devMode: isDebugBuild,  // DevMode only via #if DEBUG, not UserDefaults (child could set it)
                devAutoUnlockSeconds: defaults.double(forKey: "DevAutoUnlockSeconds").nonZero ?? 10
            )
        }

        // Fallback: environment
        let env = ProcessInfo.processInfo.environment
        return AgentConfig(
            serverURL: migrateServerURL(env["UTC_SERVER_URL"] ?? "https://my.nestimer.com"),
            apiToken: env["UTC_API_TOKEN"] ?? "",
            pollInterval: TimeInterval(env["UTC_POLL_INTERVAL"] ?? "20") ?? 20,
            devMode: env["UTC_DEV_MODE"] == "1" || isDebugBuild,
            devAutoUnlockSeconds: TimeInterval(env["UTC_DEV_AUTO_UNLOCK"] ?? "10") ?? 10
        )
    }
}

private extension Double {
    var nonZero: Double? {
        self > 0 ? self : nil
    }
}
