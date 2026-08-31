import XCTest
@testable import LyricsCore

final class LRCTests: XCTestCase {
    func testRepeatedTimestampsUnicodeAndOrdering() {
        let lines = LRC.parse("[00:05.5][00:01.250] İstanbul 🎵\n[ar:Artist]\n[00:03] middle")
        XCTAssertEqual(lines.map(\.timestamp), [1.25, 3, 5.5])
        XCTAssertEqual(lines.map(\.text), ["İstanbul 🎵", "middle", "İstanbul 🎵"])
    }
    func testOffsetsZeroAndInstrumentalGaps() {
        let lines = LRC.parse("[00:01]one\n[00:02]\n[00:04]four")
        XCTAssertNil(LRC.line(in: lines, position: 0, adjustment: 0))
        XCTAssertEqual(LRC.line(in: lines, position: 1, adjustment: 0), "one")
        XCTAssertEqual(LRC.line(in: lines, position: 0.7, adjustment: 0.3), "one")
        XCTAssertNil(LRC.line(in: lines, position: 1, adjustment: -0.1))
        XCTAssertNil(LRC.line(in: lines, position: 3, adjustment: 0))
        XCTAssertEqual(LRC.line(in: lines, position: 3, adjustment: 1), "four")
    }
    func testLRCOffsetAndInvalidInput() {
        XCTAssertEqual(LRC.parse("[offset:+500]\n[00:02]early").first?.timestamp, 1.5)
        XCTAssertEqual(LRC.parse("[offset:-500]\n[00:02]late").first?.timestamp, 2.5)
        XCTAssertTrue(LRC.parse("[00:99]bad\nplain lyrics").isEmpty)
        XCTAssertNil(LRC.line(in: [], position: 0, adjustment: 0))
        XCTAssertNil(LRC.line(in: LRC.parse("[00:00]zero"), position: .nan, adjustment: 0))
    }
}
