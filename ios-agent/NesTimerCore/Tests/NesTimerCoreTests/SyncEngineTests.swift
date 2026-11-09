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
        let d = await r.engine.onThreshold(eventName: "lock-60", observedMinutes: 60)
        XCTAssertEqual(d, .shield(.timeExpired))
        XCTAssertEqual(r.shield.current, .timeExpired)
    }

    func testDowntimeHoldsOffline() async {
        let r = Rig(now: Fx.at(21))
        r.api.policy = Fx.policy(downtime: ("22:00", "07:00"))
        _ = await r.engine.onForeground()
        r.api.configFails = true
        r.clock.now = Fx.at(22)
        let v1 = await r.engine.onIntervalBoundary()
        XCTAssertEqual(v1, .shield(.downtime(until: "07:00")))
    }

    // MARK: Reporting

    func testFailedReportIsRetriedWithLatestTotal() async {
        let r = Rig()
        r.api.policy = Fx.policy()
        r.api.reportFailures = [10]
        _ = await r.engine.onThreshold(eventName: "chunk-10", observedMinutes: 10)
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
        r.clock.now = Fx.at(0, 0, day: 1)
        let d = await r.engine.onIntervalBoundary()
        XCTAssertEqual(r.store.state.observedMinutes, 0)
        XCTAssertEqual(r.store.state.date, "2026-11-10")
        XCTAssertEqual(d, .shield(.downtime(until: "07:00")))
        // Yesterday's usage must not count against today, even from the stale snapshot.
        r.clock.now = Fx.at(8, 0, day: 1)
        let v2 = await r.engine.onIntervalBoundary()
        XCTAssertEqual(v2, .open(remainingMinutes: 120, why: .withinLimit))
    }

    // MARK: Limits and arming

    func testLimitLoweredBelowUsedShieldsImmediately() async {
        let r = Rig()
        r.api.policy = Fx.policy(limit: 120, used: 40, deviceUsed: 40)
        _ = await r.engine.onThreshold(eventName: "chunk-40", observedMinutes: 40)
        r.api.policy = Fx.policy(limit: 30, used: 40, deviceUsed: 40)
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
        XCTAssertEqual(r.scheduler.windows.map(\.kind), [.downtime])
    }

    func testWarningsFireOnceEach() async {
        let r = Rig()
        r.api.policy = Fx.policy(limit: 60, used: 0, deviceUsed: 0)
        _ = await r.engine.onThreshold(eventName: "warn5-55", observedMinutes: 55)
        _ = await r.engine.onThreshold(eventName: "chunk-55", observedMinutes: 55)
        XCTAssertEqual(r.notifier.warnings, [15, 10, 5])
        r.api.policy = Fx.policy(limit: 120, used: 0, deviceUsed: 0)  // parent raised the limit
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
        let d = await r.engine.onThreshold(eventName: "unlockend-65", observedMinutes: 65)
        XCTAssertEqual(d, .shield(.timeExpired))
    }

    func testUnlockEndsByWallClockToo() async {
        let r = Rig()
        r.api.policy = Fx.policy(limit: 60)
        _ = await r.engine.onThreshold(eventName: "lock-60", observedMinutes: 60)
        _ = await r.engine.submitCode("123456")
        r.clock.now = r.clock.now.addingTimeInterval(6 * 60)
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
        r.clock.now = r.clock.now.addingTimeInterval(301)
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

    // MARK: Paused counting (matches the Mac: activities and TOTP unlocks don't count)

    func testUsageDuringActivityIsNotCounted() async {
        let a = ScheduledActivity(id: "a", name: "Chess", dayOfWeek: 0, startTime: "16:00", endTime: "17:00",
                                  bufferBeforeMinutes: 0, bufferAfterMinutes: 0)
        let r = Rig(now: Fx.at(15, 50))
        r.api.policy = Fx.policy(limit: 60, activities: [a])
        _ = await r.engine.onThreshold(eventName: "chunk-20", observedMinutes: 20)
        r.clock.now = Fx.at(16)
        _ = await r.engine.onIntervalBoundary()                                   // activity starts
        r.clock.now = Fx.at(16, 30)
        _ = await r.engine.onThreshold(eventName: "chunk-45", observedMinutes: 45) // 25 min used in activity
        r.clock.now = Fx.at(17)
        let d = await r.engine.onIntervalBoundary()                               // activity ends
        XCTAssertEqual(r.store.state.countedMinutes, 20)
        XCTAssertEqual(d, .open(remainingMinutes: 40, why: .withinLimit))
        XCTAssertEqual(r.api.reports.last?.0, 20)
    }

    func testUsageDuringTOTPUnlockIsNotCounted() async {
        let r = Rig()
        r.api.policy = Fx.policy(limit: 60)
        _ = await r.engine.onThreshold(eventName: "lock-60", observedMinutes: 60)
        _ = await r.engine.submitCode("123456")
        _ = await r.engine.onThreshold(eventName: "unlockend-65", observedMinutes: 65)
        XCTAssertEqual(r.store.state.countedMinutes, 60)
    }

    func testBonusTimeIsCounted() async {
        let r = Rig()
        r.api.policy = Fx.policy(limit: 60, bonusUntil: Fx.at(15).addingTimeInterval(3600))
        _ = await r.engine.onThreshold(eventName: "chunk-70", observedMinutes: 70)
        XCTAssertEqual(r.store.state.countedMinutes, 70)
    }
}
