import XCTest
@testable import NesTimerCore

final class TOTPTests: XCTestCase {
    let rfcSecret = "3132333435363738393031323334353637383930"  // "12345678901234567890"

    func testRFC4226Vectors() {
        XCTAssertEqual(TOTP.code(secretHex: rfcSecret, counter: 0), "755224")
        XCTAssertEqual(TOTP.code(secretHex: rfcSecret, counter: 1), "287082")
        XCTAssertEqual(TOTP.code(secretHex: rfcSecret, counter: 9), "520489")
    }

    func testVerifyAcceptsPlusMinusOneStep() {
        let now = Date(timeIntervalSince1970: 3000)  // counter 10 with the 300 s step
        for counter: UInt64 in [9, 10, 11] {
            XCTAssertTrue(TOTP.verify(secretHex: rfcSecret, code: TOTP.code(secretHex: rfcSecret, counter: counter)!, now: now))
        }
        XCTAssertFalse(TOTP.verify(secretHex: rfcSecret, code: TOTP.code(secretHex: rfcSecret, counter: 12)!, now: now))
    }

    func testBadSecretNeverVerifies() {
        XCTAssertNil(TOTP.code(secretHex: "zz", counter: 0))
        XCTAssertFalse(TOTP.verify(secretHex: "zz", code: "000000", now: Date()))
    }
}
