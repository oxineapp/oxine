import SwiftUI
import PanelKit
import AppKit
import Combine

func log(_ msg: String) {
    try? FileHandle.standardError.write(contentsOf: Data((msg + "\n").utf8))
}

extension Notification.Name {
    static let popoverWillClose = Notification.Name("popoverWillClose")
    static let popoverDidShow = Notification.Name("popoverDidShow")
    static let biometricWillBegin = Notification.Name("biometricWillBegin")
    static let biometricDidEnd = Notification.Name("biometricDidEnd")
    static let authTabActivated = Notification.Name("authTabActivated")
    static let clipboardCaptured = Notification.Name("clipboardCaptured")
    static let openSettings = Notification.Name("openSettings")
    static let openTab = Notification.Name("openTab")
}

@main
struct Oxine: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        // SwiftUI's Settings scene auto-adds a "Settings…" menu item bound to ⌘,
        // that opens this empty window — and that menu shortcut shadows our own
        // ⌘, handler. Remove the item so ⌘, reaches us and opens the panel's
        // Settings tab instead of a blank window.
        .commands {
            CommandGroup(replacing: .appSettings) { }
        }
    }
}

class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static weak var instance: AppDelegate?

    var statusItem: NSStatusItem?
    var orbitView: OrbitStatusView?
    var panel: KeyablePanel?
    var monitor: Any?
    var globalMonitor: Any?
    var resignObserver: Any?
    @Published var isPinned: Bool = false
    var isAuthenticating = false
    var panelJustOpened = false
    var panelJustOpenedTimer: DispatchWorkItem?
    var authWatchdog: DispatchWorkItem?
    var closeReason = ""
    var isAuthVisible = false
    var isProgrammaticResize = false
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Tell the shared chrome who it is (settings suite + display name) before
        // anything touches the theme, size store, crash reporter, or updater.
        PanelKit.configure(.oxine)
        // Install crash capture before anything else can fault, so a crash during
        // startup is still recorded for the next-launch report.
        CrashReporter.install()
        // Carry settings/clipboard/setup state from the legacy com.menubar.*
        // domains to com.oxine.* (must run before anything reads a setting), then
        // rename the legacy "MenuBar Notes" folder to the new default. Both are
        // one-time no-ops once migrated.
        StorageMigration.runIfNeeded()
        ScriptsMigration.runIfNeeded()
        NotesLocation.migrateLegacyIfNeeded()
        setupMenuBar()
        setupEventMonitoring()
        setupBiometricObservers()
        setupSizeObserver()
        // Start Sparkle (background update checks on its own schedule). The
        // singleton must be touched once so it stays alive for the app's life.
        _ = UpdaterManager.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        Self.instance = self
        observeSous()
        // If we crashed last run, offer to send the captured report.
        CrashReporter.presentPendingReportIfNeeded()
    }

    /// Tint the menu-bar bead from the live Sous charge state.
    private func observeSous() {
        SousManager.shared.$menuTint
            .receive(on: RunLoop.main)
            .sink { [weak self] tint in
                let color: NSColor?
                switch tint {
                case .none:    color = nil
                case .holding: color = .systemGreen
                case .working: color = .systemOrange
                }
                self?.orbitView?.setSousTint(color)
            }
            .store(in: &cancellables)
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: 28)

        if let button = statusItem?.button {
            // The animated orbit mark, hosted as a layer-backed subview. It
            // ignores hit-testing so the button still handles the click.
            button.image = nil
            button.title = ""
            let orbit = OrbitStatusView(frame: button.bounds)
            orbit.autoresizingMask = [.width, .height]
            button.addSubview(orbit)
            orbitView = orbit
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

            // A genuine external copy → the bead does a quick spin.
            NotificationCenter.default.addObserver(
                self, selector: #selector(clipboardCaptured),
                name: .clipboardCaptured, object: nil)
        }

        let initial = PanelLayout.current
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: initial.width, height: initial.height),
            styleMask: [.borderless, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel?.isOpaque = false
        panel?.backgroundColor = .clear
        panel?.hasShadow = true
        panel?.level = .floating
        panel?.isMovable = false
        panel?.isMovableByWindowBackground = false
        panel?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel?.title = ""
        let hostingController = NSHostingController(rootView: MainView(appDelegate: self))
        hostingController.sizingOptions = []
        panel?.contentViewController = hostingController
        panel?.contentView?.wantsLayer = true
        panel?.contentView?.layer?.cornerRadius = 20
        panel?.contentView?.layer?.masksToBounds = true
        panel?.isReleasedWhenClosed = false
        panel?.hidesOnDeactivate = false
        panel?.delegate = self
        applyPanelSize()
    }

    /// Authoritative resize clamp. AppKit's minSize/maxSize aren't honored for
    /// this borderless, hosting-controller-backed panel, so we enforce bounds
    /// here on every live-resize tick — and refuse resizes entirely when locked.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        if isProgrammaticResize { return frameSize }
        guard PanelLayout.isResizable else { return sender.frame.size }
        let lo = PanelLayout.minSize
        let hi = PanelLayout.maxSize
        return NSSize(
            width: min(max(frameSize.width, lo.width), hi.width),
            height: min(max(frameSize.height, lo.height), hi.height)
        )
    }

    private func setupSizeObserver() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSizeChanged),
            name: .panelSizeChanged, object: nil
        )
        if let panel {
            NotificationCenter.default.addObserver(
                self, selector: #selector(panelDidResize(_:)),
                name: NSWindow.didResizeNotification, object: panel
            )
        }
    }

    @objc private func handleSizeChanged() { applyPanelSize() }

    /// Apply min/max constraints for the current preset and, if visible, resize
    /// in place keeping the top edge pinned under the menubar.
    func applyPanelSize() {
        guard let panel else { return }
        let size = PanelLayout.current
        // Use frame-based min/max — AppKit honors these during live resize even
        // for a borderless panel; contentMinSize gets reset by the host controller.
        let lo = PanelLayout.isResizable ? PanelLayout.minSize : size
        let hi = PanelLayout.isResizable ? PanelLayout.maxSize : size
        panel.minSize = lo
        panel.maxSize = hi
        panel.contentMinSize = lo
        panel.contentMaxSize = hi
        guard panel.isVisible else { return }
        isProgrammaticResize = true
        var frame = panel.frame
        let top = frame.maxY
        frame.size = size
        frame.origin.y = top - size.height
        // Eased, fixed-duration resize that matches the SwiftUI content's
        // animation (PanelLayout.resizeDuration) so they move together
        // instead of the AppKit default fighting the content's snap.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = PanelLayout.resizeDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.isProgrammaticResize = false }
        }
    }

    /// Persist user drag-resizes when the Custom preset is active.
    @objc private func panelDidResize(_ n: Notification) {
        guard !isProgrammaticResize, PanelLayout.isResizable, let panel else { return }
        PanelLayout.setCustomSize(panel.frame.size)
    }

    private func setupEventMonitoring() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                if self.panel?.isVisible == true {
                    self.closeReason = "escape"
                    self.closePanel()
                    return nil
                }
            }
            if event.modifierFlags.contains(.command) && event.modifierFlags.contains(.shift) && event.characters == "v" {
                self.togglePanel()
                return nil
            }
            // ⌘, opens Settings — the standard macOS preferences shortcut.
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "," {
                if self.panel?.isVisible == true {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                    return nil
                }
            }
            return event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.panel?.isVisible == true, !self.isPinned, !self.isAuthenticating, !self.panelJustOpened else { return }
            log("globalMonitor -> closePanel (pinned=\(self.isPinned) auth=\(self.isAuthenticating) justOpened=\(self.panelJustOpened))")
            self.closeReason = "globalMonitor"
            self.closePanel()
        }

        resignObserver = NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidResignActive(_:)),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func appDidResignActive(_ n: Notification) {
        log("resignActive panelVisible=\(panel?.isVisible ?? false) pinned=\(isPinned) auth=\(isAuthenticating) justOpened=\(panelJustOpened)")
        guard panel?.isVisible == true, !isPinned, !isAuthenticating, !panelJustOpened else { return }
        log("resignActive -> closePanel")
        closeReason = "resignActive"
        closePanel()
    }

    @objc private func appDidBecomeActive(_ n: Notification) {
        log("didBecomeActive")
    }

    private func setupBiometricObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(biometricWillBegin),
            name: .biometricWillBegin,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(biometricDidEnd),
            name: .biometricDidEnd,
            object: nil
        )
    }

    @objc private func biometricWillBegin() {
        log("biometricWillBegin")
        isAuthenticating = true
        // Failsafe: if biometricDidEnd is ever missed (e.g. the panel is hidden
        // mid-prompt), never leave isAuthenticating stuck true — that wedged the
        // Auth tab (couldn't switch tabs, and unlock() refused to re-prompt). A
        // real prompt resolves in seconds; force-clear after a generous timeout.
        authWatchdog?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.isAuthenticating else { return }
            log("biometric watchdog -> clearing stuck isAuthenticating")
            self.isAuthenticating = false
        }
        authWatchdog = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: w)
    }

    @objc private func biometricDidEnd() {
        log("biometricDidEnd")
        authWatchdog?.cancel()
        // ALWAYS clear the auth flag (previously skipped when the panel wasn't
        // visible, which is what stuck the Auth tab). Short delay so the click
        // that dismisses the system sheet doesn't immediately close the panel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            log("biometricDidEnd reset")
            self?.isAuthenticating = false
        }
        // The panelJustOpened debounce only matters while the panel is open.
        guard panel?.isVisible == true else { return }
        panelJustOpened = true
        panelJustOpenedTimer?.cancel()
        let t = DispatchWorkItem { [weak self] in
            log("postAuth panelJustOpened reset")
            self?.panelJustOpened = false
        }
        panelJustOpenedTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: t)
    }

    @objc private func clipboardCaptured() { orbitView?.playCopy() }

    /// Left-click toggles the panel; right-click pops a small menu.
    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
        } else {
            togglePanel()
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Oxine", action: #selector(menuOpen), keyEquivalent: "")

        // Every tab is reachable here, whether or not it's on the bar — so a
        // hidden tab is never stranded.
        let tabsItem = NSMenuItem(title: "Open Tab", action: nil, keyEquivalent: "")
        let tabsMenu = NSMenu()
        for tab in TabID.canonical {
            let item = NSMenuItem(title: tab.title, action: #selector(menuOpenTab(_:)), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: tab.icon, accessibilityDescription: nil)
            item.representedObject = tab.rawValue
            item.target = self
            tabsMenu.addItem(item)
        }
        tabsItem.submenu = tabsMenu
        menu.addItem(tabsItem)

        menu.addItem(withTitle: "Settings\u{2026}", action: #selector(menuSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Check for Updates\u{2026}", action: #selector(menuCheckUpdates), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Oxine", action: #selector(menuQuit), keyEquivalent: "q")
        menu.items.forEach { if $0.target == nil { $0.target = self } }
        if let button = statusItem?.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
        }
    }

    @objc private func menuOpen() { if panel?.isVisible != true { showPanel() } }
    @objc private func menuOpenTab(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        if panel?.isVisible != true { showPanel() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NotificationCenter.default.post(name: .openTab, object: raw)
        }
    }
    @objc private func menuSettings() { openSettings() }
    @objc private func menuCheckUpdates() { UpdaterManager.shared.checkForUpdates() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    /// Show the panel (if needed) and switch it to the Settings pane. Bound to
    /// ⌘, and the right-click menu — the standard macOS "preferences" gesture.
    func openSettings() {
        if panel?.isVisible != true { showPanel() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NotificationCenter.default.post(name: .openSettings, object: nil)
        }
    }

    @objc func togglePanel() {
        guard let panel else { return }
        log("togglePanel isVisible=\(panel.isVisible) pinned=\(isPinned)")
        if panel.isVisible {
            closeReason = "togglePanel"
            closePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem?.button, let panel else { return }
        log("showPanel")

        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = button.window?.convertToScreen(buttonRect) ?? .zero

        let size = PanelLayout.current
        let panelWidth: CGFloat = size.width
        let panelHeight: CGFloat = size.height
        let x = screenRect.midX - panelWidth / 2
        let y = screenRect.minY - panelHeight - 5

        NSApp.activate(ignoringOtherApps: true)
        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
        panel.makeKeyAndOrderFront(nil)
        orbitView?.setPanelOpen(true)

        panelJustOpened = true
        panelJustOpenedTimer?.cancel()
        let t = DispatchWorkItem { [weak self] in self?.panelJustOpened = false }
        panelJustOpenedTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: t)

        NotificationCenter.default.post(name: .popoverDidShow, object: nil)
    }

    private func closePanel() {
        log("closePanel reason=\(closeReason) stack=\(Thread.callStackSymbols.prefix(6).joined(separator: " | "))")
        closeReason = ""
        panelJustOpenedTimer?.cancel()
        panelJustOpened = false
        NotificationCenter.default.post(name: .popoverWillClose, object: nil)
        panel?.orderOut(nil as Any?)
        orbitView?.setPanelOpen(false)
    }

    func setPinned(_ pinned: Bool) {
        isPinned = pinned
    }
}
