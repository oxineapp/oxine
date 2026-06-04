import AppKit
import Foundation

extension Notification.Name {
    /// Posted when a two-finger horizontal trackpad swipe over the panel asks to
    /// move between tabs. `object` is a `SwipeDirection`. MainView turns it into a
    /// step through the enabled tabs (see `navigateBySwipe`).
    static let swipeNavigate = Notification.Name("swipeNavigate")
}

/// Which way a horizontal swipe goes. `next`/`previous` are relative to the tab
/// bar order, not the screen, so the slide animation always matches.
enum SwipeDirection { case next, previous }

extension AppDelegate {
    /// Inspect a scroll event for a deliberate two-finger horizontal swipe and, on
    /// one, post `.swipeNavigate`. Returns true when the event was consumed so the
    /// caller swallows it (keeps the swipe from also scrolling content sideways).
    ///
    /// We key off `scrollWheel` rather than AppKit's `swipeWithEvent:` because the
    /// latter only fires when the user has enabled "swipe between pages" in
    /// Trackpad settings; precise scroll deltas are always present on a trackpad.
    func handleSwipeScroll(_ event: NSEvent) -> Bool {
        // Travel (points) before a gesture commits to the horizontal axis, and the
        // travel that equals one tab step once it has. A continuous swipe keeps
        // stepping: each `step` of further travel advances another tab. The step is
        // driven by the Settings sensitivity slider (higher = shorter step = more
        // sensitive); default 0.7 lands near the original 70pt feel.
        let axisCommit: CGFloat = 16
        let sensitivity = (UserDefaults(suiteName: "com.oxine.settings")?
            .object(forKey: "swipeSensitivity") as? Double) ?? 0.7
        let step = 120 - CGFloat(sensitivity) * 80   // 40 (most) … 120 (least)

        // Trackpad only (mouse wheels get no tab nav), and only the live finger
        // gesture — never its inertia tail.
        guard let panel, panel.isVisible,
              event.hasPreciseScrollingDeltas,
              event.momentumPhase.isEmpty else { return false }

        if event.phase.contains(.began) {
            swipeAccumX = 0; swipeAccumY = 0; swipeHorizontal = false
            return false
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            let wasHorizontal = swipeHorizontal
            swipeAccumX = 0; swipeAccumY = 0; swipeHorizontal = false
            return wasHorizontal     // eat the tail of a swipe we acted on
        }

        swipeAccumX += event.scrollingDeltaX
        swipeAccumY += event.scrollingDeltaY

        // Commit to an axis once there's enough travel. A clearly-vertical gesture
        // is left alone for the rest of the gesture so in-tab scrolling is never
        // stolen; an undecided one passes through until it tips one way.
        if !swipeHorizontal {
            if abs(swipeAccumX) > axisCommit, abs(swipeAccumX) > abs(swipeAccumY) * 1.5 {
                swipeHorizontal = true
            } else if abs(swipeAccumY) > axisCommit {
                return false         // vertical scroll — not ours
            } else {
                return false         // still ambiguous
            }
        }

        // Horizontal gesture: emit a step per `step` of travel, draining the
        // accumulator so a held swipe keeps advancing tab by tab.
        // Natural-scroll mapping: swipe right (deltaX > 0) goes to the previous
        // tab, swipe left advances — matching browser back/forward.
        while abs(swipeAccumX) >= step {
            let dir: SwipeDirection = swipeAccumX < 0 ? .next : .previous
            swipeAccumX -= swipeAccumX < 0 ? -step : step
            NotificationCenter.default.post(name: .swipeNavigate, object: dir)
        }
        return true
    }
}
