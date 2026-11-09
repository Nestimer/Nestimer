import XCTest
@testable import NesTimerCore

final class SetupStringTests: XCTestCase {
    func testPlain() {
        let s = SetupString.parse("https://my.nestimer.com|abc")
        XCTAssertEqual(s?.serverURL.absoluteString, "https://my.nestimer.com")
        XCTAssertEqual(s?.token, "abc")
    }

    func testTrimsWhitespaceAndTrailingSlash() {
        let s = SetupString.parse("  https://my.nestimer.com/|abc \n")
        XCTAssertEqual(s?.serverURL.absoluteString, "https://my.nestimer.com")
        XCTAssertEqual(s?.token, "abc")
    }

    func testMigratesOldIPURL() {
        XCTAssertEqual(SetupString.parse("http://134.209.8.62:8000|abc")?.serverURL.absoluteString, "https://my.nestimer.com")
    }

    func testRejectsMalformed() {
        for raw in ["https://my.nestimer.com|", "|abc", "abc", "a|b|c", "ftp://x.com|abc", "my.nestimer.com|abc"] {
            XCTAssertNil(SetupString.parse(raw), raw)
        }
    }
}
