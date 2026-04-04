import AppKit
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController!
    private var agentConfig: AgentConfig!
    private var apiClient: APIClient!
    private var usageTracker: UsageTracker!
    private var policyEnforcer: PolicyEnforcer!
    private var notificationManager: NotificationManager!
    private var selfProtection: SelfProtection!

    private var syncTimer: Timer?
    private var tickTimer: Timer?
    /// Cached TOTP shared secret (received from server, persisted in UserDefaults for offline use).
    private var sharedSecret: String? {
        get { UserDefaults.standard.string(forKey: "totp_shared_secret") }
        set { UserDefaults.standard.set(newValue, forKey: "totp_shared_secret") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[UsageTimeAgent] Application starting...")

        // Load config
        agentConfig = AgentConfig.load()

        guard !agentConfig.apiToken.isEmpty else {
            NSLog("[UsageTimeAgent] ERROR: No API token configured.")
            showSetupRequiredAlert()
            return
        }

        if agentConfig.devMode {
            NSLog("[UsageTimeAgent] ⚠️ DEV MODE ENABLED — lock screen will auto-dismiss, quit allowed")
        }

        // Initialize services
        apiClient = APIClient(serverURL: agentConfig.serverURL, apiToken: agentConfig.apiToken)
        usageTracker = UsageTracker()
        notificationManager = NotificationManager()
        policyEnforcer = PolicyEnforcer(notificationManager: notificationManager)
        selfProtection = SelfProtection()

        // Configure dev mode on enforcer (auto-unlock, emergency hotkey, floating window)
        policyEnforcer.configureDevMode(
            enabled: agentConfig.devMode,
            autoUnlockSeconds: agentConfig.devAutoUnlockSeconds
        )

        // Wire up TOTP code handler on lock screen
        policyEnforcer.setCodeHandler { [weak self] code in
            self?.handleCodeSubmission(code)
        }

        // Initialize menu bar
        statusBar = StatusBarController(usageTracker: usageTracker)
        statusBar.devMode = agentConfig.devMode

        // Request notification permissions
        notificationManager.requestPermission()

        // Start self-protection (skip in dev mode — allows normal quit)
        if !agentConfig.devMode {
            selfProtection.start()
        } else {
            NSLog("[UsageTimeAgent] DEV: Self-protection DISABLED")
        }

        // Timer intervals: faster in dev mode for quick testing
        let tickInterval: TimeInterval = agentConfig.devMode ? 5 : 30
        let syncInterval: TimeInterval = agentConfig.devMode ? 10 : agentConfig.pollInterval

        // Start tracking timer
        tickTimer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            self?.performTick()
        }
        // Fire immediately
        performTick()

        // Start server sync timer
        syncTimer = Timer.scheduledTimer(withTimeInterval: syncInterval, repeats: true) { [weak self] _ in
            Task { await self?.performSync() }
        }
        // Initial sync
        Task { await performSync() }

        // Keep timers alive when menu is open
        RunLoop.current.add(tickTimer!, forMode: .common)
        RunLoop.current.add(syncTimer!, forMode: .common)

        NSLog("[UsageTimeAgent] Started. Server: \(agentConfig.serverURL), poll: \(Int(syncInterval))s, devMode: \(agentConfig.devMode)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        tickTimer?.invalidate()
        syncTimer?.invalidate()
    }

    // MARK: - Core loop

    private func performTick() {
        // Pause counting during scheduled activity window
        if policyEnforcer.activeActivity != nil {
            let current = usageTracker.getUsedMinutesToday()
            statusBar?.updateDisplay(usedMinutes: current)
            return
        }
        let usedMinutes = usageTracker.tick()
        statusBar?.updateDisplay(usedMinutes: usedMinutes)
    }

    private func performSync() async {
        let usedMinutes = usageTracker.getUsedMinutesToday()

        do {
            // Fetch policy from server
            let policy = try await apiClient.fetchConfig()

            // Sync usage with server state
            usageTracker.setUsedMinutes(policy.usedMinutesToday, forDate: usageTracker.currentDateString())

            // Report our usage back
            try await apiClient.reportUsage(
                date: usageTracker.currentDateString(),
                totalMinutes: usedMinutes
            )

            // Cache the shared secret for offline TOTP verification
            if let secret = policy.sharedSecret {
                self.sharedSecret = secret
            }

            // Enforce policy (lock/unlock, warnings)
            await MainActor.run {
                policyEnforcer.evaluate(policy: policy, usedMinutesToday: usedMinutes)
                statusBar?.updatePolicy(policy: policy)
                statusBar?.activeActivityName = policyEnforcer.activeActivity?.name
                statusBar?.activeActivityEndsAt = policyEnforcer.activeActivityEndsAt
            }

            NSLog("[UsageTimeAgent] Sync OK — used: \(String(format: "%.1f", usedMinutes))m, limit: \(policy.screenTimeLimitMinutes)m")
        } catch {
            NSLog("[UsageTimeAgent] Sync failed: \(error.localizedDescription)")
        }
    }

    // MARK: - TOTP code handling

    private func handleCodeSubmission(_ code: String) {
        guard let secret = sharedSecret else {
            NSLog("[UsageTimeAgent] TOTP: No shared secret available")
            return
        }
        if TOTPGenerator.verifyCode(secretHex: secret, code: code) {
            NSLog("[UsageTimeAgent] TOTP: Code accepted — granting 30 minutes")
            policyEnforcer.grantTemporaryAccess(minutes: 30)
        } else {
            NSLog("[UsageTimeAgent] TOTP: Code rejected")
        }
    }

    // MARK: - Setup alert

    private func showSetupRequiredAlert() {
        let alert = NSAlert()
        alert.messageText = "UsageTime Setup"
        alert.informativeText = "Paste the setup string from the parent dashboard.\nFormat: http://server:8000|token"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Quit")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
        input.placeholderString = "http://server:8000|your-agent-token"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            NSApp.terminate(nil)
            return
        }

        let setupString = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = setupString.components(separatedBy: "|")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            let err = NSAlert()
            err.messageText = "Invalid setup string"
            err.informativeText = "Expected format: http://server:8000|token\nGot: \(setupString)"
            err.alertStyle = .critical
            err.runModal()
            NSApp.terminate(nil)
            return
        }

        let serverURL = parts[0]
        let apiToken = parts[1]

        // Save to UserDefaults so it persists across restarts
        let defaults = UserDefaults.standard
        defaults.set(serverURL, forKey: "ServerURL")
        defaults.set(apiToken, forKey: "APIToken")
        NSLog("[UsageTimeAgent] Setup saved: server=\(serverURL)")

        // Restart app to pick up new config
        let url = URL(fileURLWithPath: Bundle.main.bundlePath)
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
        NSApp.terminate(nil)
    }
}
