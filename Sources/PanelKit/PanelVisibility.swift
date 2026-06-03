import Foundation
import Combine

/// Whether the menu-bar panel is currently on screen.
///
/// Ordering the panel out (`orderOut`) does **not** fire SwiftUI `.onDisappear`
/// on its hosted content, so views can't tell the window went away — they keep
/// animating and refreshing off-screen. `MenubarApp` drives this from its
/// show/close path to give everyone a reliable visibility signal.
///
/// Only *UI churn* (live gauges, continuous animations) should react to this.
/// Control logic — the fan curve, the charge limit — deliberately keeps running
/// while hidden and must not be gated on it.
@MainActor
public final class PanelVisibility: ObservableObject {
    public static let shared = PanelVisibility()

    @Published public private(set) var isOpen = false

    private init() {}

    public func set(_ open: Bool) {
        guard isOpen != open else { return }
        isOpen = open
        // Mirrored as a notification so non-SwiftUI observers (the managers) can
        // listen without importing Combine plumbing.
        NotificationCenter.default.post(name: .panelVisibilityChanged, object: open)
    }
}

public extension Notification.Name {
    /// Posted whenever the panel shows or hides; `object` is the new `Bool` open
    /// state.
    static let panelVisibilityChanged = Notification.Name("panelVisibilityChanged")
}
