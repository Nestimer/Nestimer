import Foundation
@testable import NesTimerCore

struct Offline: Error {}

final class FakeAPI: AgentAPI, @unchecked Sendable {
    var policy: ServerPolicy?
    var configFails = false
    var reportFailures: Set<Double> = []
    var reports: [(Double, Bool)] = []   // (minutes, succeeded)
    var verifyResult: Bool? = true       // nil → network error
    var serverTime: Date?
    var fetchedDates: [String] = []

    func fetchConfig(localDate: String) async throws -> ConfigResponse {
        fetchedDates.append(localDate)
        if configFails { throw Offline() }
        guard let p = policy else { throw Offline() }
        return ConfigResponse(policy: p, serverTime: serverTime)
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
    /// True while an update() closure runs — i.e. while the real store would hold its flock.
    var locked = false
    func load() -> AgentState { state }
    func save(_ s: AgentState) { state = s }
    func update<T>(_ body: (inout AgentState) -> T) -> T {
        locked = true
        defer { locked = false }
        var s = state; let r = body(&s); state = s; return r
    }
}

/// Fails the test if iOS side effects happen while the state lock is held: on device the
/// monitor extension, woken by those very calls, blocks on the same lock (deadlock).
final class LockCheckingScheduler: MonitorScheduler, ShieldLike, @unchecked Sendable {
    let store: MemoryStore
    var violations = 0
    init(store: MemoryStore) { self.store = store }
    func armEvents(_ events: [PlannedEvent]) throws { if store.locked { violations += 1 } }
    func armWindows(_ windows: [PlannedWindow]) throws { if store.locked { violations += 1 } }
    func apply(_ reason: ShieldReason) { if store.locked { violations += 1 } }
    func remove() { if store.locked { violations += 1 } }
}
typealias ShieldLike = Shield

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
    var armCount = 0
    func armEvents(_ events: [PlannedEvent]) throws { self.events = events; armCount += 1 }
    func armWindows(_ windows: [PlannedWindow]) throws { self.windows = windows }
}

final class FakeNotifier: Notifier, @unchecked Sendable {
    var warnings: [Int] = []
    var expiredCount = 0
    func warn(minutesLeft: Int) { warnings.append(minutesLeft) }
    func expired() { expiredCount += 1 }
}

struct FakeSecrets: SecretStore { var secret: String?; func totpSecret() -> String? { secret } }

/// `now` is the phone's wall clock — assigning it directly models the child changing
/// Date & Time. `set(_:)` / `advance(_:)` model real time passing (uptime moves too).
final class Clock: @unchecked Sendable {
    var now: Date
    var uptime: TimeInterval = 1_000
    init(_ d: Date) { now = d }
    func set(_ d: Date) { uptime += d.timeIntervalSince(now); now = d }
    func advance(_ seconds: TimeInterval) { set(now.addingTimeInterval(seconds)) }
}

struct Rig {
    let api = FakeAPI(), store = MemoryStore(), shield = FakeShield(), scheduler = FakeScheduler(), notifier = FakeNotifier()
    let clock: Clock
    let engine: SyncEngine

    init(now: Date = Fx.at(15), secret: String? = "3132333435363738393031323334353637383930") {
        clock = Clock(now)
        let c = clock
        engine = SyncEngine(api: api, store: store, shield: shield, scheduler: scheduler, notifier: notifier,
                            secrets: FakeSecrets(secret: secret), calendar: Fx.cal, now: { c.now }, uptime: { c.uptime })
    }
}

extension Rig {
    /// Real use of the phone for `minutes`: iOS fires each armed usage event in order, as
    /// usage reaches it. Returns the last decision (nil if no event fired).
    @discardableResult
    func use(_ minutes: Double) async -> Decision? {
        let target = store.state.observedMinutes + minutes
        var last: Decision?
        for _ in 0..<1000 {
            guard let next = scheduler.events
                .filter({ Double($0.deviceMinutes) > store.state.observedMinutes && Double($0.deviceMinutes) <= target })
                .min(by: { $0.deviceMinutes < $1.deviceMinutes }) else { break }
            clock.advance((Double(next.deviceMinutes) - store.state.observedMinutes) * 60)
            last = await engine.onThreshold(eventName: next.name, observedMinutes: next.deviceMinutes)
        }
        return last
    }
}
