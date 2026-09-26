import XCTest
import SwiftUI
@testable import AppScrollCore

final class ChatScrollPersistencePolicyTests: XCTestCase {
    func testIdleResizeDoesNotOverwriteReaderPosition() {
        var policy = ChatScrollPersistencePolicy()
        XCTAssertFalse(policy.shouldCaptureGeometry)
        XCTAssertFalse(policy.transition(to: .idle))
        XCTAssertFalse(policy.shouldCaptureGeometry)
    }

    func testUserGestureCapturesThroughDecelerationAndFinalIdleOffset() {
        var policy = ChatScrollPersistencePolicy()
        XCTAssertTrue(policy.transition(to: .tracking))
        XCTAssertTrue(policy.shouldCaptureGeometry)
        XCTAssertTrue(policy.transition(to: .interacting))
        XCTAssertTrue(policy.transition(to: .decelerating))
        XCTAssertTrue(policy.transition(to: .idle))
        XCTAssertFalse(policy.shouldCaptureGeometry)
    }

    func testProgrammaticAnimationCannotReplaceSavedOffset() {
        var policy = ChatScrollPersistencePolicy()
        XCTAssertTrue(policy.transition(to: .interacting))
        XCTAssertFalse(policy.transition(to: .animating))
        XCTAssertFalse(policy.shouldCaptureGeometry)
        XCTAssertFalse(policy.transition(to: .idle))
    }

    func testNewMessagesFollowOnlyNearBottom() {
        XCTAssertTrue(ChatScrollPersistencePolicy.shouldFollowNewContent(
            visibleBottom: 980, contentHeight: 1_000))
        XCTAssertFalse(ChatScrollPersistencePolicy.shouldFollowNewContent(
            visibleBottom: 700, contentHeight: 1_000))
    }

    func testNearBottomThresholdBoundaryDoesNotPullReaderDown() {
        XCTAssertFalse(ChatScrollPersistencePolicy.shouldFollowNewContent(
            visibleBottom: 964, contentHeight: 1_000))
        XCTAssertTrue(ChatScrollPersistencePolicy.shouldFollowNewContent(
            visibleBottom: 965, contentHeight: 1_000))
    }

    func testOffsetsAreIsolatedBySurfaceAndConversation() {
        var store = ChatScrollOffsetStore()
        store.save(120, for: "notchTab:chat-a")
        store.save(640, for: "panelTab:chat-a")
        store.save(310, for: "notchTab:chat-b")

        XCTAssertEqual(store.offset(for: "notchTab:chat-a"), 120)
        XCTAssertEqual(store.offset(for: "panelTab:chat-a"), 640)
        XCTAssertEqual(store.offset(for: "notchTab:chat-b"), 310)
        XCTAssertNil(store.offset(for: "panelTab:chat-b"))
    }

    func testLatestGestureOffsetReplacesOlderOffsetOnlyForSameChat() {
        var store = ChatScrollOffsetStore()
        store.save(100, for: "notchTab:chat-a")
        store.save(220, for: "notchTab:chat-b")
        store.save(175, for: "notchTab:chat-a")

        XCTAssertEqual(store.offset(for: "notchTab:chat-a"), 175)
        XCTAssertEqual(store.offset(for: "notchTab:chat-b"), 220)
    }
}
