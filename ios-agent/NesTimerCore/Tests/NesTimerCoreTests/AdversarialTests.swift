import XCTest
@testable import NesTimerCore

/// Bypass attempts from the risk review (the child controls Date & Time, airplane mode and
/// timing). `clock.now = …` is the child changing the clock; `clock.set(…)` is real time.
final class AdversarialTests: XCTestCase {
    let secret = "3132333435363738393031323334353637383930"
    func code(at d: Date) -> String { TOTP.code(secretHex: secret, counter: UInt64(d.timeIntervalSince1970 / 300))! }

    // MARK: Clock

    func testClockForwardADayRestoresNothing() async {
        let r = Rig()
        r.api.policy = Fx.policy(limit: 60)
        _ = await r.engine.onThreshold(eventName: "lock-60", observedMinutes: 60)
        XCTAssertEqual(r.shield.current, .timeExpired)
        r.clock.now = Fx.at(15, 5, day: 1)
        let d = await r.engine.onForeground()
        XCTAssertEqual(d, .shield(.clockChanged))
        XCTAssertEqual(r.store.state.date, "2026-11-09", "no rollover on an untrusted clock")
    }

    func testClockBackLeavesNoDowntime() async {
        let r = Rig(now: Fx.at(22, 30))
        r.api.policy = Fx.policy(downtime: ("22:00", "07:00"))
        _ = await r.engine.onIntervalBoundary()
        r.clock.now = Fx.at(21)
        let d = await r.engine.onForeground()
        XCTAssertTrue(d.isShielded)
    }

    func testClockIntoActivityWindowGivesNothing() async {
        let a = ScheduledActivity(id: "a", name: "Chess", dayOfWeek: 0, startTime: "08:00", endTime: "09:00")
        let r = Rig()
        r.api.policy = Fx.policy(limit: 60, activities: [a])
        _ = await r.engine.onThreshold(eventName: "lock-60", observedMinutes: 60)
        r.clock.now = Fx.at(8, 30)
        _ = await r.engine.onForeground()
        _ = await r.engine.onThreshold(eventName: "chunk-120", observedMinutes: 120)
        XCTAssertEqual(r.store.state.countedMinutes, 120)
        XCTAssertNotNil(r.shield.current)
    }

    func testServerClockOverridesDeviceClock() async {
        // Device clock and uptime agree with each other, but the server says it's an hour earlier.
        let r = Rig(now: Fx.at(23))
        r.api.policy = Fx.policy(downtime: ("22:00", "07:00"))
        r.api.serverTime = Fx.at(22)
        _ = await r.engine.onForeground()
        r.clock.advance(60)
        r.api.serverTime = Fx.at(22, 1)
        let v1 = await r.engine.onForeground()
        XCTAssertEqual(v1, .shield(.clockChanged))
    }

    func testSmallClockDriftTolerated() async {
        let r = Rig()
        r.api.policy = Fx.policy(limit: 60)
        r.api.serverTime = Fx.at(15).addingTimeInterval(-120)  // phone 2 minutes fast
        _ = await r.engine.onForeground()
        let v2 = await r.engine.onForeground()
        XCTAssertEqual(v2, .open(remainingMinutes: 60, why: .withinLimit))
    }

    func testAfterRebootClockCantGoBackPastLatestTrusted() async {
        let r = Rig(now: Fx.at(22, 30))
        r.api.policy = Fx.policy(downtime: ("22:00", "07:00"))
        _ = await r.engine.onForeground()
        r.api.configFails = true
        r.clock.uptime = 5          // rebooted
        r.clock.now = Fx.at(21)      // and moved the clock back
        let v3 = await r.engine.onForeground()
        XCTAssertEqual(v3, .shield(.clockChanged))
    }

    func testAfterRebootOfflineNoRolloverWithoutTrustedTime() async {
        let r = Rig(now: Fx.at(15))
        r.api.policy = Fx.policy(limit: 60)
        _ = await r.engine.onThreshold(eventName: "lock-60", observedMinutes: 60)
        r.api.configFails = true
        r.clock.uptime = 5
        r.clock.now = Fx.at(15, day: 1)  // a day forward after a reboot, offline: unverifiable
        let d = await r.engine.onForeground()
        XCTAssertTrue(d.isShielded)
        XCTAssertEqual(r.store.state.date, "2026-11-09")
    }

    // MARK: Codes

    func testSameCodeCannotBeReusedOffline() async {
        let r = Rig(now: Fx.at(15, 1))
        r.api.policy = Fx.policy(limit: 60)
        _ = await r.engine.onThreshold(eventName: "lock-60", observedMinutes: 60)
        r.api.verifyResult = nil
        r.api.configFails = true
        let c = code(at: r.clock.now)
        let v4 = await r.engine.submitCode(c)
        XCTAssertTrue(v4)
        _ = await r.engine.onThreshold(eventName: "unlockend-65", observedMinutes: 65)
        XCTAssertNotNil(r.shield.current)
        r.clock.advance(60)
        let v5 = await r.engine.submitCode(c)
        XCTAssertFalse(v5, "a spent code unlocked again")
    }

    func testOldCodeDoesNotWorkAfterRewindingClockOffline() async {
        let r = Rig()
        r.api.policy = Fx.policy(limit: 60)
        let leaked = code(at: Fx.at(10))
        _ = await r.engine.onThreshold(eventName: "lock-60", observedMinutes: 60)
        r.api.verifyResult = nil
        r.api.configFails = true
        r.clock.now = Fx.at(10)
        let v6 = await r.engine.submitCode(leaked)
        XCTAssertFalse(v6)
    }

    // MARK: Concurrency

    func testCodeAttemptsSurviveConcurrentWake() async {
        let api = GatedAPI(policy: Fx.policy(limit: 60))
        let store = MemoryStore(), clock = Clock(Fx.at(15))
        let c = clock
        let e = SyncEngine(api: api, store: store, shield: FakeShield(), scheduler: FakeScheduler(), notifier: FakeNotifier(),
                           secrets: FakeSecrets(secret: secret), calendar: Fx.cal, now: { c.now }, uptime: { c.uptime })
        let wake = Task { await e.onForeground() }
        while api.gate == nil { await Task.yield() }
        for _ in 0..<5 { _ = await e.submitCode("000001") }
        XCTAssertEqual(store.state.codeAttempts.count, 5)
        api.release()
        _ = await wake.value
        XCTAssertEqual(store.state.codeAttempts.count, 5, "stale save wiped the attempt log")
    }

    // MARK: Pause attribution

    func testUsageBeforeActivityStartIsCounted() async {
        let a = ScheduledActivity(id: "a", name: "Chess", dayOfWeek: 0, startTime: "16:00", endTime: "17:00",
                                  bufferBeforeMinutes: 0, bufferAfterMinutes: 0)
        let r = Rig(now: Fx.at(15, 50))
        r.api.policy = Fx.policy(limit: 60, activities: [a])
        _ = await r.engine.onThreshold(eventName: "chunk-20", observedMinutes: 20)
        r.clock.set(Fx.at(16))
        _ = await r.engine.onIntervalBoundary()
        _ = await r.engine.onThreshold(eventName: "chunk-25", observedMinutes: 25)
        XCTAssertGreaterThanOrEqual(r.store.state.countedMinutes, 24)
    }

    func testUsageBeforeCodeEntryIsCounted() async {
        let r = Rig()
        r.api.policy = Fx.policy(limit: 60)
        _ = await r.engine.onThreshold(eventName: "chunk-20", observedMinutes: 20)
        r.clock.advance(290)
        _ = await r.engine.submitCode("123456")
        _ = await r.engine.onThreshold(eventName: "unlockend-25", observedMinutes: 25)
        XCTAssertGreaterThanOrEqual(r.store.state.countedMinutes, 24)
    }

    // MARK: Arming

    func testArmFailureDoesNotLeavePhoneOpenUnarmed() async {
        let store = MemoryStore(), api = FakeAPI(), shield = FakeShield(), clock = Clock(Fx.at(15))
        api.policy = Fx.policy(limit: 60)
        let c = clock
        let e = SyncEngine(api: api, store: store, shield: shield, scheduler: ThrowingScheduler(), notifier: FakeNotifier(),
                           secrets: FakeSecrets(secret: secret), calendar: Fx.cal, now: { c.now }, uptime: { c.uptime })
        let d = await e.onThreshold(eventName: "chunk-50", observedMinutes: 50)
        XCTAssertEqual(d, .open(remainingMinutes: 10, why: .withinLimit))
        XCTAssertEqual(shield.current, .agentError, "open with no lock event armed")
    }

    func testBonusEndIsAWake() async {
        let r = Rig()
        r.api.policy = Fx.policy(limit: 60, bonusUntil: Fx.at(15, 30))
        _ = await r.engine.onThreshold(eventName: "chunk-60", observedMinutes: 60)
        XCTAssertNil(r.shield.current)
        XCTAssertTrue(r.scheduler.windows.contains { $0.kind == .bonusEnd && $0.end == Fx.at(15, 30) })
    }

    // MARK: Midnight

    func testLateEventAfterMidnightIsNotBookedOnToday() async {
        let r = Rig(now: Fx.at(23, 50))
        r.api.policy = Fx.policy(limit: 120)
        _ = await r.engine.onThreshold(eventName: "chunk-110", observedMinutes: 110)
        r.clock.set(Fx.at(0, 1, day: 1))
        _ = await r.engine.onThreshold(eventName: "chunk-115", observedMinutes: 115)
        XCTAssertLessThanOrEqual(r.store.state.observedMinutes, 1.01)
    }

    // MARK: Offline double spend

    func testOfflineOnlyHalfTheRemainingBudget() async {
        let r = Rig()
        r.api.policy = Fx.policy(limit: 60, used: 20, deviceUsed: 0)   // 40 left
        _ = await r.engine.onForeground()
        r.api.configFails = true
        r.clock.advance(31 * 60)
        let d = await r.engine.onThreshold(eventName: "chunk-20", observedMinutes: 20)
        XCTAssertEqual(d, .shield(.timeExpired), "offline, 20 of the 40 left is the most the phone may spend")
    }
}

/// fetchConfig suspends until released — a slow or black-holed network.
final class GatedAPI: AgentAPI, @unchecked Sendable {
    let policy: ServerPolicy
    var gate: CheckedContinuation<Void, Never>?
    var gated = true
    init(policy: ServerPolicy) { self.policy = policy }
    func fetchConfig(localDate: String) async throws -> ConfigResponse {
        if gated { await withCheckedContinuation { gate = $0 } }
        return ConfigResponse(policy: policy, serverTime: nil)
    }
    func reportUsage(date: String, totalMinutes: Double) async throws {}
    func verifyTOTP(code: String) async throws -> Bool { throw Offline() }
    func release() { gated = false; gate?.resume(); gate = nil }
}

struct ThrowingScheduler: MonitorScheduler {
    struct Boom: Error {}
    func armEvents(_ events: [PlannedEvent]) throws { throw Boom() }
    func armWindows(_ windows: [PlannedWindow]) throws { throw Boom() }
}
