import SwiftUI

/// A tab in the notch. This is NotchKit's extension point — each tab is a
/// top-level surface (Home, Shelf, Calendar…). A module supplies idle "peek"
/// content that flanks the physical cutout when the notch is closed, the full
/// expanded view for when the notch is open and this tab is active, and a bit of
/// identity for the tab bar.
///
/// Modules are reference types so they can hold live managers/observers; their
/// views typically `@ObservedObject` those managers so they re-render on their
/// own. The only thing the controller needs reactively is *who wants the idle
/// slot* — push that via `onIdleChange`.
@MainActor
public protocol NotchModule: AnyObject {
    /// Stable identity (also the key the controller addresses it by, and what's
    /// persisted as the last-open tab).
    var id: String { get }
    /// Label for the tab bar / tooltip.
    var title: String { get }
    /// SF Symbol for the tab bar.
    var icon: String { get }

    /// When several modules want the idle peek at once, the highest priority wins.
    var idlePriority: Int { get }
    /// Whether this module currently wants to own the idle peek (e.g. Home only
    /// while something is playing).
    var wantsIdle: Bool { get }
    /// Set by the controller. Call it whenever `wantsIdle` flips so the idle slot
    /// can re-resolve.
    var onIdleChange: (() -> Void)? { get set }

    /// Idle content shown to the **left** of the physical cutout (e.g. album art).
    func leftPeek() -> AnyView
    /// Idle content shown to the **right** of the cutout (e.g. a visualizer).
    func rightPeek() -> AnyView
    /// The expanded content shown when the notch is open and this tab is active.
    func expandedView() -> AnyView

    /// Start/stop live work alongside the notch's lifecycle.
    func activate()
    func deactivate()
}

public extension NotchModule {
    var idlePriority: Int { 0 }
    var wantsIdle: Bool { false }
    func leftPeek() -> AnyView { AnyView(EmptyView()) }
    func rightPeek() -> AnyView { AnyView(EmptyView()) }
    func activate() {}
    func deactivate() {}
}
