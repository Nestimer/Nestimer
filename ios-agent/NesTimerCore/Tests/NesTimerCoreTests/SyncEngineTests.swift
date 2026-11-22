import XCTest
@testable import NesTimerCore

final class SyncEngineTests: XCTestCase {

    // MARK: Fail-closed

    func testNoSnapshotOfflineShields() async {
        let r = Rig()
        r.api.configFails = true
        let d = await r.engine.onForeground()
        XCTAssertEqual(d, .shield(.timeExpired))
        XCTAssertEqual(r.shield.applied, [.timeExpired])
    }

    func testStaleSnapshotUsesLocalCount() async {
        let r = Rig()
        r.api.policy = Fx.policy(limit: 60, used: 0, deviceUsed: 0)
        _ = await r.engine.onForeground()
        XCTAssertEqual(r.shield.current, nil)
        r.api.configFails = true
        let d = await r.use(60)
        XCTAssertEqual(d, .shield(.timeExpired))
        XCTAssertEqual(r.shield.current, .timeExpired)
    }

    func testDowntimeHoldsOffline() async {
        let r = Rig(now: Fx.at(21))
        r.api.policy = Fx.policy(downtime: ("22:00", "07:00"))
        _ = await r.engine.onForeground()
        r.api.configFails = true
        r.clock.set(Fx.at(22))
        let v1 = await r.engine.onIntervalBoundary()
        XCTAssertEqual(v1, .shield(.downtime(until: "07:00")))
    }

    // MARK: Reporting

    func testFailedReportIsRetriedWithLatestTotal() async {
        let r = Rig()
        r.api.policy = Fx.policy()
        r.api.reportFailures = [10]
        _ = await r.engine.onThreshold(eventName: "chunk-10", observedMinutes: 10)
        r.clock.advance(5 * 60)
        _ = await r.engine.onThreshold(eventName: "chunk-15", observedMinutes: 15)
        XCTAssertEqual(r.api.reports.map(\.0), [10, 15])
        XCTAssertEqual(r.api.reports.map(\.1), [false, true])
        XCTAssertEqual(r.store.state.reportedMinutes, 15)
    }

    func testNothingReportedWhenNothingNew() async {
        let r = Rig()
        r.api.policy = Fx.policy()
        _ = await r.engine.onThreshold(eventName: "chunk-10", observedMinutes: 10)
        _ = await r.engine.onForeground()
        XCTAssertEqual(r.api.reports.map(\.0), [10])
    }

    func testDeviceMinutesNeverDecrease() async {
        let r = Rig()
        r.api.policy = Fx.policy()
        _ = await r.engine.onThreshold(eventName: "chunk-25", observedMinutes: 25)
        _ = await r.engine.onThreshold(eventName: "chunk-20", observedMinutes: 20)
        XCTAssertEqual(r.store.state.observedMinutes, 25)
    }

    func testServerCountHigherThanLocalIsAdopted() async {
        // e.g. app reinstalled: local state lost, server already has 40 for this device today.
        let r = Rig()
        r.api.policy = Fx.policy(limit: 60, used: 40, deviceUsed: 40)
        let d = await r.engine.onForeground()
        XCTAssertEqual(d, .open(remainingMinutes: 20, why: .withinLimit))
    }

    // MARK: Day rollover

    func testDateRolloverResetsCountButKeepsOvernightDowntime() async {
        let r = Rig(now: Fx.at(21))
        r.api.policy = Fx.policy(limit: 120, used: 80, deviceUsed: 80, downtime: ("22:00", "07:00"))
        _ = await r.engine.onThreshold(eventName: "chunk-80", observedMinutes: 80)
        r.api.configFails = true
        r.clock.set(Fx.at(0, 0, day: 1))
        let d = await r.engine.onIntervalBoundary()
        XCTAssertEqual(r.store.state.observedMinutes, 0)
        XCTAssertEqual(r.store.state.date, "2026-11-10")
        XCTAssertEqual(d, .shield(.downtime(until: "07:00")))
        // Yesterday's usage must not count against today, even from the stale snapshot.
        // Still offline (snapshot 11 h old), so only half of today's 120 may be spent.
        r.clock.set(Fx.at(8, 0, day: 1))
        let v2 = await r.engine.onIntervalBoundary()
        XCTAssertEqual(v2, .open(remainingMinutes: 60, why: .withinLimit))
    }

    // MARK: Limits and arming

    func testLimitLoweredBelowUsedShieldsImmediately() async {
        let r = Rig()
        r.api.policy = Fx.policy(limit: 120, used: 40, deviceUsed: 40)
        _ = await r.engine.onThreshold(eventName: "chunk-40", observedMinutes: 40)
        r.api.policy = Fx.policy(limit: 30, used: 40, deviceUsed: 40)
        r.clock.advance(10)
        let d = await r.engine.onForeground()
        XCTAssertEqual(d, .shield(.timeExpired))
        XCTAssertFalse(r.scheduler.events.contains { $0.kind == .lock })
    }

    func testArmsLockAtRemainingBudget() async {
        let r = Rig()
        r.api.policy = Fx.policy(limit: 60, used: 30, deviceUsed: 10)  // 20 on other devices
        _ = await r.engine.onThreshold(eventName: "chunk-10", observedMinutes: 10)
        XCTAssertEqual(r.scheduler.events.first { $0.kind == .lock }?.deviceMinutes, 40)
    }

    func testWindowsArmedFromSnapshot() async {
        let r = Rig(now: Fx.at(20))
        r.api.policy = Fx.policy(downtime: ("22:00", "07:00"))
        _ = await r.engine.onForeground()
        XCTAssertEqual(r.scheduler.windows.map(\.kind).filter { $0 != .heartbeat }, [.downtime])
    }

    func testWarningsFireOnceEach() async {
        let r = Rig()
        r.api.policy = Fx.policy(limit: 60, used: 0, deviceUsed: 0)
        _ = await r.engine.onThreshold(eventName: "warn5-55", observedMinutes: 55)
        _ = await r.engine.onThreshold(eventName: "chunk-55", observedMinutes: 55)
        XCTAssertEqual(r.notifier.warnings, [15, 10, 5])
        r.api.policy = Fx.policy(limit: 120, used: 0, deviceUsed: 0)  // parent raised the limit
        r.clock.advance(10)
        _ = await r.engine.onForeground()
        XCTAssertEqual(r.store.state.warned, [])
    }

    func testExpiredNotifiedOnceOnTransition() async {
        let r = Rig()
        r.api.policy = Fx.policy(limit: 60)
        _ = await r.engine.onThreshold(eventName: "lock-60", observedMinutes: 60)
        _ = await r.engine.onForeground()
        XCTAssertEqual(r.notifier.expiredCount, 1)
    }

    // MARK: TOTP

    func testCodeOnlineGrantsFiveMinutesOfUse() async {
        let r = Rig()
        r.api.policy = Fx.policy(limit: 60)
        _ = await r.engine.onThreshold(eventName: "lock-60", observedMinutes: 60)
        let v3 = await r.engine.submitCode("123456")
        XCTAssertTrue(v3)
        XCTAssertNil(r.shield.current)
        XCTAssertEqual(r.scheduler.events.first { $0.kind == .unlockEnd }?.deviceMinutes, 65)
        // Five more minutes of use → shield again.
        r.clock.advance(5 * 60)
        let d = await r.engine.onThreshold(eventName: "unlockend-65", observedMinutes: 65)
        XCTAssertEqual(d, .shield(.timeExpired))
    }

    func testUnlockEndsByWallClockToo() async {
        let r = Rig()
        r.api.policy = Fx.policy(limit: 60)
        _ = await r.engine.onThreshold(eventName: "lock-60", observedMinutes: 60)
        _ = await r.engine.submitCode("123456")
        r.clock.advance(6 * 60)
        let v4 = await r.engine.onForeground()
        XCTAssertEqual(v4, .shield(.timeExpired))
    }

    func testCodeOfflineFallsBackToKeychainSecret() async {
        let r = Rig()
        r.api.policy = Fx.policy(limit: 60)
        _ = await r.engine.onThreshold(eventName: "lock-60", observedMinutes: 60)
        r.api.verifyResult = nil
        r.api.configFails = true
        let code = TOTP.code(secretHex: "3132333435363738393031323334353637383930",
                             counter: UInt64(r.clock.now.timeIntervalSince1970 / 300))!
        let v5 = await r.engine.submitCode(code)
        XCTAssertTrue(v5)
        XCTAssertNil(r.shield.current)
    }

    func testOfflineCodeAttemptsAreRateLimited() async {
        // Offline there is no server-side limit; 6-digit codes must not be brute-forceable.
        let r = Rig()
        r.api.policy = Fx.policy(limit: 60)
        _ = await r.engine.onThreshold(eventName: "lock-60", observedMinutes: 60)
        r.api.verifyResult = nil
        for _ in 0..<5 { _ = await r.engine.submitCode("000001") }
        let good = TOTP.code(secretHex: "3132333435363738393031323334353637383930",
                             counter: UInt64(r.clock.now.timeIntervalSince1970 / 300))!
        let v6 = await r.engine.submitCode(good)
        XCTAssertFalse(v6)
        r.clock.advance(301)
        let later = TOTP.code(secretHex: "3132333435363738393031323334353637383930",
                              counter: UInt64(r.clock.now.timeIntervalSince1970 / 300))!
        let v7 = await r.engine.submitCode(later)
        XCTAssertTrue(v7)
    }

    func testWrongCodeKeepsShield() async {
        let r = Rig()
        r.api.policy = Fx.policy(limit: 60)
        _ = await r.engine.onThreshold(eventName: "lock-60", observedMinutes: 60)
        r.api.verifyResult = false
        let v8 = await r.engine.submitCode("999999")
        XCTAssertFalse(v8)
        XCTAssertEqual(r.shield.current, .timeExpired)
    }

    func testServerRejectionIsNotOverriddenByOfflineCheck() async {
        let r = Rig()
        r.api.policy = Fx.policy(limit: 60)
        _ = await r.engine.onThreshold(eventName: "lock-60", observedMinutes: 60)
        r.api.verifyResult = false  // server reachable and says no (e.g. rate limited)
        let code = TOTP.code(secretHex: "3132333435363738393031323334353637383930",
                             counter: UInt64(r.clock.now.timeIntervalSince1970 / 300))!
        let v9 = await r.engine.submitCode(code)
        XCTAssertFalse(v9)
    }

    // MARK: Paused counting (matches the Mac: activities, TOTP unlocks and bonus don't count)

    func testUsageDuringActivityIsNotCounted() async {
        let a = ScheduledActivity(id: "a", name: "Chess", dayOfWeek: 0, startTime: "16:00", endTime: "17:00",
                                  bufferBeforeMinutes: 0, bufferAfterMinutes: 0)
        let r = Rig(now: Fx.at(15, 50))
        r.api.policy = Fx.policy(limit: 60, activities: [a])
        _ = await r.engine.onThreshold(eventName: "chunk-20", observedMinutes: 20)
        r.clock.set(Fx.at(16))
        _ = await r.engine.onIntervalBoundary()                                   // activity starts
        // Continuous use during the activity: a chunk every 5 minutes.
        for (i, m) in [25, 30, 35, 40, 45].enumerated() {
            r.clock.set(Fx.at(16, 5 * (i + 1)))
            _ = await r.engine.onThreshold(eventName: "chunk-\(m)", observedMinutes: m)
        }
        r.clock.set(Fx.at(17))
        let d = await r.engine.onIntervalBoundary()                               // activity ends
        // The first in-activity chunk spans the 16:00 boundary; its 5 minutes are split by
        // wall time (we can't know when within the gap they were used): at most one chunk off.
        XCTAssertGreaterThanOrEqual(r.store.state.countedMinutes, 20)
        XCTAssertLessThanOrEqual(r.store.state.countedMinutes, 25)
        guard case .open(let left?, .withinLimit) = d else { return XCTFail("\(d)") }
        XCTAssertGreaterThanOrEqual(left, 35)
    }

    func testUsageDuringTOTPUnlockIsNotCounted() async {
        let r = Rig()
        r.api.policy = Fx.policy(limit: 60)
        _ = await r.engine.onThreshold(eventName: "lock-60", observedMinutes: 60)
        _ = await r.engine.submitCode("123456")
        _ = await r.engine.onThreshold(eventName: "unlockend-65", observedMinutes: 65)
        XCTAssertEqual(r.store.state.countedMinutes, 60)
    }

    /// A bonus is extra time, as on the Mac: given before the limit is reached, what was
    /// left is still left afterwards.
    func testUsageDuringBonusIsNotCounted() async {
        let r = Rig(now: Fx.at(14, 50))
        r.api.policy = Fx.policy(limit: 60)
        _ = await r.engine.onThreshold(eventName: "chunk-20", observedMinutes: 20)
        r.clock.set(Fx.at(15))
        r.api.policy = Fx.policy(limit: 60, bonusUntil: Fx.at(15, 30))
        _ = await r.engine.onForeground()                                         // bonus seen
        for (i, m) in [25, 30, 35, 40, 45, 50].enumerated() {
            r.clock.set(Fx.at(15, 5 * (i + 1)))
            _ = await r.engine.onThreshold(eventName: "chunk-\(m)", observedMinutes: m)
        }
        r.api.policy = Fx.policy(limit: 60, bonusUntil: nil)
        let d = await r.engine.onIntervalBoundary()                               // bonus over
        // The first in-bonus chunk spans the 15:00 boundary and is split by wall time
        // (as for activities): at most one chunk off. Without the pause it would be 50.
        XCTAssertGreaterThanOrEqual(r.store.state.countedMinutes, 20)
        XCTAssertLessThanOrEqual(r.store.state.countedMinutes, 25)
        guard case .open(let left?, .withinLimit) = d else { return XCTFail("\(d)") }
        XCTAssertGreaterThanOrEqual(left, 35)
    }

    func testBonusAfterTheLimitDoesNotCount() async {
        let r = Rig()
        r.api.policy = Fx.policy(limit: 60)
        _ = await r.engine.onThreshold(eventName: "lock-60", observedMinutes: 60)
        r.api.policy = Fx.policy(limit: 60, bonusUntil: Fx.at(16))
        r.clock.advance(10)                       // past the network debounce
        _ = await r.engine.onForeground()
        r.clock.set(Fx.at(15, 10))
        _ = await r.engine.onThreshold(eventName: "chunk-70", observedMinutes: 70)
        XCTAssertEqual(r.store.state.countedMinutes, 60, accuracy: 0.5)   // 10 s before the bonus was seen
    }

    // MARK: Deadlock guard

    func testNoIOSCallsWhileStateIsLocked() async {
        let store = MemoryStore(), api = FakeAPI(), clock = Clock(Fx.at(15))
        api.policy = Fx.policy(limit: 60, downtime: ("22:00", "07:00"))
        let probe = LockCheckingScheduler(store: store)
        let c = clock
        let e = SyncEngine(api: api, store: store, shield: probe, scheduler: probe, notifier: FakeNotifier(),
                           secrets: FakeSecrets(secret: nil), calendar: Fx.cal, now: { c.now }, uptime: { c.uptime })
        _ = await e.onForeground()
        _ = await e.onThreshold(eventName: "lock-60", observedMinutes: 60)
        XCTAssertEqual(probe.violations, 0)
    }
}

final class ArmingTests: XCTestCase {
    func testThresholdsAreRelativeToWhenTheyWereArmed() async {
        let r = Rig()
        r.api.policy = Fx.policy(limit: 60)
        _ = await r.engine.onThreshold(eventName: "chunk-20", observedMinutes: 20)
        let lock = r.scheduler.events.first { $0.kind == .lock }!
        XCTAssertEqual(lock.deviceMinutes, 60)       // absolute, in the name
        XCTAssertEqual(lock.armThreshold, 40)        // usage since arming
        XCTAssertEqual(lock.name, "lock-60")
    }

    func testPassingAChunkDoesNotReArm() async {
        let r = Rig()
        r.api.policy = Fx.policy(limit: 120)
        _ = await r.engine.onThreshold(eventName: "chunk-20", observedMinutes: 20)
        let first = r.scheduler.armCount
        r.clock.advance(5 * 60)
        _ = await r.engine.onThreshold(eventName: "chunk-25", observedMinutes: 25)
        XCTAssertEqual(r.scheduler.armCount, first, "re-arming restarts iOS's count and fires echoes")
    }

    func testLimitChangeReArms() async {
        let r = Rig()
        r.api.policy = Fx.policy(limit: 120)
        _ = await r.engine.onThreshold(eventName: "chunk-20", observedMinutes: 20)
        let first = r.scheduler.armCount
        r.api.policy = Fx.policy(limit: 90)
        r.clock.advance(60)
        _ = await r.engine.onForeground()
        XCTAssertEqual(r.scheduler.armCount, first + 1)
        XCTAssertEqual(r.scheduler.events.first { $0.kind == .lock }?.armThreshold, 70)
    }

    func testRunningOutOfChunksReArms() async {
        let r = Rig()
        r.api.policy = Fx.policy(limitEnabled: false)
        _ = await r.engine.onThreshold(eventName: "chunk-20", observedMinutes: 20)   // chunks 25…120
        let first = r.scheduler.armCount
        await r.use(95)   // up to chunk-115: one left ahead
        XCTAssertEqual(r.scheduler.armCount, first + 1)
    }

    func testArmFailureIsRetriedNextWake() async {
        let store = MemoryStore(), api = FakeAPI(), clock = Clock(Fx.at(15))
        api.policy = Fx.policy(limit: 60)
        let flaky = FlakyScheduler()
        let c = clock
        let e = SyncEngine(api: api, store: store, shield: FakeShield(), scheduler: flaky, notifier: FakeNotifier(),
                           secrets: FakeSecrets(secret: nil), calendar: Fx.cal, now: { c.now }, uptime: { c.uptime })
        flaky.fail = true
        _ = await e.onForeground()
        flaky.fail = false
        clock.advance(60)
        _ = await e.onForeground()
        XCTAssertEqual(flaky.succeeded, 1)
    }
}

final class FlakyScheduler: MonitorScheduler, @unchecked Sendable {
    var fail = false
    var succeeded = 0
    struct Boom: Error {}
    func armEvents(_ events: [PlannedEvent]) throws { if fail { throw Boom() }; succeeded += 1 }
    func armWindows(_ windows: [PlannedWindow]) throws {}
}

final class ConsumedEventTests: XCTestCase {
    /// Seen on device: iOS delivered warn10/warn5/warn1/lock together after 4.5 real minutes.
    /// The clock cap kept the phone open (10 min left) — but those events are one-shot, so
    /// the lock must be re-armed or the phone stays open for good.
    func testEarlyLockEventIsReArmed() async {
        let r = Rig()
        r.api.policy = Fx.policy(limit: 200, used: 177, deviceUsed: 177)
        _ = await r.engine.onThreshold(eventName: "chunk-177", observedMinutes: 177)  // armed up to lock-200
        XCTAssertTrue(r.scheduler.events.contains { $0.name == "lock-200" })
        // As on device: chunk-180 after 25 min, warn15-185 ~5.7 min later, then the burst.
        r.clock.advance(25 * 60)
        _ = await r.engine.onThreshold(eventName: "chunk-180", observedMinutes: 180)
        r.clock.advance(5.7 * 60)
        _ = await r.engine.onThreshold(eventName: "warn15-185", observedMinutes: 185)
        let armsBefore = r.scheduler.armCount
        r.clock.advance(4.5 * 60)
        defer { XCTAssertGreaterThan(r.scheduler.armCount, armsBefore, "fired one-shot events were never re-armed") }
        for name in ["warn5-195", "warn1-199", "lock-200", "warn10-190"] {
            _ = await r.engine.onThreshold(eventName: name, observedMinutes: PlannedEvent.observedMinutes(fromName: name)!)
        }
        let lock = r.scheduler.events.first { $0.kind == .lock }
        XCTAssertNotNil(lock, "no lock armed — phone would stay open")
        XCTAssertEqual(lock?.deviceMinutes, 200)
        XCTAssertGreaterThan(lock?.armThreshold ?? 0, 9)  // ~10.5 min of use from now
    }
}

/// The real scheduler and iOS, as far as arming goes: a request with the same event names
/// and thresholds as the last one is skipped (no restart), and iOS delivers each armed
/// event at most once.
final class OneShotScheduler: MonitorScheduler, @unchecked Sendable {
    var live: [PlannedEvent] = []
    var restarts = 0
    /// The extension is suspended before the next arming reaches iOS.
    var loseNext = false
    private var signature: [String]?
    private var confirmed = 0

    func armEvents(_ events: [PlannedEvent]) throws {
        let sig = events.map { "\($0.armName)@\($0.armThreshold)" }.sorted()
        if sig == signature { return }
        signature = sig
        if loseNext { loseNext = false; return }
        live = events
        confirmed = events.first?.epoch ?? 0
        restarts += 1
    }
    func liveEpoch() -> Int? { confirmed }
    func armWindows(_ windows: [PlannedWindow]) throws {}

    /// iOS delivers the lowest live event.
    func pop() -> PlannedEvent? {
        guard let e = live.min(by: { $0.deviceMinutes < $1.deviceMinutes }) else { return nil }
        live.removeAll { $0.armName == e.armName }
        return e
    }
}

/// Seen on the son's phone 2026-11-22 09:08: right after a restart iOS fired every armed
/// event at once. The clock cap ignored them as usage, but they were spent; the re-arm had
/// the same names and thresholds as before, so nothing restarted — no count and no lock
/// for the rest of the day (4 h of YouTube on a 35-minute limit).
final class EventBurstTests: XCTestCase {
    struct BurstRig {
        let api = FakeAPI(), store = MemoryStore(), scheduler = OneShotScheduler(), clock = Clock(Fx.at(9))
        let engine: SyncEngine
        init() {
            let c = clock
            engine = SyncEngine(api: api, store: store, shield: FakeShield(), scheduler: scheduler,
                                notifier: FakeNotifier(), secrets: FakeSecrets(secret: nil), calendar: Fx.cal,
                                now: { c.now }, uptime: { c.uptime })
            api.policy = Fx.policy(limit: 35)
        }

        @discardableResult
        func fire(_ e: PlannedEvent) async -> Decision {
            await engine.onThreshold(eventName: e.armName, observedMinutes: e.deviceMinutes)
        }

        /// iOS fires everything that is live, at this instant.
        func burst() async {
            let all = scheduler.live
            scheduler.live = []
            for e in all { await fire(e) }
        }

        /// 15 minutes of real use, then warn15-20 arrives early at 17.9 and the engine re-arms.
        func reachTheMorningOf22November() async {
            _ = await engine.onForeground()
            for _ in 0..<3 {
                clock.advance(5 * 60)
                await fire(scheduler.pop()!)
            }
            XCTAssertEqual(store.state.observedMinutes, 15)
            clock.advance(2.9 * 60)
            await fire(scheduler.pop()!)
            XCTAssertEqual(store.state.observedMinutes, 17.9, accuracy: 0.01)
        }
    }

    func testBurstRightAfterARestartIsReArmed() async {
        let r = BurstRig()
        await r.reachTheMorningOf22November()
        let before = r.scheduler.restarts

        await r.burst()

        XCTAssertEqual(r.store.state.observedMinutes, 17.9, accuracy: 0.01, "the burst is not usage")
        XCTAssertEqual(r.scheduler.restarts, before + 1, "one restart for the whole burst")
        XCTAssertTrue(r.scheduler.live.contains { $0.kind == .lock }, "every event is spent: nothing counts or locks")

        // Real use afterwards runs into the lock.
        var d: Decision?
        while let e = r.scheduler.pop() {
            r.clock.advance((Double(e.deviceMinutes) - r.store.state.observedMinutes) * 60)
            d = await r.fire(e)
        }
        XCTAssertEqual(d, .shield(.timeExpired))
    }

    func testBurstOnEveryRestartCannotLoopAndRecoversAtTheNextWake() async {
        let r = BurstRig()
        await r.reachTheMorningOf22November()
        let before = r.scheduler.restarts

        for _ in 0..<50 { await r.burst() }
        XCTAssertLessThanOrEqual(r.scheduler.restarts - before, SyncEngine.armStormLimit)
        // Nothing live can lock the phone, so it isn't left open until the next wake.
        XCTAssertTrue(r.scheduler.live.isEmpty)
        XCTAssertTrue(r.store.state.shielded)

        r.clock.advance(15 * 60)   // the heartbeat
        let d = await r.engine.onIntervalBoundary()
        XCTAssertEqual(d.isShielded, false)
        XCTAssertTrue(r.scheduler.live.contains { $0.kind == .lock })
        XCTAssertEqual(r.store.state.observedMinutes, 17.9, accuracy: 0.01)
    }

    func testArmingLostInTheExtensionIsRedoneAtTheNextWake() async {
        // The engine records the new arming, the extension is suspended before iOS gets it,
        // and iOS then burns the old events in a burst: they look stale, nothing re-arms.
        let r = BurstRig()
        await r.reachTheMorningOf22November()
        r.api.policy = Fx.policy(limit: 40, used: 17.9, deviceUsed: 17.9)
        r.clock.advance(61)
        r.scheduler.loseNext = true
        _ = await r.engine.onForeground()
        XCTAssertFalse(r.scheduler.live.contains { $0.name == "lock-40" })
        await r.burst()
        XCTAssertTrue(r.scheduler.live.isEmpty)

        r.clock.advance(60)
        _ = await r.engine.onIntervalBoundary()
        XCTAssertTrue(r.scheduler.live.contains { $0.name == "lock-40" })
    }

    func testChunkRefillOverTheRestartLimitDoesNotShield() async {
        let r = BurstRig()
        r.api.policy = Fx.policy(limitEnabled: false)
        _ = await r.engine.onForeground()
        r.store.update { s in s.recentArms = Array(repeating: r.clock.now, count: SyncEngine.armStormLimit) }
        var d: Decision?
        for _ in 0..<19 {   // down to one chunk ahead: a refill is due
            let e = r.scheduler.pop()!
            r.clock.advance(1)
            d = await r.engine.onThreshold(eventName: e.armName, observedMinutes: e.deviceMinutes)
            r.store.update { s in s.recentArms = Array(repeating: r.clock.now, count: SyncEngine.armStormLimit) }
        }
        XCTAssertEqual(d?.isShielded, false)
    }

    func testLateEventFromAnEarlierArmingDoesNotSpendTheNewOne() async {
        let r = BurstRig()
        _ = await r.engine.onForeground()
        let old = r.scheduler.live.first { $0.kind == .lock }!
        r.api.policy = Fx.policy(limit: 40)   // the limit moves: re-arm
        r.clock.advance(60)
        _ = await r.engine.onForeground()
        let restarts = r.scheduler.restarts

        r.clock.advance(60)
        await r.fire(old)

        XCTAssertEqual(r.scheduler.restarts, restarts)
        XCTAssertTrue(r.store.state.armedEvents?.contains { $0.kind == .lock } ?? false)
    }

    func testWakesBetweenEventsDoNotRestart() async {
        // A restart resets iOS's count towards the next event. With one chunk ahead and
        // no more to add (limit 35: 15, then the warnings), a wake must leave it alone.
        let r = BurstRig()
        _ = await r.engine.onForeground()
        for _ in 0..<2 {
            r.clock.advance(5 * 60)
            await r.fire(r.scheduler.pop()!)
        }
        XCTAssertEqual(r.store.state.observedMinutes, 10)
        let restarts = r.scheduler.restarts
        for _ in 0..<4 {
            r.clock.advance(61)
            _ = await r.engine.onForeground()
        }
        XCTAssertEqual(r.scheduler.restarts, restarts)
    }

    func testStateFromABuildWithoutEpochsIsReArmedOnce() async {
        // The phone as the fix finds it: the state says "armed", iOS holds only spent events.
        let r = BurstRig()
        _ = await r.engine.onForeground()
        r.store.update { s in
            s.armEpoch = nil
            s.recentArms = nil
            s.armedEvents = s.armedEvents?.map {
                PlannedEvent(name: $0.name, deviceMinutes: $0.deviceMinutes, kind: $0.kind, armThreshold: $0.armThreshold)
            }
        }
        let restarts = r.scheduler.restarts
        for _ in 0..<3 {
            r.clock.advance(61)
            _ = await r.engine.onForeground()
        }
        XCTAssertEqual(r.scheduler.restarts, restarts + 1)
        XCTAssertTrue(r.scheduler.live.allSatisfy { $0.epoch != nil })
    }

    func testArmNameRoundTrip() {
        let e = PlannedEvent(name: "lock-35", deviceMinutes: 35, kind: .lock, armThreshold: 18, epoch: 7)
        XCTAssertEqual(e.armName, "e7.lock-35")
        XCTAssertEqual(PlannedEvent.observedMinutes(fromName: e.armName), 35)
        XCTAssertEqual(PlannedEvent.parse(armName: e.armName).epoch, 7)
        XCTAssertEqual(PlannedEvent.parse(armName: e.armName).name, "lock-35")
        XCTAssertNil(PlannedEvent.parse(armName: "lock-35").epoch)
        XCTAssertEqual(PlannedEvent.parse(armName: "unlockend-65").name, "unlockend-65")
    }
}
