import XCTest
@testable import NesTimerCore

/// iOS fires window callbacks a few seconds early (seen: bonus end 8 s early). A wake just
/// before a schedule edge must decide as if the edge had passed, or nothing wakes us again
/// (a shielded phone produces no usage events).
final class EdgeTimingTests: XCTestCase {
    func testDowntimeEndFiredEarlyOpens() async {
        let r = Rig(now: Fx.at(7, 0).addingTimeInterval(-120))  // 06:58, inside downtime
        r.api.policy = Fx.policy(downtime: ("22:00", "07:00"))
        let before = await r.engine.onForeground()
        XCTAssertEqual(before, .shield(.downtime(until: "07:00")))
        r.clock.set(Fx.at(7, 0).addingTimeInterval(-8))        // intervalDidEnd, 8 s early
        let d = await r.engine.onIntervalBoundary()
        XCTAssertFalse(d.isShielded)
    }

    func testDowntimeStartFiredEarlyShields() async {
        let r = Rig(now: Fx.at(22, 0).addingTimeInterval(-8))
        r.api.policy = Fx.policy(downtime: ("22:00", "07:00"))
        let d = await r.engine.onIntervalBoundary()
        XCTAssertEqual(d, .shield(.downtime(until: "07:00")))
    }

    func testBonusEndFiredEarlyEndsBonus() async {
        let r = Rig(now: Fx.at(19, 8).addingTimeInterval(2))   // 19:08:02
        r.api.policy = Fx.policy(limit: 60, used: 60, deviceUsed: 60, bonusUntil: Fx.at(19, 8).addingTimeInterval(10))
        let d = await r.engine.onIntervalBoundary()
        XCTAssertEqual(d, .shield(.timeExpired))
    }

    func testEdgeFurtherThanAMinuteIsNotAnticipated() async {
        let r = Rig(now: Fx.at(7, 0).addingTimeInterval(-120))
        r.api.policy = Fx.policy(downtime: ("22:00", "07:00"))
        let d = await r.engine.onIntervalBoundary()
        XCTAssertEqual(d, .shield(.downtime(until: "07:00")))
    }

    // MARK: Heartbeat

    func testHeartbeatWindowIsAlwaysArmed() async {
        let r = Rig(now: Fx.at(15, 3))
        r.api.policy = Fx.policy(limit: 60)
        _ = await r.engine.onForeground()
        let hb = r.scheduler.windows.filter { $0.kind == .heartbeat }
        XCTAssertEqual(hb.count, 1)
        XCTAssertEqual(hb.first?.end, Fx.at(15, 15))
        XCTAssertEqual(hb.first?.start, Fx.at(15, 0))
    }

    func testHeartbeatSkipsAnEdgeLessThanAMinuteAway() async {
        let r = Rig(now: Fx.at(15, 14).addingTimeInterval(30))
        r.api.policy = Fx.policy(limit: 60)
        _ = await r.engine.onForeground()
        XCTAssertEqual(r.scheduler.windows.first { $0.kind == .heartbeat }?.end, Fx.at(15, 30))
    }

    func testHeartbeatWhileShielded() async {
        let r = Rig()
        r.api.policy = Fx.policy(limit: 60, used: 60, deviceUsed: 60)
        let d = await r.engine.onForeground()
        XCTAssertTrue(d.isShielded)
        XCTAssertTrue(r.scheduler.windows.contains { $0.kind == .heartbeat })
    }

    func testHeartbeatEdgeIsNotAPolicyEdge() async {
        // 14:59:52 with no downtime: anticipating the heartbeat end changes nothing,
        // but it must not be used to snap the policy clock either (no crash, still open).
        let r = Rig(now: Fx.at(15, 0).addingTimeInterval(-8))
        r.api.policy = Fx.policy(limit: 60)
        let d = await r.engine.onIntervalBoundary()
        XCTAssertFalse(d.isShielded)
    }
}

extension EdgeTimingTests {
    /// Windows are armed with minute precision; a bonus ending at :10 s must not get a
    /// window ending at the minute before (that's a wake 10 s early, or 59 s).
    func testBonusWindowEndsOnTheMinuteAfter() async {
        let r = Rig(now: Fx.at(18, 0))
        r.api.policy = Fx.policy(limit: 60, bonusUntil: Fx.at(19, 8).addingTimeInterval(10))
        _ = await r.engine.onForeground()
        XCTAssertEqual(r.scheduler.windows.first { $0.kind == .bonusEnd }?.end, Fx.at(19, 9))
    }

    func testHeartbeatIsArmedFirst() async {
        let r = Rig(now: Fx.at(20))
        r.api.policy = Fx.policy(downtime: ("22:00", "07:00"))
        _ = await r.engine.onForeground()
        XCTAssertEqual(r.scheduler.windows.first?.kind, .heartbeat)
    }
}
