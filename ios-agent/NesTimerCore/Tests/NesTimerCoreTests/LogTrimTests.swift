import XCTest
@testable import NesTimerCore

final class LogTrimTests: XCTestCase {
    private func lines(_ n: Int) -> String { (1...n).map { "line \($0)\n" }.joined() }

    func testUnderLimitIsUnchanged() {
        XCTAssertEqual(LogTrim.tail(lines(3), keepingLines: 5), lines(3))
    }

    func testKeepsLastLines() {
        let out = LogTrim.tail(lines(10), keepingLines: 3)
        XCTAssertEqual(out, "line 8\nline 9\nline 10\n")
    }

    func testDropsPartialLastLineFromCount() {
        // A torn final write (no newline) still counts as a line and is kept.
        let out = LogTrim.tail("a\nb\nc\nd", keepingLines: 2)
        XCTAssertEqual(out, "c\nd")
    }

    func testEmpty() {
        XCTAssertEqual(LogTrim.tail("", keepingLines: 5), "")
    }

    func testNeedsTrimBySize() {
        XCTAssertFalse(LogTrim.needsTrim(fileSize: 1000, maxBytes: 1000))
        XCTAssertTrue(LogTrim.needsTrim(fileSize: 1001, maxBytes: 1000))
    }
}
