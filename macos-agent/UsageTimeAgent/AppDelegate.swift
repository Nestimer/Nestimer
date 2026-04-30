import AppKit
import UserNotifications
import ServiceManagement

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
    /// True after the first successful server sync. Lock screen won't show before this.
    private var initialSyncCompleted = false
    /// Last fetched policy — used to calculate adaptive sync interval.
    private var lastPolicy: ServerPolicy?
    /// Timestamp of last successful sync.
    private var lastSyncTime: Date = .distantPast
    /// Cached TOTP shared secret — stored in Keychain, not UserDefaults (child can't read).
    private var sharedSecret: String? {
        get { KeychainStore.get(key: "totp_shared_secret") }
        set {
            if let v = newValue { KeychainStore.set(key: "totp_shared_secret", value: v) }
            else { KeychainStore.delete(key: "totp_shared_secret") }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[UsageTimeAgent] Application starting...")

        // Load config
        agentConfig = AgentConfig.load()

        // If another instance is already running from /Applications, kill it first
        // (happens during manual update when old agent is still alive)
        if !SystemInstaller.isRunningFromSystemLocation && SystemInstaller.isInstalled {
            killOtherInstances()
        }

        // Install or update as a protected system service (Release builds only).
        // Triggers when: not installed yet, OR running from outside /Applications (= update).
        if !agentConfig.devMode && (!SystemInstaller.isInstalled || !SystemInstaller.isRunningFromSystemLocation) {
            SystemInstaller.promptAndInstallIfNeeded()
        } else if !SystemInstaller.isInstalled && agentConfig.devMode {
            registerAsLoginItem()
        }

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

        // Adaptive sync timer — checks every 5s, syncs based on current state:
        //   Locked:              every 5s  (parent might change policy)
        //   < 5 min remaining:   every 10s (approaching limit)
        //   < 30 min remaining:  every 20s
        //   > 30 min remaining:  every 60s (idle, save bandwidth)
        //   Dev mode:            every 10s
        syncTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let elapsed = Date().timeIntervalSince(self.lastSyncTime)
            let interval = self.adaptiveSyncInterval()
            if elapsed >= interval {
                Task { await self.performSync() }
            }
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
        // Don't count or evaluate until first server sync completes
        guard initialSyncCompleted else { return }
        // Pause counting during scheduled activity, TOTP temp unlock, or parent-granted bonus
        if policyEnforcer.activeActivity != nil || policyEnforcer.isTemporaryUnlockActive || policyEnforcer.isBonusActive {
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
            let policy = try await apiClient.fetchConfig(localDate: usageTracker.currentDateString())

            // On first sync, trust server value completely (local cache may be stale)
            if !initialSyncCompleted {
                usageTracker.forceSetUsedMinutes(policy.usedMinutesToday, forDate: usageTracker.currentDateString())
                initialSyncCompleted = true
                NSLog("[UsageTimeAgent] Initial sync — server says \(String(format: "%.1f", policy.usedMinutesToday))m used")
                // Fetch TOTP secret if not in Keychain yet
                if sharedSecret == nil {
                    if let secret = try? await apiClient.fetchTOTPSecret() {
                        sharedSecret = secret
                        NSLog("[UsageTimeAgent] TOTP secret stored in Keychain")
                    }
                }
            } else {
                // Normal sync — reconcile local and server
                usageTracker.setUsedMinutes(policy.usedMinutesToday, forDate: usageTracker.currentDateString())
            }

            // Report our usage back (use fresh value after sync)
            let syncedMinutes = usageTracker.getUsedMinutesToday()
            try await apiClient.reportUsage(
                date: usageTracker.currentDateString(),
                totalMinutes: syncedMinutes
            )

            // Enforce policy (lock/unlock, warnings)
            let currentUsed = usageTracker.getUsedMinutesToday()
            await MainActor.run {
                policyEnforcer.evaluate(policy: policy, usedMinutesToday: currentUsed)
                statusBar?.updatePolicy(policy: policy)
                statusBar?.activeActivityName = policyEnforcer.activeActivity?.name
                statusBar?.activeActivityEndsAt = policyEnforcer.activeActivityEndsAt
            }

            lastPolicy = policy
            lastSyncTime = Date()

            let remaining = Double(policy.screenTimeLimitMinutes) - currentUsed
            let nextIn = Int(adaptiveSyncInterval())
            NSLog("[UsageTimeAgent] Sync OK — used: \(String(format: "%.1f", currentUsed))m, limit: \(policy.screenTimeLimitMinutes)m, remaining: \(String(format: "%.0f", remaining))m, next sync: \(nextIn)s")
        } catch {
            NSLog("[UsageTimeAgent] Sync failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Adaptive sync

    private func adaptiveSyncInterval() -> TimeInterval {
        if agentConfig.devMode { return 10 }
        if policyEnforcer.isLocked { return 5 }
        if policyEnforcer.activeActivity != nil { return 60 }
        if policyEnforcer.isTemporaryUnlockActive { return 60 }
        if policyEnforcer.isBonusActive { return 30 }

        // Calculate remaining minutes from last policy
        if let policy = lastPolicy, policy.screenTimeEnabled {
            let remaining = Double(policy.screenTimeLimitMinutes) - usageTracker.getUsedMinutesToday()
            if remaining < 5 { return 10 }
            if remaining < 30 { return 20 }
        }

        return 60  // Everything is fine — sync once per minute
    }

    // MARK: - Duplicate instance handling

    private func killOtherInstances() {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "UsageTimeAgent"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in output.split(separator: "\n") {
            if let pid = Int32(line.trimmingCharacters(in: .whitespaces)), pid != myPID {
                NSLog("[UsageTimeAgent] Killing other instance PID \(pid)")
                kill(pid, SIGTERM)
            }
        }
        usleep(500_000) // 0.5s for graceful exit
    }

    // MARK: - Autostart

    private func registerAsLoginItem() {
        let service = SMAppService.mainApp
        switch service.status {
        case .enabled:
            NSLog("[UsageTimeAgent] Login item: already enabled")
        case .notRegistered, .notFound:
            do {
                try service.register()
                NSLog("[UsageTimeAgent] Login item: registered ✓")
            } catch {
                NSLog("[UsageTimeAgent] Login item: failed to register — \(error.localizedDescription)")
            }
        case .requiresApproval:
            NSLog("[UsageTimeAgent] Login item: requires user approval in System Settings")
        @unknown default:
            break
        }
    }

    // MARK: - TOTP code handling

    private func handleCodeSubmission(_ code: String) {
        guard let secret = sharedSecret else {
            NSLog("[UsageTimeAgent] TOTP: No shared secret available")
            return
        }
        if TOTPGenerator.verifyCode(secretHex: secret, code: code) {
            NSLog("[UsageTimeAgent] TOTP: Code accepted — granting 5 minutes")
            policyEnforcer.grantTemporaryAccess(minutes: 5)
        } else {
            NSLog("[UsageTimeAgent] TOTP: Code rejected")
        }
    }

    // MARK: - Setup alert

    private func showSetupRequiredAlert() {
        let alert = NSAlert()
        alert.messageText = "NesTimer Setup"
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
