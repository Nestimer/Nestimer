import Foundation
@testable import NesTimerCore

struct Offline: Error {}

final class FakeAPI: AgentAPI, @unchecked Sendable {
    var policy: ServerPolicy?
    var configFails = false
    var reportFailures: Set<Double> = []
    var reports: [(Double, Bool)] = []   // (minutes, succeeded)
    var verifyResult: Bool? = true       // nil → network error

    func fetchConfig(localDate: String) async throws -> ServerPolicy {
        if configFails { throw Offline() }
        guard let p = policy else { throw Offline() }
        return p
    }
    func reportUsage(date: String, totalMinutes: Double) async throws {
        let fail = reportFailures.contains(totalMinutes)
        reports.append((totalMinutes, !fail))
        if fail { throw Offline() }
    }
    func verifyTOTP(code: String) async throws -> Bool {
        guard let r = verifyResult else { throw Offline() }
        return r
    }
}

final class MemoryStore: StateStore, @unchecked Sendable {
    var state = AgentState()
    func load() -> AgentState { state }
    func save(_ s: AgentState) { state = s }
}

final class FakeShield: Shield, @unchecked Sendable {
    var applied: [ShieldReason] = []
    var removed = 0
    var current: ShieldReason?
    func apply(_ r: ShieldReason) { applied.append(r); current = r }
    func remove() { removed += 1; current = nil }
}

final class FakeScheduler: MonitorScheduler, @unchecked Sendable {
    var events: [PlannedEvent] = []
    var windows: [PlannedWindow] = []
    func arm(events: [PlannedEvent], windows: [PlannedWindow]) throws { self.events = events; self.windows = windows }
}

final class FakeNotifier: Notifier, @unchecked Sendable {
    var warnings: [Int] = []
    var expiredCount = 0
    func warn(minutesLeft: Int) { warnings.append(minutesLeft) }
    func expired() { expiredCount += 1 }
}

struct FakeSecrets: SecretStore { var secret: String?; func totpSecret() -> String? { secret } }

final class Clock: @unchecked Sendable { var now: Date; init(_ d: Date) { now = d } }

struct Rig {
    let api = FakeAPI(), store = MemoryStore(), shield = FakeShield(), scheduler = FakeScheduler(), notifier = FakeNotifier()
    let clock: Clock
    let engine: SyncEngine

    init(now: Date = Fx.at(15), secret: String? = "3132333435363738393031323334353637383930") {
        clock = Clock(now)
        let c = clock
        engine = SyncEngine(api: api, store: store, shield: shield, scheduler: scheduler, notifier: notifier,
                            secrets: FakeSecrets(secret: secret), calendar: Fx.cal, now: { c.now })
    }
}
