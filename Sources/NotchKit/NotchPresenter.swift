import SwiftUI
import AppKit
import Combine
import DynamicNotchKit

/// Bridges our module system onto DynamicNotchKit, which owns the window, the
/// notch shape, geometry, and the fluid expand/compact animation. We supply
/// content (compact peeks + the expanded tab) and drive open/close ourselves.
///
/// Why we don't use DynamicNotchKit's own hover: its window is a *fixed
/// half-screen panel* that never sets `ignoresMouseEvents`, so when collapsed it
/// silently eats clicks across the whole top-centre of the screen (a "ghost"
/// blocker). Instead we detect hover from the global mouse position against the
/// notch region — exactly like Boring Notch — and flip `ignoresMouseEvents` so the
/// window is click-through whenever it isn't expanded.
/// A tiny shared box the expanded SwiftUI view writes its *real* on-screen card
/// rect into, so the presenter can derive the interactive region by measurement
/// instead of guessed pixel constants. SwiftUI `.frame(in: .global)` is in the
/// window's coordinate space (top-left origin); the presenter flips it to screen
/// coords using the window frame.
@MainActor
final class NotchLayoutBox {
    /// The cards' frame in SwiftUI global (window) coordinates, or nil pre-layout.
    var cardsWindowFrame: CGRect?
}

@MainActor
public final class NotchPresenter {
    /// Show a synthesised (floating) notch on displays without a hardware cutout.
    public var allowFauxNotch: Bool

    private let controller: NotchController
    private var notch: (any DynamicNotchControllable)?
    private weak var window: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var screen: NSScreen?
    private var hoverTimer: Timer?
    private let layout = NotchLayoutBox()
    private var systemHUD: SystemHUDMonitor?
    private var peekHub: PeekHub?
    private var barOverlay: NotchBarOverlay?

    private var wantExpanded = false
    private var reconciling = false
    /// The tab we auto-switched away from for a drag, so we can switch back when
    /// the drag ends. nil when we haven't auto-flipped.
    private var autoFlippedFrom: String?
    /// The drag pasteboard's changeCount last time no mouse button was held — the
    /// baseline that lets us tell a NEW drag from the stale type a finished drag
    /// leaves behind (see `updateAutoFlip`).
    private var idleDragChangeCount = NSPasteboard(name: .drag).changeCount

    public init(controller: NotchController, allowFauxNotch: Bool = false) {
        self.controller = controller
        self.allowFauxNotch = allowFauxNotch
    }

    public var isShowing: Bool { notch != nil }

    public func show() {
        guard notch == nil, let screen = NotchGeometry.preferredScreen() else { return }
        let hasNotch = NotchGeometry.hasNotch(screen)
        guard hasNotch || allowFauxNotch else { return }
        self.screen = screen

        let controller = self.controller
        // The real reserved band above the content (the notch height), so the tab
        // strip can ride up into it. Derived from the actual notched screen, not
        // measured from a GeometryReader (which reads ~0 inside the inset content).
        let bandHeight = NotchGeometry.notchFrame(for: screen).height
        let layout = self.layout
        // Live data for the collapsed ears (now-playing + agents + CPU).
        let home = controller.modules.compactMap { $0 as? HomeModule }.first
        let hub = PeekHub(nowPlaying: home?.nowPlaying)
        hub.start()
        self.peekHub = hub
        // The opt-in bar outline (click-through, hidden in fullscreen).
        if hasNotch && PeekContent.barEnabled {
            let bar = NotchBarOverlay(hub: hub, screen: screen)
            bar.start()
            self.barOverlay = bar
        }
        let dn = DynamicNotch(
            hoverBehavior: [.keepVisible],
            style: hasNotch ? .notch : .floating,
            expanded: { NotchExpandedRoot(controller: controller, bandHeight: bandHeight) { layout.cardsWindowFrame = $0 }.environment(\.controlActiveState, .active) },
            compactLeading: { NotchCompactLeading(controller: controller, hub: hub).environment(\.controlActiveState, .active) },
            compactTrailing: { NotchCompactTrailing(controller: controller, hub: hub).environment(\.controlActiveState, .active) }
        )
        // Go straight compact → expanded. By default DynamicNotchKit inserts an
        // intermediate *hide* (collapse, wait 0.25s, re-expand) on every open —
        // that's the deterministic stutter mid-animation.
        dn.transitionConfiguration = .init(skipIntermediateHides: true)
        self.notch = dn

        // Pinning keeps it open even without hover.
        controller.$pinned
            .sink { [weak self] pinned in
                guard let self, pinned else { return }
                self.wantExpanded = true
                self.reconcile()
            }
            .store(in: &cancellables)

        // Hide the bar while the HUD or a sneak peek takes over the ears (they
        // balloon the island; the metric bar wrapping them looks wrong).
        controller.$hud
            .sink { [weak self] hud in
                guard let self else { return }
                self.barOverlay?.setSuppressed(hud != nil || self.controller.peekText != nil)
            }
            .store(in: &cancellables)
        controller.$peekText
            .sink { [weak self] peek in
                guard let self else { return }
                self.barOverlay?.setSuppressed(self.controller.hud != nil || peek != nil)
            }
            .store(in: &cancellables)

        // Sneak peek: flash the new track's title beside the cutout on change.
        if let home = controller.modules.compactMap({ $0 as? HomeModule }).first {
            home.nowPlaying.$track
                .map { $0?.title }
                .removeDuplicates()
                .dropFirst()
                .sink { [weak self] title in
                    guard let self, let title, !title.isEmpty,
                          NotchKit.settingsDefaults.object(forKey: "notchSneakPeek") as? Bool ?? true,
                          !self.wantExpanded else { return }
                    self.controller.peek(title)
                }
                .store(in: &cancellables)
        }

        startSystemHUD()
        startHoverTracking()
        reconcile()                      // begin collapsed + click-through
    }

    /// Watch volume / brightness and flash the notch HUD on change (opt-out via
    /// `notchSystemHUD`). Permission-free — see `SystemHUDMonitor`.
    private func startSystemHUD() {
        guard NotchKit.settingsDefaults.object(forKey: "notchSystemHUD") as? Bool ?? true else { return }
        let monitor = SystemHUDMonitor()
        monitor.onChange = { [weak self] hud in self?.controller.showHUD(hud) }
        monitor.start()
        systemHUD = monitor
    }

    public func hide() {
        hoverTimer?.invalidate(); hoverTimer = nil
        systemHUD?.stop(); systemHUD = nil
        barOverlay?.stop(); barOverlay = nil
        peekHub?.stop(); peekHub = nil
        cancellables.removeAll()
        let n = notch
        notch = nil
        window = nil
        Task { await n?.hide() }
        controller.stop()
    }

    // MARK: hover (global mouse vs. notch region)

    private func startHoverTracking() {
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickHover() }
        }
        RunLoop.main.add(t, forMode: .common)
        hoverTimer = t
    }

    private func tickHover() {
        guard let screen else { return }
        // Hysteresis: when open, test the larger open region so small movements
        // don't snap it shut; when collapsed, test the small notch region.
        let region = wantExpanded ? openRegion(screen) : closedRegion(screen)
        let want = controller.pinned || region.contains(NSEvent.mouseLocation)
        if want != wantExpanded {
            // A firm tap as it springs open — DynamicNotchKit fires this from its
            // own hover, which we bypass, so we do it here. `.levelChange` is the
            // most pronounced of the three system patterns.
            if want {
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }
            wantExpanded = want
            reconcile()
        }
        updateAutoFlip()
        updateClickThrough(screen)
    }

    /// If a file is being dragged and the active tab has no drop zone (Home with a
    /// non-Shelf slot), flip to the Shelf tab so there's somewhere to drop — then
    /// flip back once the drag ends. The drag pasteboard keeps its `fileURL` type
    /// even after a drag finishes, so checking the type alone misfires on ordinary
    /// clicks (which was silently yanking the active tab back to Home). We instead
    /// require the drag pasteboard's `changeCount` to have advanced past the value
    /// captured while no button was held — i.e. a genuinely NEW drag — and only
    /// ever restore from the Shelf, so a tab you picked yourself is never overridden.
    private func updateAutoFlip() {
        let dragPb = NSPasteboard(name: .drag)
        let leftDown = NSEvent.pressedMouseButtons & 1 != 0

        if !leftDown {
            // Idle: remember the pasteboard state, and undo any auto-flip.
            idleDragChangeCount = dragPb.changeCount
            if let from = autoFlippedFrom {
                autoFlippedFrom = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                    guard let self, self.autoFlippedFrom == nil,
                          self.controller.activeModuleID == "shelf" else { return }
                    self.controller.select(from)
                }
            }
            return
        }

        // Button held: a real file drag only if a new drag session bumped the
        // pasteboard since we were last idle (filters the stale leftover type).
        let dragging = dragPb.changeCount != idleDragChangeCount
            && (dragPb.types?.contains(.fileURL) ?? false)
        if dragging, autoFlippedFrom == nil,
           controller.activeModuleID == "home",
           controller.module("shelf") != nil,
           NotchKit.settingsDefaults.string(forKey: "notchHomeSlot") != "shelf" {
            autoFlippedFrom = controller.activeModuleID
            controller.select("shelf")
        }
    }

    /// The window is a fixed half-screen panel, so it must be click-through
    /// everywhere except the bit actually showing UI — otherwise the transparent
    /// area eats clicks and, crucially, blocks drag-and-drop across the whole
    /// top-centre of the desktop.
    ///
    /// Live ONLY over the live region (the measured panel when open, the small
    /// notch region when collapsed); click-through everywhere else. This holds even
    /// during a drag: the decision is purely positional, so a file dragged over the
    /// notch makes it a drop target while one dragged *past* it under the panel is
    /// never intercepted. (The old rule went fully live on any held button, turning
    /// the entire half-screen panel into a drag deadzone. Auto-flip to the Shelf
    /// keys off the drag pasteboard, not mouse events, so it still opens without
    /// the window needing to be live.)
    private func updateClickThrough(_ screen: NSScreen) {
        guard let w = currentWindow() else { return }
        let region: CGRect
        if wantExpanded {
            // If we haven't measured the cards yet, fall back to the open region
            // rather than going fully live (which would re-introduce the deadzone).
            region = panelHitRegion() ?? openRegion(screen)
        } else {
            region = closedRegion(screen)
        }
        w.ignoresMouseEvents = !region.contains(NSEvent.mouseLocation)
    }

    /// The visible panel's bounds in *screen* coordinates, derived from the cards'
    /// real measured frame (reported by the SwiftUI view) rather than guessed
    /// constants. SwiftUI's global frame is in window space (top-left origin,
    /// y-down); we flip it through the window frame to screen space, then extend
    /// the top up to the screen edge so the tab strip (which sits in the band above
    /// the cards) is covered too. A few px of margin for the rounded corners.
    private func panelHitRegion() -> CGRect? {
        guard let r = layout.cardsWindowFrame, let w = window, let screen else { return nil }
        let wf = w.frame
        let cards = CGRect(x: wf.minX + r.minX,
                           y: wf.maxY - r.maxY,
                           width: r.width, height: r.height)
        let m: CGFloat = 8
        let minX = cards.minX - m
        let bottom = cards.minY - m
        let top = screen.frame.maxY            // include the tab strip up in the band
        return CGRect(x: minX, y: bottom, width: cards.width + m * 2, height: top - bottom)
    }

    /// DynamicNotchKit creates its window lazily on the first expand/compact, so we
    /// can't cache it at `show()`. Fetch it on demand and, the first time we see
    /// it, patch its class so Liquid Glass stays lively while we're a background app.
    private func currentWindow() -> NSWindow? {
        if let window { return window }
        guard let w = NSApp.windows.first(where: {
            NSStringFromClass(type(of: $0)) == "DynamicNotchKit.DynamicNotchPanel"
        }) else { return nil }
        window = w
        w.forceActiveGlassAppearance()
        // DynamicNotchKit pins the panel at `.screenSaver` (1000), which sits ABOVE
        // the system drag image — so a dragged file vanishes behind the notch and
        // never drops. Drop to just above the menu bar (matching Boring Notch's
        // `.mainMenu + 3`): still over the menu bar and app windows, but below the
        // drag image, so drag-and-drop works.
        w.level = .mainMenu + 3
        return w
    }

    /// Top slop so a cursor pinned to the screen edge (it clamps to maxY-1) still
    /// counts as "at the notch". Used by BOTH regions, so they share a top edge
    /// and the open region strictly contains the closed one — no open/close
    /// flicker at the boundary.
    private let topSlop: CGFloat = 4

    /// Width of each compact peek (album art / visualizer) that flanks the cutout
    /// when something is playing — so the closed hover zone covers them too, not
    /// just the bare notch.
    private let peekSlot: CGFloat = 58

    /// The closed-notch hover target: the real cutout (derived from the notch
    /// rect, not a guessed width) plus, when the idle peeks are showing, the
    /// album-art/visualizer widths that flank it. Centred on `midX`, plus a few
    /// px of top slop.
    private func closedRegion(_ screen: NSScreen) -> CGRect {
        let n = NotchGeometry.notchFrame(for: screen)
        let peeks: CGFloat = controller.idleModule != nil ? peekSlot * 2 : 0
        let w = n.width + peeks
        return CGRect(x: screen.frame.midX - w / 2, y: n.minY, width: w, height: n.height + topSlop)
    }

    /// The open surface's bounds: concentric with the notch (same `midX`, same
    /// top), sized to the actual open window — the notch height plus the content's
    /// own footprint (both from `NotchExpandedRoot`'s constants, so the zone tracks
    /// the rendered window). Strictly contains `closedRegion`, so the hover test
    /// can never bounce on a shared edge.
    private func openRegion(_ screen: NSScreen) -> CGRect {
        let f = screen.frame
        let n = NotchGeometry.notchFrame(for: screen)
        let w = NotchExpandedRoot.openWidth
        let h = n.height + NotchExpandedRoot.openHeightBelowNotch
        return CGRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h + topSlop)
    }

    // MARK: reconcile toward desired state

    private func reconcile() {
        // The bar traces the *collapsed* island. Hide it the instant the notch
        // starts opening; it stays hidden through the whole open and only returns
        // once a collapse has fully settled back to compact (revealed below, after
        // `compact` awaits). Synced before the in-flight guard so rapid hover
        // toggles never strand it open.
        if wantExpanded { barOverlay?.setExpanded(true) }
        guard !reconciling, let notch, let screen else { return }
        reconciling = true
        Task { @MainActor in
            while true {
                let target = wantExpanded
                if target {
                    barOverlay?.setExpanded(true)
                    await notch.expand(on: screen)
                } else {
                    await notch.compact(on: screen)
                    // Fully minimised now — bring the bar back unless we've since
                    // been asked to reopen.
                    if !wantExpanded { barOverlay?.setExpanded(false) }
                }
                if wantExpanded == target { break }
            }
            reconciling = false
        }
    }
}
