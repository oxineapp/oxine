import XCTest
@testable import GestureKit

final class TouchFrameTests: XCTestCase {
    // Build the C ABI bytes independently of Swift's Finger initializer/layout.
    private func frame(states: [Int32], ids: [Int32]? = nil) -> Data {
        var data = Data(count: states.count * 96)
        func store<T>(_ value: T, at offset: Int) {
            var value = value
            withUnsafeBytes(of: &value) { data.replaceSubrange(offset..<(offset + $0.count), with: $0) }
        }
        for (index, state) in states.enumerated() {
            let start = index * 96
            store(Int32(17), at: start)
            store(Double(100), at: start + 8)
            store(ids?[index] ?? Int32(index + 100), at: start + 16)
            store(state, at: start + 20)
            store(Float(0.2 + Double(index) * 0.1), at: start + 32)
            store(Float(0.4), at: start + 36)
            store(Float(0.8), at: start + 48)
        }
        return data
    }

    func testContactRecordStrideAndMultipleFingerCoordinates() throws {
        XCTAssertEqual(MemoryLayout<Finger>.stride, 96)
        let bytes = frame(states: [4, 4, 4])
        let touches = try XCTUnwrap(bytes.withUnsafeBytes { Multitouch.decodeFrame($0.baseAddress, count: 3) })
        XCTAssertEqual(touches.map(\.id), [100, 101, 102])
        XCTAssertEqual(touches.map(\.x), [0.2, 0.3, 0.4])
        XCTAssertEqual(touches.map(\.size), [0.8, 0.8, 0.8])
    }

    func testRawTouchDownAndStaggeredReleaseProduceExactlyOneTap() throws {
        var recognizer = ThreeFingerTapRecognizer()
        let states: [[Int32]] = [[3, 3, 3], [4, 4, 4], [5, 4, 4], [6, 5, 4], [7, 6, 5], []]
        var taps = 0
        for (index, contacts) in states.enumerated() {
            let bytes = frame(states: contacts)
            let touches = try XCTUnwrap(bytes.withUnsafeBytes { Multitouch.decodeFrame($0.baseAddress, count: contacts.count) })
            if recognizer.update(touches: touches, time: Double(index) * 0.04, enabled: true) { taps += 1 }
        }
        XCTAssertEqual(taps, 1)
    }

    func testHoverNeverBecomesATapAndInvalidRecordsDoNotBecomeARelease() {
        var r = ThreeFingerTapRecognizer()
        let hover = frame(states: [1, 2, 2])
        let touches = hover.withUnsafeBytes { Multitouch.decodeFrame($0.baseAddress, count: 3)! }
        XCTAssertTrue(touches.isEmpty)
        XCTAssertFalse(r.update(touches: touches, time: 0, enabled: true))
        XCTAssertNil(Multitouch.decodeFrame(nil, count: 1))
        XCTAssertNil(Multitouch.decodeFrame(nil, count: -1))
        XCTAssertEqual(Multitouch.decodeFrame(nil, count: 0)?.count, 0)
        let malformed = frame(states: [4, 99, 4])
        XCTAssertNil(malformed.withUnsafeBytes { Multitouch.decodeFrame($0.baseAddress, count: 3) })
        let duplicate = frame(states: [4, 4], ids: [1, 1])
        XCTAssertNil(duplicate.withUnsafeBytes { Multitouch.decodeFrame($0.baseAddress, count: 2) })
    }
}
