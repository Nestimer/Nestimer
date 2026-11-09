import XCTest
@testable import NesTimerCore

final class SchedulePlannerTests: XCTestCase {
    func plan(_ p: ServerPolicy, now: Date) -> [PlannedWindow] {
        SchedulePlanner.plan(policy: p, now: now, calendar: Fx.cal)
    }
    func act(_ id: String, day: Int, _ s: String, _ e: String, before: Int = 0, after: Int = 0, enabled: Bool = true) -> ScheduledActivity {
        ScheduledActivity(id: id, name: id, dayOfWeek: day, startTime: s, endTime: e,
                          bufferBeforeMinutes: before, bufferAfterMinutes: after, enabled: enabled)
    }

    func testOvernightDowntimeFromEvening() {
        let w = plan(Fx.policy(downtime: ("22:00", "07:00")), now: Fx.at(20))
        XCTAssertEqual(w, [PlannedWindow(name: "downtime-202611092200-202611100700", start: Fx.at(22), end: Fx.at(7, day: 1), kind: .downtime)])
    }

    func testInProgressDowntimeKeepsItsRealStart() {
        // 23:30, inside 22:00–07:00: the window is still registered (its end must wake us).
        let w = plan(Fx.policy(downtime: ("22:00", "07:00")), now: Fx.at(23, 30))
        XCTAssertEqual(w.first, PlannedWindow(name: "downtime-202611092200-202611100700", start: Fx.at(22), end: Fx.at(7, day: 1), kind: .downtime))
    }

    func testMorningInsideOvernightDowntimeFromYesterday() {
        let w = plan(Fx.policy(downtime: ("22:00", "07:00")), now: Fx.at(6))
        XCTAssertEqual(w.first?.start, Fx.at(22, day: -1))
        XCTAssertEqual(w.first?.end, Fx.at(7))
        XCTAssertEqual(w.count, 2)  // and tonight's
    }

    func testNoDowntimeWhenDisabledOrEmpty() {
        XCTAssertEqual(plan(Fx.policy(), now: Fx.at(12)), [])
        XCTAssertEqual(plan(Fx.policy(downtime: ("08:00", "08:00")), now: Fx.at(12)), [])
    }

    func testShortActivityPaddedTo15() {
        let w = plan(Fx.policy(activities: [act("a", day: 0, "10:00", "10:05")]), now: Fx.at(9))
        XCTAssertEqual(w, [PlannedWindow(name: "activity-a-202611091000-202611091005", start: Fx.at(10), end: Fx.at(10, 15), kind: .activity)])
    }

    func testActivityBuffersApplied() {
        let w = plan(Fx.policy(activities: [act("a", day: 0, "16:00", "17:00", before: 5, after: 5)]), now: Fx.at(9))
        XCTAssertEqual(w.first?.start, Fx.at(15, 55))
        XCTAssertEqual(w.first?.end, Fx.at(17, 5))
    }

    func testTomorrowsActivityWithinHorizon() {
        let w = plan(Fx.policy(activities: [act("a", day: 1, "08:00", "09:00")]), now: Fx.at(20))
        XCTAssertEqual(w.first?.start, Fx.at(8, day: 1))
    }

    func testPastAndOtherDaysSkipped() {
        let w = plan(Fx.policy(activities: [act("a", day: 0, "08:00", "09:00"), act("b", day: 3, "08:00", "09:00")]), now: Fx.at(12))
        XCTAssertEqual(w, [])
    }

    func testDisabledActivitySkipped() {
        XCTAssertEqual(plan(Fx.policy(activities: [act("a", day: 0, "16:00", "17:00", enabled: false)]), now: Fx.at(9)), [])
    }

    func testTruncatedToMax() {
        var many: [ScheduledActivity] = []
        for i in 0..<30 {
            let hour = 1 + i / 2
            let minute = (i % 2) * 30
            let start = String(format: "%02d:%02d", hour, minute)
            let end = String(format: "%02d:%02d", hour, minute + 20)
            many.append(act("a\(i)", day: 0, start, end))
        }
        let w = plan(Fx.policy(activities: many), now: Fx.at(0, 30))
        XCTAssertEqual(w.count, SchedulePlanner.maxWindows)
        XCTAssertEqual(w.first?.start, Fx.at(1))
        XCTAssertEqual(w, w.sorted { $0.start < $1.start })
    }
}
