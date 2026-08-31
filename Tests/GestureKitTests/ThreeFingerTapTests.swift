import XCTest
@testable import GestureKit

final class ThreeFingerTapTests: XCTestCase {
    private func touches(_ count: Int, x: Float = 0.5) -> [Multitouch.Touch] {
        (0..<count).map { Multitouch.Touch(id: $0, x: x, y: 0.5, size: 0.1) }
    }
    func testStaggeredLiftFiresOnce() {
        var r = ThreeFingerTapRecognizer()
        XCTAssertFalse(r.update(touches: touches(1), time: 0, enabled: true))
        XCTAssertFalse(r.update(touches: touches(3), time: 0.03, enabled: true))
        XCTAssertFalse(r.update(touches: touches(2), time: 0.1, enabled: true))
        XCTAssertFalse(r.update(touches: touches(1), time: 0.15, enabled: true))
        XCTAssertTrue(r.update(touches: [], time: 0.2, enabled: true))
        XCTAssertFalse(r.update(touches: [], time: 0.21, enabled: true))
    }
    func testSwipeHoldFourthFingerAndPhysicalClickNeverFire() {
        for mode in 0..<4 {
            var r = ThreeFingerTapRecognizer()
            _ = r.update(touches: touches(3), time: 0, enabled: true)
            if mode == 0 { _ = r.update(touches: touches(3, x: 0.7), time: 0.1, enabled: true) }
            if mode == 2 { _ = r.update(touches: touches(4), time: 0.1, enabled: true) }
            if mode == 3 { r.cancel() }
            XCTAssertFalse(r.update(touches: [], time: mode == 1 ? 0.5 : 0.2, enabled: true))
        }
    }
    func testFnOrDisabledDuringContactCancelsUntilAllFingersLift() {
        var r = ThreeFingerTapRecognizer()
        _ = r.update(touches: touches(3), time: 0, enabled: true)
        _ = r.update(touches: touches(3), time: 0.1, enabled: false)
        XCTAssertFalse(r.update(touches: [], time: 0.2, enabled: true))
        _ = r.update(touches: touches(3), time: 1, enabled: true)
        XCTAssertTrue(r.update(touches: [], time: 1.1, enabled: true))
    }
}
