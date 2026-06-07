import SwiftUI

/// The notch's tab brain: owns the ordered tabs, which tab is active (persisted,
/// so it reopens where you left it), and which tab owns the idle peek. The
/// window/animation/hover are DynamicNotchKit's job (see `NotchPresenter`).
@MainActor
public final class NotchController: ObservableObject {
    /// The active tab whose `expandedView` shows when expanded. Persisted.
    @Published public var activeModuleID: String { didSet { persistActiveTab() } }
    /// The tab currently owning the idle peek (highest `idlePriority` among those
    /// that `wantsIdle`), or nil for the bare notch.
    @Published public private(set) var idleModuleID: String?
    /// Keep the notch expanded regardless of hover (toggled from the expanded UI).
    @Published public var pinned = false
    /// A transient "sneak peek" line shown beside the cutout (e.g. a new track's
    /// title) for a couple of seconds, without fully opening the notch.
    @Published public private(set) var peekText: String?
    /// A transient system HUD (volume / brightness) taking over the compact ears.
    /// Highest priority of the collapsed-notch overlays.
    @Published public private(set) var hud: NotchHUD?

    public let modules: [any NotchModule]

    private static let lastTabKey = "notchLastTab"
    private var peekClear: DispatchWorkItem?
    private var hudClear: DispatchWorkItem?

    public init(modules: [any NotchModule]) {
        self.modules = modules
        // Reopen the last-used tab if it still exists, else the first one.
        let saved = NotchKit.settingsDefaults.string(forKey: Self.lastTabKey)
        self.activeModuleID = modules.first(where: { $0.id == saved })?.id ?? modules.first?.id ?? ""
        for m in modules {
            m.activate()
            m.onIdleChange = { [weak self] in self?.resolveIdle() }
        }
        resolveIdle()
    }

    /// Stop every module's live work (host calls this on teardown).
    public func stop() { modules.forEach { $0.deactivate() } }

    public func module(_ id: String) -> (any NotchModule)? { modules.first { $0.id == id } }
    public var activeModule: (any NotchModule)? { module(activeModuleID) }
    public var idleModule: (any NotchModule)? { idleModuleID.flatMap(module) }

    /// Select which tab is active (from the tab bar).
    public func select(_ id: String) { activeModuleID = id }

    /// Flash a sneak-peek line beside the cutout for a couple of seconds.
    public func peek(_ text: String, seconds: TimeInterval = 2.5) {
        peekClear?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { peekText = text }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { self?.peekText = nil }
        }
        peekClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Flash a system HUD (volume / brightness) over the compact ears. Repeated
    /// calls while one's showing just update the value and push the dismissal out,
    /// so holding a volume key keeps a single HUD live.
    public func showHUD(_ hud: NotchHUD, seconds: TimeInterval = 1.7) {
        hudClear?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { self.hud = hud }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { self?.hud = nil }
        }
        hudClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Re-pick the idle module. Called when any module's `wantsIdle` flips.
    public func resolveIdle() {
        let winner = modules
            .filter { $0.wantsIdle }
            .max { $0.idlePriority < $1.idlePriority }
        let newID = winner?.id
        if newID != idleModuleID { idleModuleID = newID }
    }

    private func persistActiveTab() {
        NotchKit.settingsDefaults.set(activeModuleID, forKey: Self.lastTabKey)
    }
}
