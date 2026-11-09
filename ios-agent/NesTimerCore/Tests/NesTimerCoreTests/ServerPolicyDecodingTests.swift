import XCTest
@testable import NesTimerCore

final class ServerPolicyDecodingTests: XCTestCase {
    func testLegacyPayloadDecodesWithoutThrowing() throws {
        let json = #"{"downtime_enabled": true, "downtime_start": "22:00", "downtime_end": "08:00", "screen_time_enabled": true, "screen_time_limit_minutes": 120, "used_minutes_today": 10.0}"#
        let p = try JSONDecoder().decode(ServerPolicy.self, from: Data(json.utf8))
        XCTAssertFalse(p.reportsDeviceUsage)
        XCTAssertEqual(p.otherDevicesUsed, 0)
        XCTAssertNil(p.deviceCapMinutes)
    }

    func testFullPayload() throws {
        let json = #"{"downtime_enabled": false, "downtime_start": "22:00", "downtime_end": "08:00", "screen_time_enabled": true, "screen_time_limit_minutes": 120, "used_minutes_today": 10.0, "device_used_minutes": 7.5, "device_cap_minutes": 60, "bonus_until": "2026-11-09T15:00:00.123456+00:00", "activities": [{"id": "a1", "name": "Homework", "day_of_week": 0, "start_time": "16:00", "end_time": "17:00", "buffer_before_minutes": 5, "buffer_after_minutes": 5, "enabled": true}]}"#
        let p = try JSONDecoder().decode(ServerPolicy.self, from: Data(json.utf8))
        XCTAssertEqual(p.otherDevicesUsed, 2.5)
        XCTAssertEqual(p.deviceCapMinutes, 60)
        XCTAssertEqual(p.activities?.first?.name, "Homework")
        XCTAssertNotNil(p.bonusUntilDate)
    }

    func testRoundTripsThroughJSONForTheSnapshot() throws {
        let p = ServerPolicy(downtimeEnabled: true, downtimeStart: "22:00", downtimeEnd: "07:00", screenTimeEnabled: true,
                             screenTimeLimitMinutes: 60, usedMinutesToday: 30, deviceUsedMinutes: 10, deviceCapMinutes: nil)
        let back = try JSONDecoder().decode(ServerPolicy.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back, p)
        XCTAssertTrue(back.reportsDeviceUsage)
    }
}
