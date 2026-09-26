import SwiftUI

/// Separates genuine reader-driven scrolling from geometry changes caused by
/// resizing, view removal, or programmatic navigation.
public struct ChatScrollPersistencePolicy {
    public private(set) var isUserScrollActive = false

    public init() {}

    /// Returns true when the phase's current coordinate should be persisted.
    public mutating func transition(to phase: ScrollPhase) -> Bool {
        switch phase {
        case .tracking, .interacting, .decelerating:
            isUserScrollActive = true
            return true
        case .idle:
            let shouldCapture = isUserScrollActive
            isUserScrollActive = false
            return shouldCapture
        case .animating:
            // Programmatic scrolling and layout animation must never replace a
            // coordinate the reader chose.
            isUserScrollActive = false
            return false
        }
    }

    public var shouldCaptureGeometry: Bool { isUserScrollActive }

    public static func shouldFollowNewContent(
        visibleBottom: CGFloat,
        contentHeight: CGFloat,
        threshold: CGFloat = 36
    ) -> Bool {
        contentHeight - visibleBottom < threshold
    }
}

/// Runtime-owned offsets keyed by surface and conversation. Keeping this store
/// outside transient SwiftUI views is what lets a collapsed notch restore the
/// reader's exact location when its view is created again.
public struct ChatScrollOffsetStore {
    private var offsets: [String: CGFloat] = [:]

    public init() {}

    public func offset(for key: String) -> CGFloat? { offsets[key] }

    public mutating func save(_ offset: CGFloat, for key: String) {
        offsets[key] = offset
    }

    public mutating func removeAll() { offsets.removeAll() }
}
