import Foundation

/// UsageTimeAgent — macOS daemon that enforces screen time limits and downtime.
/// Runs as a LaunchDaemon (root) to prevent the child from killing it.

@main
struct UsageTimeAgentApp {
    static func main() async {
        log("UsageTimeAgent starting...")

        let config = AgentConfig.load()
        guard !config.apiToken.isEmpty else {
            log("ERROR: No API token configured. Set it in /etc/usagetime/config.plist or UTC_API_TOKEN env var.")
            log("Register this device via the web dashboard first, then configure the token.")
            Foundation.exit(1)
        }

        let client = APIClient(serverURL: config.serverURL, apiToken: config.apiToken)
        let tracker = UsageTracker()
        let enforcer = PolicyEnforcer()

        log("Connected to server: \(config.serverURL)")
        log("Poll interval: \(Int(config.pollInterval))s")

        // Main loop
        var lastSyncTime: Date = .distantPast
        let syncInterval: TimeInterval = config.pollInterval

        while true {
            // 1. Tick usage tracker
            let usedMinutes = tracker.tick()

            // 2. Sync with server periodically
            let now = Date()
            if now.timeIntervalSince(lastSyncTime) >= syncInterval {
                lastSyncTime = now

                do {
                    // Fetch latest policy
                    let policy = try await client.fetchConfig()

                    // Sync usage with server
                    tracker.setUsedMinutes(policy.usedMinutesToday, forDate: tracker.currentDateString())

                    // Report our tracked usage back
                    try await client.reportUsage(
                        date: tracker.currentDateString(),
                        totalMinutes: usedMinutes
                    )

                    // Enforce rules
                    enforcer.evaluate(policy: policy, usedMinutesToday: usedMinutes)

                    log("Sync OK — used: \(String(format: "%.1f", usedMinutes))min, limit: \(policy.screenTimeLimitMinutes)min, downtime: \(policy.downtimeEnabled ? "\(policy.downtimeStart)-\(policy.downtimeEnd)" : "off")")
                } catch {
                    log("Sync failed: \(error.localizedDescription) — using cached policy")
                    // Even without network, enforce based on local tracking
                }
            }

            // Sleep for tick interval
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000) // 30 seconds
        }
    }

    static func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        NSLog("[UsageTimeAgent \(timestamp)] \(message)")
    }
}
