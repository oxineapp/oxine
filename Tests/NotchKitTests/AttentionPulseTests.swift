import XCTest
@testable import NotchKit

final class AttentionPulseTests: XCTestCase {
    func testPulseUsesSmoothCosineBreath() {
        let start = AttentionPulseCurve.state(at: 0, colorCount: 1)
        let quarter = AttentionPulseCurve.state(at: AttentionPulseCurve.cycle * 0.25, colorCount: 1)
        let peak = AttentionPulseCurve.state(at: AttentionPulseCurve.cycle * 0.5, colorCount: 1)

        XCTAssertEqual(start.opacity, 0.14, accuracy: 0.0001)
        XCTAssertEqual(quarter.opacity, 0.55, accuracy: 0.0001)
        XCTAssertEqual(peak.opacity, 0.96, accuracy: 0.0001)
        XCTAssertGreaterThan(quarter.opacity, start.opacity)
        XCTAssertGreaterThan(peak.opacity, quarter.opacity)
    }

    func testColorRotatesOnlyAtDarkestPointAndWraps() {
        let justBefore = AttentionPulseCurve.state(at: AttentionPulseCurve.cycle - 0.001, colorCount: 3)
        let next = AttentionPulseCurve.state(at: AttentionPulseCurve.cycle, colorCount: 3)
        let wrapped = AttentionPulseCurve.state(at: AttentionPulseCurve.cycle * 3, colorCount: 3)

        XCTAssertEqual(justBefore.colorIndex, 0)
        XCTAssertEqual(next.colorIndex, 1)
        XCTAssertEqual(wrapped.colorIndex, 0)
        XCTAssertEqual(justBefore.opacity, next.opacity, accuracy: 0.001)
    }

    func testReduceMotionKeepsAStableVisibleIndicator() {
        let low = AttentionPulseCurve.state(at: 0, colorCount: 2, reduceMotion: true)
        let high = AttentionPulseCurve.state(at: AttentionPulseCurve.cycle * 0.5,
                                             colorCount: 2, reduceMotion: true)
        XCTAssertEqual(low.opacity, 0.62)
        XCTAssertEqual(high.opacity, 0.62)
    }
}
