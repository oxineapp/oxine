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
    /// This notch's own panel. DynamicNotchKit rebuilds the panel on a screen
    /// change, so it's read fresh each time; scanning `NSApp.windows` could pick
    /// up another notch's panel.
    private var notchWindow: () -> NSWindow? = { nil }
    private weak var window: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var screen: NSScreen?
    private var hoverTimer: Timer?
    private let layout = NotchLayoutBox()
    private var systemHUD: SystemHUDMonitor?
    private var peekHub: PeekHub?
    /// The metric bar's values, when the bar is on (it's drawn by the island).
    private var barFeed: BarFeed?
    /// The screen has a real cutout, so notices can attach to the notch.
    private var hasCutout = false
    /// The pointer was on the volume/brightness display last tick.
    private var pointerWasOnHUD = false

    private var wantExpanded = false
    private var reconciling = false
    /// How the notch opens. `hover` is the classic behaviour; the other two are
    /// "game mode": a cursor parked at the top of the screen never opens it —
    /// only a click (or ⌘-click) on the collapsed island does. Closing is
    /// always by leaving the open region, so nothing gets stuck.
    public enum OpenTrigger: String, CaseIterable, Sendable {
        case hover, click, commandClick
        public var label: String {
            switch self {
            case .hover: "Hover"
            case .click: "Click"
            case .commandClick: "⌘-click"
            }
        }
        static var current: OpenTrigger {
            OpenTrigger(rawValue: NotchKit.settingsDefaults.string(forKey: "notchOpenTrigger") ?? "") ?? .hover
        }
    }
    /// How far past the open notch the pointer can stray before it closes,
    /// so a fast movement that overshoots its edge doesn't shut it.
    public enum SafeZone: Int, CaseIterable, Sendable {
        case off = 0, small = 16, medium = 32, large = 56
        public var label: String {
            switch self {
            case .off: "Off"
            case .small: "Small"
            case .medium: "Medium"
            case .large: "Large"
            }
        }
        static var current: SafeZone {
            SafeZone(rawValue: NotchKit.settingsDefaults.object(forKey: "notchSafeZone") as? Int ?? 32) ?? .medium
        }
    }
    private var openTrigger: OpenTrigger = .hover
    private var clickMonitors: [Any] = []
    /// Clicked open (or opened by a notice's "Open"): if it opens by then,
    /// the tab gets the keyboard. A deadline, so a click that didn't open it
    /// can't hand the keyboard to some later hover.
    private var focusWhenOpenUntil: Date?
    private var focusWhenOpen: Bool {
        get { focusWhenOpenUntil.map { Date() < $0 } ?? false }
        set { focusWhenOpenUntil = newValue ? Date().addingTimeInterval(1.5) : nil }
    }
    /// Opened on request, not by the pointer: stay open this long even if
    /// the pointer isn't there yet, so it can't snap shut mid-animation.
    private var holdOpenUntil: Date?
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
        KeyHandback.shared.start()
        let hasNotch = NotchGeometry.hasNotch(screen)
        guard hasNotch || allowFauxNotch else { return }
        self.screen = screen

        let controller = self.controller
        // The real reserved band above the content (the notch height), so the tab
        // strip can ride up into it. Derived from the actual notched screen, not
        // measured from a GeometryReader (which reads ~0 inside the inset content).
        let bandHeight = NotchGeometry.notchFrame(for: screen).height
        let notchWidth = NotchGeometry.notchFrame(for: screen).width
        let layout = self.layout
        // Live data for the collapsed ears (now-playing + agents + CPU).
        let home = controller.modules.compactMap { $0 as? HomeModule }.first
        // ScreenLyrics (if its app is installed) follows the same player feed.
        if let home { ScreenLyrics.shared.attach(home.nowPlaying) }
        let hub = PeekHub(nowPlaying: home?.nowPlaying)
        hub.start()
        self.peekHub = hub
        let dn = DynamicNotch(
            hoverBehavior: [.keepVisible],
            style: hasNotch ? .notch(topCornerRadius: 15, bottomCornerRadius: NotchExpandedRoot.bottomCornerRadius) : .floating,
            expanded: { NotchExpandedRoot(controller: controller, bandHeight: bandHeight, notchWidth: notchWidth) { layout.cardsWindowFrame = $0 }.environment(\.controlActiveState, .active) },
            compactLeading: { NotchCompactLeading(controller: controller, hub: hub).environment(\.controlActiveState, .active) },
            compactTrailing: { NotchCompactTrailing(controller: controller, hub: hub).environment(\.controlActiveState, .active) }
        )
        dn.expandedInset = NotchExpandedRoot.kitInset
        // Notices grow out of the bottom of the closed notch (and peek there).
        dn.compactBottom = AnyView(NoticeNudge(notices: NotchNotices.shared).environment(\.controlActiveState, .active))
        hasCutout = hasNotch
        NotchNotices.shared.context = { [weak self] in self?.noticeContext() ?? NoticeContext() }
        NoticeBridgeListener.shared.start()
        notchWindow = { [weak dn] in dn?.windowController?.window }
        // Along the closed island's edge, drawn by the island itself: the
        // glow when someone's waiting on an app, else the opt-in metric bar.
        if hasNotch {
            let feed = PeekContent.barEnabled ? BarFeed(hub: hub) : nil
            barFeed = feed
            dn.compactEdge = { edge in AnyView(IslandEdge(controller: controller, feed: feed, edge: edge)) }
        }
        NotchNotices.shared.returnNotchKey = { [weak self] in self?.currentWindow()?.giveBackKey() }
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

        // A taller tab (a chat) pushes what hangs under the open notch down.
        controller.$activeModuleID
            .sink { [weak self] id in
                guard let self else { return }
                NotchExpandedRoot.activeContentHeight = NotchExpandedRoot.contentHeight(for: self.controller.module(id))
                NotchNotices.shared.floating?.relayout()
            }
            .store(in: &cancellables)
        controller.focusRequests
            .sink { [weak self] in self?.focusActiveTab() }
            .store(in: &cancellables)
        controller.openRequests
            .sink { [weak self] id in self?.open(tab: id) }
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
        openTrigger = OpenTrigger.current
        startHoverTracking()
        startClickTracking()
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
        ScreenLyrics.shared.detach()
        hasCutout = false
        NotchNotices.shared.setNotch(present: false, open: false)
        NotchNotices.shared.returnNotchKey = nil
        clickMonitors.forEach { NSEvent.removeMonitor($0) }
        clickMonitors = []
        hoverTimer?.invalidate(); hoverTimer = nil
        systemHUD?.stop(); systemHUD = nil
        barFeed?.stop(); barFeed = nil
        peekHub?.stop(); peekHub = nil
        cancellables.removeAll()
        let n = notch
        notch = nil
        notchWindow = { nil }
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
        let region = wantExpanded ? openRegion(screen, margin: CGFloat(SafeZone.current.rawValue)) : closedRegion(screen)
        // The volume/brightness display steps aside when the pointer comes to
        // it. Only on arrival: a pointer already resting there while the keys
        // are pressed still sees it.
        let onHUD = !wantExpanded && pointerOnHUD()
        if onHUD && !pointerWasOnHUD && controller.hud != nil { controller.dismissHUD() }
        pointerWasOnHUD = onHUD
        // A notice on the closed notch takes the pointer first: pointing at it
        // shows its buttons (or opens its peek), not the notch.
        let noticeSpot = wantExpanded ? nil : noticeSpotUnderCursor()
        NotchNotices.shared.pointerOnAttached(noticeSpot)
        let onNotice = noticeSpot != nil
        let mouse = NSEvent.mouseLocation
        let hovering = !onNotice && (region.contains(mouse) || (wantExpanded && onBridgeToFloating(mouse, below: region)))
        // Native source menus extend outside the card. Keep their anchor alive
        // while AppKit tracks a menu/drag, then resume normal hover dismissal.
        let trackingInteraction = wantExpanded && RunLoop.current.currentMode == .eventTracking
        // Game mode: hovering can keep it open, never open it (see `startClickTracking`).
        let hoverOpens = openTrigger == .hover || wantExpanded
        let held = holdOpenUntil.map { Date() < $0 } ?? false
        let want = controller.pinned || controller.heldOpen || trackingInteraction || held || (hoverOpens && hovering)
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
        updateClickThrough(screen, onNotice: onNotice)
    }

    /// Which notice spot on the closed notch the pointer is on, from the frames
    /// the notices report (only the notice showing in a spot counts, so a
    /// frame left by one on its way out can't block it).
    private func noticeSpotUnderCursor() -> NoticePlacement? {
        let notices = NotchNotices.shared
        guard notices.hasAttached, let w = window else { return nil }
        let wf = w.frame
        let mouse = NSEvent.mouseLocation
        return [NoticePlacement.left, .right, .below].first { spot in
            guard let r = notices.attachedRect(spot) else { return false }
            return CGRect(x: wf.minX + r.minX, y: wf.maxY - r.maxY, width: r.width, height: r.height)
                .insetBy(dx: -4, dy: -4).contains(mouse)
        }
    }

    /// The open notch's hover reaches down to a floating notice under it: the
    /// pill itself plus a slim bridge over the gap, the pill's width, so the
    /// pointer can cross to it without the notch closing and the pill moving
    /// away.
    private func onBridgeToFloating(_ mouse: CGPoint, below region: CGRect) -> Bool {
        guard let card = NotchNotices.shared.floating?.cardScreenFrame else { return false }
        let pad: CGFloat = 6
        let bridge = CGRect(x: card.minX - pad, y: card.minY - pad,
                            width: card.width + pad * 2, height: region.minY - card.minY + pad)
        return bridge.contains(mouse)
    }

    /// Whether the pointer is where the HUD shows: both its ears and the
    /// cutout between them, from the frames the ears last reported. Checked
    /// while it's hidden too, so a pointer already there when it appears
    /// doesn't count as arriving.
    private func pointerOnHUD() -> Bool {
        guard let w = window, let left = controller.hudFrames[true], let right = controller.hudFrames[false] else {
            return false
        }
        let r = left.union(right)
        let wf = w.frame
        return CGRect(x: wf.minX + r.minX, y: wf.maxY - r.maxY, width: r.width, height: r.height)
            .insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
    }

    /// What's on the closed notch's ears right now, for Smart placement.
    private func noticeContext() -> NoticeContext {
        var c = NoticeContext()
        c.hudActive = controller.hud != nil
        c.sneakPeek = controller.peekText != nil
        let hasTrack = peekHub?.nowPlaying?.track != nil
        let agent: NoticeContext.Ear = peekHub?.agents.primary.map { $0.status == .needs ? .important : .ambient } ?? .empty
        func ear(_ content: PeekContent, left: Bool) -> NoticeContext.Ear {
            switch content {
            case .off: return .empty
            case .albumArt, .bouncyBars: return hasTrack ? .ambient : .empty
            case .cpuUsage: return .ambient
            case .agentGrid: return agent
            case .smart: return left ? (hasTrack ? .ambient : .empty) : (agent != .empty ? agent : (hasTrack ? .ambient : .empty))
            }
        }
        c.left = ear(PeekContent.left, left: true)
        c.right = ear(PeekContent.right, left: false)
        return c
    }

    /// Game mode's opener: a left click on the collapsed island (⌘ held, for the
    /// `commandClick` trigger). The collapsed window is click-through, so the
    /// click itself goes to whatever is underneath — we only *observe* it, via
    /// a global monitor (mouse events need no permission) plus a local one for
    /// the rare case our own window is live.
    private func startClickTracking() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self, let screen = self.screen,
                  self.closedRegion(screen).contains(NSEvent.mouseLocation) else { return }
            // Hovering already opened it: a click on the notch means "let me
            // type", so the open tab takes the keyboard.
            if self.wantExpanded { self.focusActiveTab(); return }
            guard self.openTrigger != .hover else { self.focusWhenOpen = true; return }
            if self.openTrigger == .commandClick, !event.modifierFlags.contains(.command) { return }
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            self.focusWhenOpen = true
            self.wantExpanded = true
            self.reconcile()
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: handler) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { handler($0); return $0 }) {
            clickMonitors.append(local)
        }
    }

    /// The open tab takes the keyboard: the notch window becomes key (it's a
    /// non-activating panel, so the app in front stays in front), then the
    /// tab focuses its main field. Handed back when the notch closes.
    private func focusActiveTab() {
        guard wantExpanded, let window = currentWindow() else { return }
        if !window.holdsKeyboard { window.makeKey() }
        controller.activeModule?.focus()
    }

    /// Open on a tab without the pointer there (a notice's "Open"), ready to type.
    private func open(tab id: String) {
        controller.select(id)
        NotchNotices.shared.closeList()
        guard !wantExpanded else { focusActiveTab(); return }
        holdOpenUntil = Date().addingTimeInterval(1.2)
        focusWhenOpen = true
        wantExpanded = true
        reconcile()
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
    private func updateClickThrough(_ screen: NSScreen, onNotice: Bool = false) {
        guard let w = currentWindow() else { return }
        if onNotice { w.ignoresMouseEvents = false; return }
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
        guard let cards = cardsScreenFrame(), let screen else { return nil }
        let m: CGFloat = 8
        let minX = cards.minX - m
        let bottom = cards.minY - m
        let top = screen.frame.maxY            // include the tab strip up in the band
        return CGRect(x: minX, y: bottom, width: cards.width + m * 2, height: top - bottom)
    }

    /// The cards' measured frame flipped into screen coordinates, or nil before
    /// the first layout.
    private func cardsScreenFrame() -> CGRect? {
        guard let r = layout.cardsWindowFrame, let w = window else { return nil }
        let wf = w.frame
        return CGRect(x: wf.minX + r.minX, y: wf.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// DynamicNotchKit creates its window lazily on the first expand/compact, and
    /// again after a hide, so we can't cache it at `show()`. Fetch it on demand
    /// and, each time it's a new panel, patch its class so Liquid Glass stays
    /// lively while we're a background app.
    private func currentWindow() -> NSWindow? {
        guard let w = notchWindow() else { return nil }
        if w === window { return w }
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
    /// top), as wide as the open body (from `NotchExpandedRoot`'s constants) and
    /// reaching just below the measured cards. Strictly contains `closedRegion`,
    /// so the hover test can never bounce on a shared edge.
    /// `margin` widens it on the sides and below: the safe zone that keeps
    /// it open through a fast movement past its edge.
    private func openRegion(_ screen: NSScreen, margin: CGFloat = 0) -> CGRect {
        let f = screen.frame
        let n = NotchGeometry.notchFrame(for: screen)
        let w = NotchExpandedRoot.openWidth(for: controller.modules, notchWidth: n.width) + margin * 2
        let bottom = (cardsScreenFrame().map { $0.minY - NotchExpandedRoot.openSlackBelowCards }
            ?? f.maxY - n.height - NotchExpandedRoot.openHeightBelowNotch) - margin
        let h = f.maxY - bottom
        return CGRect(x: f.midX - w / 2, y: bottom, width: w, height: h + topSlop)
    }

    // MARK: reconcile toward desired state

    private func reconcile() {
        ScreenLyrics.shared.setNotchExpanded(wantExpanded)
        NotchNotices.shared.setNotch(present: hasCutout && notch != nil, open: wantExpanded)
        // The bar only shows on the closed island: no reading it while open.
        barFeed?.paused = wantExpanded
        guard !reconciling, let notch, let screen else { return }
        reconciling = true
        Task { @MainActor in
            // `notch` goes nil in `hide()`. Stop there: another expand or compact
            // on a hidden notch would build it a fresh window nobody closes.
            while self.notch != nil {
                let target = wantExpanded
                if target {
                    await notch.expand(on: screen)
                    if focusWhenOpen && wantExpanded {
                        focusWhenOpen = false
                        focusActiveTab()
                    }
                } else {
                    focusWhenOpen = false
                    await notch.compact(on: screen)
                    // Closed: whatever was typed into is gone, so the app in
                    // front gets its keyboard back.
                    if !wantExpanded { currentWindow()?.giveBackKey() }
                }
                if wantExpanded == target { break }
            }
            reconciling = false
        }
    }
}
