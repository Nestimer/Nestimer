import Foundation

/// What every wake does — in the app, the monitor extension, or after a code entry.
///
/// Anti-goal: a silent unlock. Every path that can't establish the policy keeps the shield:
/// no snapshot at all → shield; server unreachable → last snapshot + local count; the
/// phone's clock disagrees with trusted time → shield.
///
/// Wakes run in three steps so that concurrent wakes (actor reentrancy, or the app and
/// the monitor extension at once) never erase each other's state: (A) record local facts
/// in one atomic store update, (B) network with no state held, (C) reload, merge the
/// network results, decide and save in one atomic update.
public actor SyncEngine {
    public static let unlockMinutes = 5
    public static let codeAttemptLimit = 5
    public static let codeAttemptWindow: TimeInterval = 300
    /// Clock disagreement tolerated before the phone is shielded.
    public static let clockTolerance: TimeInterval = 10 * 60
    /// A snapshot older than this is "offline": only half the remaining budget may be spent.
    public static let staleAfter: TimeInterval = 30 * 60

    private let api: AgentAPI
    private let store: StateStore
    private let shield: Shield
    private let scheduler: MonitorScheduler
    private let notifier: Notifier
    private let secrets: SecretStore
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let uptime: @Sendable () -> TimeInterval
    /// Diagnostics: (step, seconds) for slow steps.
    private let trace: @Sendable (String, TimeInterval) -> Void

    public init(api: AgentAPI, store: StateStore, shield: Shield, scheduler: MonitorScheduler,
                notifier: Notifier, secrets: SecretStore, calendar: Calendar = .current,
                now: @escaping @Sendable () -> Date = Date.init,
                uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                trace: @escaping @Sendable (String, TimeInterval) -> Void = { _, _ in }) {
        self.trace = trace
        self.api = api; self.store = store; self.shield = shield; self.scheduler = scheduler
        self.notifier = notifier; self.secrets = secrets; self.calendar = calendar
        self.now = now; self.uptime = uptime
    }

    // MARK: Wake entry points

    /// A usage event fired. `observedMinutes` is the event's threshold (today's usage per iOS).
    public func onThreshold(eventName: String, observedMinutes: Int) async -> Decision {
        await wake(observed: Double(observedMinutes))
    }

    /// A downtime/activity/bonus window started or ended, or the daily interval rolled over.
    public func onIntervalBoundary() async -> Decision { await wake(observed: nil) }

    /// The app came to the foreground.
    public func onForeground() async -> Decision { await wake(observed: nil) }

    /// The parent's 6-digit code. True if it unlocked the phone.
    public func submitCode(_ code: String) async -> Bool {
        guard await verifyParentCode(code) else { return false }
        let device = now()
        store.update { s in
            s.unlockUntil = device.addingTimeInterval(TimeInterval(Self.unlockMinutes * 60))
            s.unlockEndsAtObserved = Int(s.observedMinutes.rounded(.up)) + Self.unlockMinutes
        }
        let decision = await wake(observed: nil)
        return !decision.isShielded
    }

    /// Checks a parent code — rate limited, one-time — without unlocking anything. Used
    /// for unlocks and for parent confirmations such as switching to the local time zone.
    public func verifyParentCode(_ code: String) async -> Bool {
        let device = now()
        // Record the attempt first, atomically, so no concurrent save can drop it.
        let allowed: Bool = store.update { s in
            s.codeAttempts = s.codeAttempts.filter { device.timeIntervalSince($0) < Self.codeAttemptWindow && $0 <= device }
            guard s.codeAttempts.count < Self.codeAttemptLimit else { return false }
            s.codeAttempts.append(device)
            return true
        }
        guard allowed else { return false }

        var step: Int64?
        do {
            guard try await api.verifyTOTP(code: code) else { return false }  // server enforces one-time use online
            step = trustedTime(store.load()).flatMap {
                TOTP.matchingStep(secretHex: secrets.totpSecret() ?? "", code: code, now: $0)
            }
        } catch {
            // Offline: check against the Keychain secret, at *trusted* time only, and only
            // codes newer than the last one used.
            let s = store.load()
            guard let t = trustedTime(s), !clockTampered(s, device: device),
                  let secret = secrets.totpSecret(),
                  let matched = TOTP.matchingStep(secretHex: secret, code: code, now: t),
                  matched > s.lastCodeStep else { return false }
            step = matched
        }
        store.update { s in
            if let step { s.lastCodeStep = max(s.lastCodeStep, step) }
            s.codeAttempts = []
        }
        return true
    }

    // MARK: The wake

    private func wake(observed: Double?) async -> Decision {
        let device = now()

        // (A) Local facts: rollover, usage growth, unlock expiry.
        let (pending, reportDate, flushYesterday) = store.update { s -> (Double?, String, (String, Double)?) in
            var flush: (String, Double)?
            let tampered = clockTampered(s, device: device)
            let today = localDate(device)

            // Day rollover only on a trustworthy clock; otherwise keep counting on the old day.
            // Never back to an earlier date (flying west, or switching time zones): that
            // would start a second budget for a day already spent.
            if (s.date.isEmpty || (today > s.date && !tampered && trustedOrUnanchored(s))) {
                if !s.date.isEmpty, s.countedMinutes > s.reportedMinutes { flush = (s.date, s.countedMinutes) }
                var fresh = AgentState()
                fresh.date = today
                for kp in Self.carriedAcrossDays { kp(&fresh, s) }
                s = fresh
            }

            accumulateWallTime(&s, device: device, tampered: tampered)
            if var o = observed {
                // A late event from yesterday can't be more than the minutes since midnight.
                o = min(o, minutesSinceMidnight(device))
                if o > s.observedMinutes { addObservation(&s, o) }
            }
            if let end = s.unlockEndsAtObserved, s.observedMinutes >= Double(end) { Self.clearUnlock(&s) }
            if let until = s.unlockUntil, device >= until || tampered { Self.clearUnlock(&s) }

            let pending = s.countedMinutes > s.reportedMinutes ? s.countedMinutes : nil
            return (pending, s.date, flush)
        }

        // (B) Network, holding no state.
        if let (date, total) = flushYesterday { try? await api.reportUsage(date: date, totalMinutes: total) }
        var reported: Double?
        if let total = pending, (try? await api.reportUsage(date: reportDate, totalMinutes: total)) != nil {
            reported = total
        }
        let fetched = try? await api.fetchConfig(localDate: reportDate)
        let fetchedAtUptime = uptime()

        // (C) Merge and decide atomically; then act on iOS *outside* the lock — arming
        // monitoring makes iOS wake the monitor extension, which needs the same lock.
        let plan = store.update { s -> EnforcementPlan in
            if let reported, s.date == reportDate { s.reportedMinutes = max(s.reportedMinutes, reported) }
            if let fetched {
                if let serverTime = fetched.serverTime {
                    s.anchorTime = serverTime
                    s.anchorUptime = fetchedAtUptime
                } else if s.anchorTime == nil || s.anchorUptime == nil || uptime() < (s.anchorUptime ?? 0) {
                    // No server clock available: anchor on the device clock, once per boot.
                    s.anchorTime = device
                    s.anchorUptime = fetchedAtUptime
                }
                if s.date == reportDate {
                    s.snapshot = fetched.policy
                    s.snapshotDate = reportDate
                    s.snapshotAt = trustedTime(s) ?? device
                    if fetched.policy.reportsDeviceUsage {
                        s.serverFloorMinutes = max(s.serverFloorMinutes, fetched.policy.deviceUsedMinutes)
                    }
                }
            } else if s.anchorTime == nil {
                s.anchorTime = device
                s.anchorUptime = uptime()
            }
            if let t = trustedTime(s) { s.latestTrusted = max(s.latestTrusted ?? t, t) }

            let decision = decide(&s, device: device)
            return record(&s, decision)
        }
        return carryOut(plan)
    }

    // MARK: Decide / enforce

    private func decide(_ s: inout AgentState, device: Date) -> Decision {
        if clockTampered(s, device: device) { return .shield(.clockChanged) }
        guard var policy = effectivePolicy(s) else { return .shield(.timeExpired) }  // never seen a policy
        if isStale(s, device: device) { policy = Self.halveRemaining(policy, deviceUsed: s.countedMinutes) }
        return PolicyEvaluator.evaluate(policy: policy, deviceUsedMinutes: s.countedMinutes,
                                        unlockUntil: s.unlockUntil, now: device, calendar: calendar)
    }

    /// Everything to do on iOS after a decision, computed under the lock.
    struct EnforcementPlan {
        var decision: Decision
        var events: [PlannedEvent]
        var windows: [PlannedWindow]
        var warnings: [Int]
        var expired: Bool
    }

    /// Updates state for the decision (warned, shielded, paused) and plans the side effects.
    private func record(_ s: inout AgentState, _ decision: Decision) -> EnforcementPlan {
        let policy = effectivePolicy(s)
        var windows = policy.map { SchedulePlanner.plan(policy: $0, now: now(), calendar: calendar) } ?? []
        if let bonusEnd = policy?.bonusUntilDate, bonusEnd > now() {
            windows.append(PlannedWindow(name: "bonusend-\(Int(bonusEnd.timeIntervalSince1970))",
                                         start: bonusEnd.addingTimeInterval(-SchedulePlanner.minimumLength),
                                         end: bonusEnd, kind: .bonusEnd))
        }
        var plan = EnforcementPlan(decision: decision, events: plannedEvents(decision, s), windows: windows,
                                   warnings: [], expired: false)
        switch decision {
        case .shield(let reason):
            plan.expired = !s.shielded && (reason == .timeExpired || reason == .deviceCapReached)
            s.shielded = true
            s.paused = false
        case .open(let remaining, let why):
            s.shielded = false
            if why == .withinLimit, let r = remaining {
                for n in ThresholdPlanner.warningMinutes where r <= Double(n) && !s.warned.contains(n) {
                    s.warned.insert(n)
                    plan.warnings.append(n)
                }
            }
            if let r = remaining, r > 15 { s.warned = [] }
            switch why {
            case .activity, .temporaryUnlock: s.paused = true
            default: s.paused = false
            }
        }
        return plan
    }

    /// iOS side effects, with no lock held. If no lock event can be armed, the phone must
    /// not stay open.
    private func timed<T>(_ step: String, _ work: () throws -> T) rethrows -> T {
        let t0 = Date()
        defer { trace(step, Date().timeIntervalSince(t0)) }
        return try work()
    }

    private func carryOut(_ plan: EnforcementPlan) -> Decision {
        var decision = plan.decision
        do {
            try timed("armEvents") { try scheduler.armEvents(plan.events) }
        } catch {
            if !decision.isShielded {
                decision = .shield(.agentError)
                store.update { s in s.shielded = true; s.paused = false }
            }
        }
        timed("armWindows") { try? scheduler.armWindows(plan.windows) }
        timed("shield") {
            switch decision {
            case .shield(let reason): shield.apply(reason)
            case .open: shield.remove()
            }
        }
        for n in plan.warnings { notifier.warn(minutesLeft: n) }
        if plan.expired { notifier.expired() }
        return decision
    }

    // MARK: Time

    /// Trusted "now": the anchor plus monotonic uptime since. Nil after a reboot until the
    /// next server contact (uptime restarts at boot).
    private nonisolated func trustedTime(_ s: AgentState) -> Date? {
        guard let t = s.anchorTime, let u = s.anchorUptime else { return nil }
        let up = uptime()
        guard up >= u else { return nil }
        return t.addingTimeInterval(up - u)
    }

    private nonisolated func trustedOrUnanchored(_ s: AgentState) -> Bool {
        s.anchorTime == nil || trustedTime(s) != nil
    }

    /// The device clock is off from trusted time, or (after a reboot) earlier than any
    /// trusted time ever seen.
    private nonisolated func clockTampered(_ s: AgentState, device: Date) -> Bool {
        if let t = trustedTime(s) { return abs(device.timeIntervalSince(t)) > Self.clockTolerance }
        if let latest = s.latestTrusted { return device < latest.addingTimeInterval(-Self.clockTolerance) }
        return false
    }

    private func isStale(_ s: AgentState, device: Date) -> Bool {
        guard let at = s.snapshotAt else { return true }
        return (trustedTime(s) ?? device).timeIntervalSince(at) > Self.staleAfter
    }

    /// Offline, the Macs may be spending the same budget: allow only half of what was left.
    static func halveRemaining(_ p: ServerPolicy, deviceUsed: Double) -> ServerPolicy {
        guard p.screenTimeEnabled else { return p }
        let leftAtSnapshot = Double(p.screenTimeLimitMinutes) - (p.otherDevicesUsed + p.deviceUsedMinutes)
        guard leftAtSnapshot > 0 else { return p }
        let reduced = Int((p.otherDevicesUsed + p.deviceUsedMinutes + leftAtSnapshot / 2).rounded(.down))
        return ServerPolicy(downtimeEnabled: p.downtimeEnabled, downtimeStart: p.downtimeStart,
                            downtimeEnd: p.downtimeEnd, screenTimeEnabled: true, screenTimeLimitMinutes: reduced,
                            usedMinutesToday: p.usedMinutesToday, activities: p.activities, bonusUntil: p.bonusUntil,
                            deviceUsedMinutes: p.reportsDeviceUsage ? p.deviceUsedMinutes : nil,
                            deviceCapMinutes: p.deviceCapMinutes)
    }

    // MARK: Usage accounting

    /// Wall time since the last wake, split into paused and counted, so a usage delta that
    /// spans a pause boundary is attributed proportionally instead of all-or-nothing.
    private nonisolated func accumulateWallTime(_ s: inout AgentState, device: Date, tampered: Bool) {
        defer { s.lastWakeAt = device }
        guard !tampered, let last = s.lastWakeAt, device > last else { return }
        let dt = device.timeIntervalSince(last)
        s.secondsSinceObservation += dt
        if s.paused { s.pausedSecondsSinceObservation += dt }
    }

    private nonisolated func addObservation(_ s: inout AgentState, _ o: Double) {
        let delta = o - s.observedMinutes
        let total = s.secondsSinceObservation
        let pausedShare = total > 0 ? min(1, s.pausedSecondsSinceObservation / total) : (s.paused ? 1 : 0)
        s.pausedMinutes += delta * pausedShare
        s.observedMinutes = o
        s.secondsSinceObservation = 0
        s.pausedSecondsSinceObservation = 0
    }

    private nonisolated func minutesSinceMidnight(_ d: Date) -> Double {
        d.timeIntervalSince(calendar.startOfDay(for: d)) / 60
    }

    // MARK: Helpers

    /// Fields that survive a day rollover.
    private static let carriedAcrossDays: [(inout AgentState, AgentState) -> Void] = [
        { $0.snapshot = $1.snapshot }, { $0.snapshotDate = $1.snapshotDate }, { $0.snapshotAt = $1.snapshotAt },
        { $0.unlockUntil = $1.unlockUntil }, { $0.codeAttempts = $1.codeAttempts }, { $0.shielded = $1.shielded },
        { $0.lastCodeStep = $1.lastCodeStep }, { $0.anchorTime = $1.anchorTime }, { $0.anchorUptime = $1.anchorUptime },
        { $0.latestTrusted = $1.latestTrusted }, { $0.lastWakeAt = $1.lastWakeAt }, { $0.paused = $1.paused },
    ]

    private static func clearUnlock(_ s: inout AgentState) {
        s.unlockUntil = nil
        s.unlockEndsAtObserved = nil
    }

    /// The snapshot, with its usage numbers zeroed if they belong to another day.
    private nonisolated func effectivePolicy(_ s: AgentState) -> ServerPolicy? {
        guard let p = s.snapshot else { return nil }
        guard s.snapshotDate != s.date else { return p }
        return ServerPolicy(downtimeEnabled: p.downtimeEnabled, downtimeStart: p.downtimeStart,
                            downtimeEnd: p.downtimeEnd, screenTimeEnabled: p.screenTimeEnabled,
                            screenTimeLimitMinutes: p.screenTimeLimitMinutes, usedMinutesToday: 0,
                            activities: p.activities, bonusUntil: p.bonusUntil,
                            deviceUsedMinutes: p.reportsDeviceUsage ? 0 : nil, deviceCapMinutes: p.deviceCapMinutes)
    }

    private nonisolated func plannedEvents(_ d: Decision, _ s: AgentState) -> [PlannedEvent] {
        switch d {
        case .shield:
            return []
        case .open(let remaining, let why):
            switch why {
            case .withinLimit:
                return ThresholdPlanner.plan(deviceUsedMinutes: s.observedMinutes, remainingMinutes: remaining,
                                             unlockEndsAfterMinutes: nil)
            case .temporaryUnlock:
                let after = (s.unlockEndsAtObserved ?? 0) - Int(s.observedMinutes.rounded(.up))
                return ThresholdPlanner.plan(deviceUsedMinutes: s.observedMinutes, remainingMinutes: nil,
                                             unlockEndsAfterMinutes: max(1, after))
            case .noLimit, .activity, .bonus:
                return ThresholdPlanner.plan(deviceUsedMinutes: s.observedMinutes, remainingMinutes: nil,
                                             unlockEndsAfterMinutes: nil)
            }
        }
    }

    private nonisolated func localDate(_ d: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}
