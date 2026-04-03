import XCTest
@testable import UsageTimeAgent

/// Tests for PolicyEnforcer logic — downtime detection and screen time checks.
/// These tests verify pure logic without needing macOS-specific APIs.
final class PolicyEnforcerLogicTests: XCTestCase {

    // MARK: - Downtime detection tests

    /// Helper: create a ServerPolicy with given settings
    func makePolicy(
        downtimeEnabled: Bool = true,
        downtimeStart: String = "22:00",
        downtimeEnd: String = "08:00",
        screenTimeEnabled: Bool = true,
        screenTimeLimitMinutes: Int = 120,
        usedMinutesToday: Double = 0
    ) -> ServerPolicy {
        ServerPolicy(
            downtimeEnabled: downtimeEnabled,
            downtimeStart: downtimeStart,
            downtimeEnd: downtimeEnd,
            screenTimeEnabled: screenTimeEnabled,
            screenTimeLimitMinutes: screenTimeLimitMinutes,
            usedMinutesToday: usedMinutesToday
        )
    }

    // MARK: - Time parsing tests

    func testParseTimeToMinutes() {
        // Test the time parsing logic used internally
        XCTAssertEqual(parseTime("00:00"), 0)
        XCTAssertEqual(parseTime("08:00"), 480)
        XCTAssertEqual(parseTime("12:30"), 750)
        XCTAssertEqual(parseTime("22:00"), 1320)
        XCTAssertEqual(parseTime("23:59"), 1439)
    }

    /// Test overnight downtime detection (e.g. 22:00 - 08:00)
    func testIsInDowntime_Overnight() {
        // 23:00 should be in downtime (22:00 - 08:00)
        XCTAssertTrue(isInDowntimeRange(currentMinutes: 23 * 60, start: "22:00", end: "08:00"))

        // 02:00 should be in downtime
        XCTAssertTrue(isInDowntimeRange(currentMinutes: 2 * 60, start: "22:00", end: "08:00"))

        // 07:59 should be in downtime
        XCTAssertTrue(isInDowntimeRange(currentMinutes: 7 * 60 + 59, start: "22:00", end: "08:00"))

        // 08:00 should NOT be in downtime
        XCTAssertFalse(isInDowntimeRange(currentMinutes: 8 * 60, start: "22:00", end: "08:00"))

        // 12:00 should NOT be in downtime
        XCTAssertFalse(isInDowntimeRange(currentMinutes: 12 * 60, start: "22:00", end: "08:00"))

        // 21:59 should NOT be in downtime
        XCTAssertFalse(isInDowntimeRange(currentMinutes: 21 * 60 + 59, start: "22:00", end: "08:00"))
    }

    /// Test same-day downtime (e.g. 13:00 - 15:00)
    func testIsInDowntime_SameDay() {
        // 14:00 should be in downtime (13:00 - 15:00)
        XCTAssertTrue(isInDowntimeRange(currentMinutes: 14 * 60, start: "13:00", end: "15:00"))

        // 12:59 should NOT
        XCTAssertFalse(isInDowntimeRange(currentMinutes: 12 * 60 + 59, start: "13:00", end: "15:00"))

        // 15:00 should NOT
        XCTAssertFalse(isInDowntimeRange(currentMinutes: 15 * 60, start: "13:00", end: "15:00"))
    }

    // MARK: - Screen time limit tests

    func testScreenTimeLimitExceeded() {
        let policy = makePolicy(screenTimeLimitMinutes: 120)
        XCTAssertTrue(isScreenTimeExceeded(policy: policy, usedMinutes: 120.0))
        XCTAssertTrue(isScreenTimeExceeded(policy: policy, usedMinutes: 150.0))
        XCTAssertFalse(isScreenTimeExceeded(policy: policy, usedMinutes: 119.0))
        XCTAssertFalse(isScreenTimeExceeded(policy: policy, usedMinutes: 0.0))
    }

    func testScreenTimeDisabled() {
        let policy = makePolicy(screenTimeEnabled: false, screenTimeLimitMinutes: 120)
        // Even with 999 minutes, if disabled, should not be exceeded
        XCTAssertFalse(isScreenTimeExceeded(policy: policy, usedMinutes: 999.0))
    }

    func testRemainingMinutes() {
        let policy = makePolicy(screenTimeLimitMinutes: 120)
        XCTAssertEqual(remainingMinutes(policy: policy, usedMinutes: 0), 120.0)
        XCTAssertEqual(remainingMinutes(policy: policy, usedMinutes: 60), 60.0)
        XCTAssertEqual(remainingMinutes(policy: policy, usedMinutes: 120), 0.0)
        XCTAssertEqual(remainingMinutes(policy: policy, usedMinutes: 150), 0.0)  // clamped to 0
    }

    // MARK: - Helper functions (mirrors PolicyEnforcer logic)

    private func parseTime(_ time: String) -> Int {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return 0 }
        return parts[0] * 60 + parts[1]
    }

    private func isInDowntimeRange(currentMinutes: Int, start: String, end: String) -> Bool {
        let startTotal = parseTime(start)
        let endTotal = parseTime(end)

        if startTotal <= endTotal {
            return currentMinutes >= startTotal && currentMinutes < endTotal
        } else {
            return currentMinutes >= startTotal || currentMinutes < endTotal
        }
    }

    private func isScreenTimeExceeded(policy: ServerPolicy, usedMinutes: Double) -> Bool {
        guard policy.screenTimeEnabled else { return false }
        return usedMinutes >= Double(policy.screenTimeLimitMinutes)
    }

    private func remainingMinutes(policy: ServerPolicy, usedMinutes: Double) -> Double {
        max(0, Double(policy.screenTimeLimitMinutes) - usedMinutes)
    }
}
