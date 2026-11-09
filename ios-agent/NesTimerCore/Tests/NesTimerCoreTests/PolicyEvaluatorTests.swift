import XCTest
@testable import NesTimerCore

final class PolicyEvaluatorTests: XCTestCase {
    func eval(_ p: ServerPolicy, deviceUsed: Double = 0, unlockUntil: Date? = nil, now: Date) -> Decision {
        PolicyEvaluator.evaluate(policy: p, deviceUsedMinutes: deviceUsed, unlockUntil: unlockUntil, now: now, calendar: Fx.cal)
    }

    func testActivityBeatsDowntime() {
        let a = ScheduledActivity(id: "a", name: "Chess", dayOfWeek: 0, startTime: "22:00", endTime: "23:00",
                                  bufferBeforeMinutes: 0, bufferAfterMinutes: 0)
        let d = eval(Fx.policy(downtime: ("21:00", "07:00"), activities: [a]), now: Fx.at(22, 30))
        XCTAssertEqual(d, .open(remainingMinutes: 120, why: .activity(endsAt: "23:00")))
    }

    func testTemporaryUnlockBeatsLimit() {
        let now = Fx.at(15)
        let d = eval(Fx.policy(limit: 60, used: 90, deviceUsed: 90), deviceUsed: 90, unlockUntil: now + 180, now: now)
        XCTAssertEqual(d, .open(remainingMinutes: 0, why: .temporaryUnlock))
    }

    func testExpiredUnlockIgnored() {
        let now = Fx.at(15)
        let d = eval(Fx.policy(limit: 60, used: 90, deviceUsed: 90), deviceUsed: 90, unlockUntil: now - 1, now: now)
        XCTAssertEqual(d, .shield(.timeExpired))
    }

    func testBonusBeatsDowntime() {
        let now = Fx.at(23)
        let d = eval(Fx.policy(downtime: ("22:00", "07:00"), bonusUntil: now + 600), now: now)
        XCTAssertEqual(d, .open(remainingMinutes: 120, why: .bonus))
    }

    func testOvernightDowntime() {
        let p = Fx.policy(downtime: ("22:00", "08:00"))
        XCTAssertEqual(eval(p, now: Fx.at(23)), .shield(.downtime(until: "08:00")))
        XCTAssertEqual(eval(p, now: Fx.at(7, 59, day: 1)), .shield(.downtime(until: "08:00")))
        XCTAssertEqual(eval(p, now: Fx.at(8, 0, day: 1)), .open(remainingMinutes: 120, why: .withinLimit))
    }

    func testDowntimeStartEqualsEndIsNoDowntime() {
        XCTAssertEqual(eval(Fx.policy(downtime: ("08:00", "08:00")), now: Fx.at(8)),
                       .open(remainingMinutes: 120, why: .withinLimit))
    }

    func testRemainingBelowOneShields() {
        // Server snapshot: child 59.5 total of which this device 29.5 → others 30.
        let p = Fx.policy(limit: 60, used: 59.5, deviceUsed: 29.5)
        XCTAssertEqual(eval(p, deviceUsed: 29.5, now: Fx.at(15)), .shield(.timeExpired))
    }

    func testLocalGrowthCountsAgainstBudget() {
        // Snapshot: 40 total, 10 of them here → 30 on other devices. The phone has since
        // counted 25 locally → 55 of 60 used; at 30 locally the budget is gone.
        let p = Fx.policy(limit: 60, used: 40, deviceUsed: 10)
        XCTAssertEqual(eval(p, deviceUsed: 25, now: Fx.at(15)), .open(remainingMinutes: 5, why: .withinLimit))
        XCTAssertEqual(eval(p, deviceUsed: 30, now: Fx.at(15)), .shield(.timeExpired))
    }

    func testDeviceCapBinds() {
        let p = Fx.policy(limit: 120, used: 30, deviceUsed: 30, cap: 30)
        XCTAssertEqual(eval(p, deviceUsed: 30, now: Fx.at(15)), .shield(.deviceCapReached))
    }

    func testScreenTimeDisabledOpensWithNilRemaining() {
        XCTAssertEqual(eval(Fx.policy(limitEnabled: false, used: 500), now: Fx.at(15)), .open(remainingMinutes: nil, why: .noLimit))
    }

    func testOvernightActivityFromYesterday() {
        let a = ScheduledActivity(id: "a", name: "Movie", dayOfWeek: 6, startTime: "23:00", endTime: "01:00",
                                  bufferBeforeMinutes: 0, bufferAfterMinutes: 0)
        // Sunday 23:00 → Monday 01:00; now is Monday 00:30, with downtime active.
        let d = eval(Fx.policy(downtime: ("22:00", "07:00"), activities: [a]), now: Fx.at(0, 30))
        XCTAssertEqual(d, .open(remainingMinutes: 120, why: .activity(endsAt: "01:00")))
    }

    func testDisabledActivityIgnored() {
        let a = ScheduledActivity(id: "a", name: "x", dayOfWeek: 0, startTime: "22:00", endTime: "23:00",
                                  bufferBeforeMinutes: 0, bufferAfterMinutes: 0, enabled: false)
        XCTAssertEqual(eval(Fx.policy(downtime: ("21:00", "07:00"), activities: [a]), now: Fx.at(22, 30)),
                       .shield(.downtime(until: "07:00")))
    }
}
