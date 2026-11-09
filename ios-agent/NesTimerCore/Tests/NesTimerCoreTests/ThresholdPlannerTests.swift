import XCTest
@testable import NesTimerCore

final class ThresholdPlannerTests: XCTestCase {
    func minutes(_ e: [PlannedEvent], _ k: (PlannedEvent.Kind) -> Bool) -> [Int] {
        e.filter { k($0.kind) }.map(\.deviceMinutes).sorted()
    }

    func testChunksFromZeroNoLimit() {
        let e = ThresholdPlanner.plan(deviceUsedMinutes: 0, remainingMinutes: nil, unlockEndsAfterMinutes: nil)
        XCTAssertEqual(e.map(\.deviceMinutes).sorted(), Array(stride(from: 5, through: 100, by: 5)))
        XCTAssertTrue(e.allSatisfy { $0.kind == .chunk })
    }

    func testChunksStartAboveCurrentUsage() {
        let e = ThresholdPlanner.plan(deviceUsedMinutes: 80, remainingMinutes: nil, unlockEndsAfterMinutes: nil)
        XCTAssertEqual(e.map(\.deviceMinutes).min(), 85)
        let e2 = ThresholdPlanner.plan(deviceUsedMinutes: 82.4, remainingMinutes: nil, unlockEndsAfterMinutes: nil)
        XCTAssertEqual(e2.map(\.deviceMinutes).min(), 85)
    }

    func testLockAndWarnings() {
        let e = ThresholdPlanner.plan(deviceUsedMinutes: 12, remainingMinutes: 20, unlockEndsAfterMinutes: nil)
        XCTAssertEqual(minutes(e) { $0 == .lock }, [32])
        XCTAssertEqual(e.filter { if case .warning = $0.kind { return true } else { return false } }
                        .sorted { $0.deviceMinutes < $1.deviceMinutes }.map(\.kind),
                       [.warning(minutesLeft: 15), .warning(minutesLeft: 10), .warning(minutesLeft: 5), .warning(minutesLeft: 1)])
        XCTAssertEqual(e.filter { if case .warning = $0.kind { return true } else { return false } }.map(\.deviceMinutes).sorted(),
                       [17, 22, 27, 31])
        XCTAssertEqual(minutes(e) { $0 == .chunk }, [15, 20, 25, 30])
        XCTAssertTrue(e.allSatisfy { $0.deviceMinutes <= 32 })
    }

    func testWarningsAlreadyPassedAreSkipped() {
        let e = ThresholdPlanner.plan(deviceUsedMinutes: 50, remainingMinutes: 7, unlockEndsAfterMinutes: nil)
        XCTAssertEqual(e.compactMap { if case .warning(let n) = $0.kind { return n } else { return nil } }.sorted(), [1, 5])
    }

    func testRemainingZeroArmsNothingAndLocks() {
        XCTAssertEqual(ThresholdPlanner.plan(deviceUsedMinutes: 50, remainingMinutes: 0, unlockEndsAfterMinutes: nil), [])
    }

    func testUnlockEnd() {
        let e = ThresholdPlanner.plan(deviceUsedMinutes: 40.2, remainingMinutes: 0, unlockEndsAfterMinutes: 5)
        XCTAssertEqual(e, [PlannedEvent(name: "unlockend-46", deviceMinutes: 46, kind: .unlockEnd)])
    }

    func testCapAtMaxEventsKeepsLockAndWarnings() {
        let e = ThresholdPlanner.plan(deviceUsedMinutes: 0, remainingMinutes: 300, unlockEndsAfterMinutes: nil)
        XCTAssertEqual(e.count, ThresholdPlanner.maxEvents)
        XCTAssertEqual(minutes(e) { $0 == .lock }, [300])
        XCTAssertEqual(e.filter { if case .warning = $0.kind { return true } else { return false } }.count, 4)
        XCTAssertEqual(minutes(e) { $0 == .chunk }.first, 5)  // nearest chunks kept, furthest dropped
    }

    func testEveryNameCarriesItsMinutes() {
        let e = ThresholdPlanner.plan(deviceUsedMinutes: 12, remainingMinutes: 20, unlockEndsAfterMinutes: 3)
        for ev in e { XCTAssertEqual(PlannedEvent.observedMinutes(fromName: ev.name), ev.deviceMinutes, ev.name) }
    }

    func testNamesAreUnique() {
        let e = ThresholdPlanner.plan(deviceUsedMinutes: 3, remainingMinutes: 12, unlockEndsAfterMinutes: nil)
        XCTAssertEqual(Set(e.map(\.name)).count, e.count)
        XCTAssertEqual(Set(e.map(\.deviceMinutes)).count, e.count)  // no two events on the same minute
    }
}
