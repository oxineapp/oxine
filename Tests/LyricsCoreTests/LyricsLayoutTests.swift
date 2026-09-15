import CoreGraphics
import XCTest
@testable import LyricsCore

final class LyricsLayoutTests: XCTestCase {
    private let screen = CGRect(x: 1920, y: -200, width: 1512, height: 982)
    private let visible = CGRect(x: 1920, y: -150, width: 1512, height: 900)

    func testMaximumAreaFitsOffsetDisplayAtEveryPositionExtreme() {
        for x: CGFloat in [-1500, 0, 1500] {
            for y: CGFloat in [0, 8, 1500] {
                let box = LyricsLayout.frame(screen: screen, visible: visible, notchBottom: 750,
                                             width: 1000, height: 500, xOffset: x, yOffset: y)
                XCTAssertGreaterThanOrEqual(box.minX, screen.minX + 12)
                XCTAssertLessThanOrEqual(box.maxX, screen.maxX - 12)
                XCTAssertGreaterThanOrEqual(box.minY, visible.minY + 12)
                XCTAssertLessThanOrEqual(box.maxY, 750)
                XCTAssertEqual(box.size, CGSize(width: 1000, height: 500))
            }
        }
    }
    func testSmallDisplayClampsDimensions() {
        let screen = CGRect(x: 0, y: 0, width: 800, height: 400)
        let frame = LyricsLayout.frame(screen: screen, visible: screen, notchBottom: 375,
                                       width: 1000, height: 500, xOffset: 0, yOffset: 0)
        XCTAssertEqual(frame, CGRect(x: 12, y: 12, width: 776, height: 363))
    }
    func testResizingKeepsTopAnchorUnderNotch() {
        let short = LyricsLayout.frame(screen: screen, visible: visible, notchBottom: 750,
                                       width: 520, height: 100, xOffset: 0, yOffset: 8)
        let tall = LyricsLayout.frame(screen: screen, visible: visible, notchBottom: 750,
                                      width: 520, height: 500, xOffset: 0, yOffset: 8)
        XCTAssertEqual(short.maxY, tall.maxY)
        XCTAssertEqual(short.maxY, 742)
        XCTAssertEqual(short.midX, screen.midX)
    }
}
