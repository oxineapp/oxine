import SwiftUI
import Testing
@testable import NotchKit

@MainActor
private final class Tab: NotchModule {
    let id: String
    let tabSide: NotchTabSide
    let expandedHeight: CGFloat?
    var title: String { id }
    var icon: String { "circle" }
    var onIdleChange: (() -> Void)?
    init(_ id: String, _ side: NotchTabSide = .left, height: CGFloat? = nil) {
        self.id = id
        self.tabSide = side
        self.expandedHeight = height
    }
    func expandedView() -> AnyView { AnyView(EmptyView()) }
}

@MainActor
struct NotchTabsTests {
    @Test
    func tabsAskingForTheRightGoThereFirstAndTheLeftOverflowsAfter() {
        let tabs = [Tab("home"), Tab("shelf"), Tab("chats", .right), Tab("calendar"), Tab("weather"), Tab("notes")]
        let ears = NotchExpandedRoot.tabEars(tabs)
        #expect(ears.left.map(\.id) == ["home", "shelf", "calendar", "weather"])
        #expect(ears.right.map(\.id) == ["chats", "notes"])
    }

    @Test
    func aTabsHeightIsKeptBetweenTheStandardAndTheTallest() {
        #expect(NotchExpandedRoot.contentHeight(for: Tab("home")) == NotchExpandedRoot.contentHeight)
        #expect(NotchExpandedRoot.contentHeight(for: Tab("tiny", height: 40)) == NotchExpandedRoot.contentHeight)
        #expect(NotchExpandedRoot.contentHeight(for: Tab("chats", height: 300)) == 300)
        #expect(NotchExpandedRoot.contentHeight(for: Tab("huge", height: 2000)) == NotchExpandedRoot.tallestContent)
    }

    @Test
    func theRightEarWidensForItsTabsSoTheIslandStaysCentred() {
        let few = [Tab("home"), Tab("shelf")]
        let withChats = few + [Tab("chats", .right), Tab("mail", .right), Tab("music", .right)]
        let notch: CGFloat = 200
        #expect(NotchExpandedRoot.contentWidth(for: withChats, notchWidth: notch)
                >= NotchExpandedRoot.contentWidth(for: few, notchWidth: notch))
        let strips = NotchExpandedRoot.stripWidths(left: 2, right: 3)
        #expect(strips.right > NotchExpandedRoot.stripWidths(left: 2, right: 0).right)
    }
}
