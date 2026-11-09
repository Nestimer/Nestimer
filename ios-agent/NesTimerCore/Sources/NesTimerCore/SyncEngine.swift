import Foundation

/// What every wake does — in the app, the monitor extension, or after a code entry.
///
/// Anti-goal: a silent unlock. Every path that can't establish the policy keeps the shield:
/// no snapshot at all → shield; server unreachable → last snapshot + local count.
public actor SyncEngine {
    public static let unlockMinutes = 5
    public static let codeAttemptLimit = 5
    public static let codeAttemptWindow: TimeInterval = 300

    private let api: AgentAPI
    private let store: StateStore
    private let shield: Shield
    private let scheduler: MonitorScheduler
    private let notifier: Notifier
    private let secrets: SecretStore
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    public init(api: AgentAPI, store: StateStore, shield: Shield, scheduler: MonitorScheduler,
                notifier: Notifier, secrets: SecretStore, calendar: Calendar = .current,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.api = api; self.store = store; self.shield = shield; self.scheduler = scheduler
        self.notifier = notifier; self.secrets = secrets; self.calendar = calendar; self.now = now
    }

    // MARK: Wake entry points

    /// A usage event fired. `observedMinutes` is the event's threshold (today's usage per iOS).
    public func onThreshold(eventName: String, observedMinutes: Int) async -> Decision {
        await wake(observed: Double(observedMinutes))
    }

    /// A downtime/activity window started or ended, or the daily interval rolled over.
    public func onIntervalBoundary() async -> Decision { await wake(observed: nil) }

    /// The app came to the foreground.
    public func onForeground() async -> Decision { await wake(observed: nil) }

    /// The parent's 6-digit code. True if it unlocked the phone.
    public func submitCode(_ code: String) async -> Bool {
        var state = store.load()
        let t = now()
        state.codeAttempts = state.codeAttempts.filter { t.timeIntervalSince($0) < Self.codeAttemptWindow }
        guard state.codeAttempts.count < Self.codeAttemptLimit else { store.save(state); return false }
        state.codeAttempts.append(t)
        store.save(state)

        let valid: Bool
        do {
            valid = try await api.verifyTOTP(code: code)
        } catch {
            // Server unreachable: verify against the Keychain-cached secret.
            valid = secrets.totpSecret().map { TOTP.verify(secretHex: $0, code: code, now: t) } ?? false
        }
        guard valid else { return false }

        state = store.load()
        state.codeAttempts = []
        state.unlockUntil = t.addingTimeInterval(TimeInterval(Self.unlockMinutes * 60))
        state.unlockEndsAtObserved = Int(state.observedMinutes.rounded(.up)) + Self.unlockMinutes
        store.save(state)
        let decision = await wake(observed: nil)
        return !decision.isShielded
    }

    // MARK: The wake

    private func wake(observed: Double?) async -> Decision {
        let t = now()
        let today = localDate(t)
        var state = store.load()

        // 1. Day rollover: flush yesterday's last total, then start today from zero.
        if state.date != today {
            if !state.date.isEmpty, state.countedMinutes > state.reportedMinutes {
                try? await api.reportUsage(date: state.date, totalMinutes: state.countedMinutes)
            }
            let keep = state
            state = AgentState()
            state.date = today
            state.snapshot = keep.snapshot
            state.snapshotDate = keep.snapshotDate
            state.snapshotAt = keep.snapshotAt
            state.unlockUntil = keep.unlockUntil
            state.codeAttempts = keep.codeAttempts
            state.shielded = keep.shielded
        }

        // 2. Usage growth since the last wake; growth while paused doesn't count.
        if let o = observed, o > state.observedMinutes {
            if state.paused { state.pausedMinutes += o - state.observedMinutes }
            state.observedMinutes = o
        }

        // 3. TOTP unlock ends after 5 minutes of use or 5 minutes of wall clock.
        if let end = state.unlockEndsAtObserved, state.observedMinutes >= Double(end) { clearUnlock(&state) }
        if let until = state.unlockUntil, t >= until { clearUnlock(&state) }

        // 4. Report, then fetch. Either may fail; neither failure unlocks anything.
        if state.countedMinutes > state.reportedMinutes {
            let total = state.countedMinutes
            if (try? await api.reportUsage(date: today, totalMinutes: total)) != nil {
                state.reportedMinutes = total
            }
        }
        if let fresh = try? await api.fetchConfig(localDate: today) {
            state.snapshot = fresh
            state.snapshotDate = today
            state.snapshotAt = t
            if fresh.reportsDeviceUsage { state.serverFloorMinutes = max(state.serverFloorMinutes, fresh.deviceUsedMinutes) }
        }

        // 5. Decide.
        let policy = effectivePolicy(state, today: today)
        let decision: Decision
        if let policy {
            decision = PolicyEvaluator.evaluate(policy: policy, deviceUsedMinutes: state.countedMinutes,
                                                unlockUntil: state.unlockUntil, now: t, calendar: calendar)
        } else {
            decision = .shield(.timeExpired)  // never seen a policy: fail closed
        }

        // 6. Enforce + notify.
        switch decision {
        case .shield(let reason):
            shield.apply(reason)
            if !state.shielded, reason == .timeExpired || reason == .deviceCapReached { notifier.expired() }
            state.shielded = true
        case .open(let remaining, let why):
            shield.remove()
            state.shielded = false
            if why == .withinLimit, let r = remaining {
                for n in ThresholdPlanner.warningMinutes where r <= Double(n) && !state.warned.contains(n) {
                    state.warned.insert(n)
                    notifier.warn(minutesLeft: n)
                }
            }
            if let r = remaining, r > 15 { state.warned = [] }
        }

        // 7. Pause bookkeeping for the next wake, then re-arm.
        if case .open(_, let why) = decision {
            switch why {
            case .activity, .temporaryUnlock: state.paused = true
            default: state.paused = false
            }
        } else {
            state.paused = false
        }
        let events = plannedEvents(decision, state)
        let windows = policy.map { SchedulePlanner.plan(policy: $0, now: t, calendar: calendar) } ?? []
        try? scheduler.arm(events: events, windows: windows)

        store.save(state)
        return decision
    }

    // MARK: Helpers

    private func clearUnlock(_ s: inout AgentState) {
        s.unlockUntil = nil
        s.unlockEndsAtObserved = nil
    }

    /// The snapshot, with its usage numbers zeroed if they belong to another day.
    private func effectivePolicy(_ s: AgentState, today: String) -> ServerPolicy? {
        guard let p = s.snapshot else { return nil }
        guard s.snapshotDate != today else { return p }
        return ServerPolicy(downtimeEnabled: p.downtimeEnabled, downtimeStart: p.downtimeStart,
                            downtimeEnd: p.downtimeEnd, screenTimeEnabled: p.screenTimeEnabled,
                            screenTimeLimitMinutes: p.screenTimeLimitMinutes, usedMinutesToday: 0,
                            activities: p.activities, bonusUntil: p.bonusUntil,
                            deviceUsedMinutes: p.reportsDeviceUsage ? 0 : nil, deviceCapMinutes: p.deviceCapMinutes)
    }

    private func plannedEvents(_ d: Decision, _ s: AgentState) -> [PlannedEvent] {
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

    private func localDate(_ d: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}
