import XCTest
@testable import UsageTimeAgent

/// Tests for UsageTracker logic — time accumulation, day rollover, persistence.
/// Note: These test the pure logic. Screen state detection (IOKit) cannot be
/// unit-tested and should be tested via integration tests on real macOS.
final class UsageTrackerLogicTests: XCTestCase {

    func testCurrentDateFormat() {
        let tracker = UsageTracker()
        let dateStr = tracker.currentDateString()
        // Should be YYYY-MM-DD format
        let parts = dateStr.split(separator: "-")
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0].count, 4) // year
        XCTAssertEqual(parts[1].count, 2) // month
        XCTAssertEqual(parts[2].count, 2) // day
    }

    func testSetUsedMinutesCurrentDay() {
        let tracker = UsageTracker()
        let today = tracker.currentDateString()

        tracker.setUsedMinutes(45.0, forDate: today)
        XCTAssertEqual(tracker.getUsedMinutesToday(), 45.0)
    }

    func testSetUsedMinutesTakesHigherValue() {
        let tracker = UsageTracker()
        let today = tracker.currentDateString()

        tracker.setUsedMinutes(100.0, forDate: today)
        tracker.setUsedMinutes(50.0, forDate: today)  // lower value
        XCTAssertEqual(tracker.getUsedMinutesToday(), 100.0)  // kept the higher
    }

    func testSetUsedMinutesWrongDay() {
        let tracker = UsageTracker()

        tracker.setUsedMinutes(100.0, forDate: "1999-01-01")
        XCTAssertEqual(tracker.getUsedMinutesToday(), 0.0)  // didn't apply
    }
}
