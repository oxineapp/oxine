import XCTest
import CoreGraphics
@testable import GestureKit

final class MouseClickTests: XCTestCase {
    func testMiddleClickUsesButtonTwoAndDoesNotLeakFn() {
        let events = ActionRunner.clickEvents("middle", at: CGPoint(x: 300, y: 200),
                                              flags: [.maskSecondaryFn, .maskShift])
        XCTAssertEqual(events.map(\.type), [.otherMouseDown, .otherMouseUp])
        for event in events {
            XCTAssertEqual(event.getIntegerValueField(.mouseEventButtonNumber), 2)
            XCTAssertEqual(event.getIntegerValueField(.mouseEventClickState), 1)
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), ActionRunner.magic)
            XCTAssertEqual(event.location, CGPoint(x: 300, y: 200))
            XCTAssertEqual(event.flags, .maskShift)
        }
    }
}
