import XCTest
@testable import NesTimerCore

/// Same cases as macos-agent/NesTimerAgentTests/run-logic-tests.sh.
final class RemainingTimeTests: XCTestCase {
    func m(_ l: Int, _ c: Double, _ cap: Int?, _ d: Double) -> Double {
        RemainingTime.minutes(limitMinutes: l, childUsedMinutes: c, deviceCapMinutes: cap, deviceUsedMinutes: d)
    }
    func b(_ l: Int, _ c: Double, _ cap: Int?, _ d: Double) -> LimitSource {
        RemainingTime.binding(limitMinutes: l, childUsedMinutes: c, deviceCapMinutes: cap, deviceUsedMinutes: d)
    }

    func testRemainingUsesSharedBudgetWhenNoCap() { XCTAssertEqual(m(120, 45, nil, 45), 75) }
    func testRemainingCountsTimeSpentOnOtherDevices() { XCTAssertEqual(m(120, 80, nil, 30), 40) }
    func testRemainingIsClampedToZero() { XCTAssertEqual(m(120, 150, nil, 150), 0) }
    func testDeviceCapBindsBeforeSharedBudget() { XCTAssertEqual(m(120, 20, 60, 55), 5) }
    func testSharedBudgetBindsWhenCapIsLooser() { XCTAssertEqual(m(120, 115, 60, 10), 5) }
    func testCapPresentAndLooserStillReadsRealDeviceUsage() { XCTAssertEqual(m(120, 90, 100, 20), 30) }
    func testBindingDeviceCap() { XCTAssertEqual(b(120, 20, 60, 55), .deviceCap) }
    func testBindingSharedBudget() { XCTAssertEqual(b(120, 115, 60, 10), .sharedBudget) }
    func testBindingTieReportsSharedBudget() { XCTAssertEqual(b(120, 100, 40, 20), .sharedBudget) }
}
