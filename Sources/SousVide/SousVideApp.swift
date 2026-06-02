import SwiftUI
import AppKit
import Combine
import PanelKit
import SousKit

extension Notification.Name {
    static let openSettings = Notification.Name("sousvide.openSettings")
}

@main
struct SousVideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { EmptyView() }
        .commands { CommandGroup(replacing: .appSettings) { } }
    }
}

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Menu-bar agent that drops a glass panel under its status item. A trimmed
/// cousin of Oxine's AppDelegate — one feature (Sous) so no tab bar, no
/// biometrics, no orbit animation; just show / dismiss / resize.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static weak var instance: AppDelegate?

    private var statusItem: NSStatusItem?
    private var iconView: PounceIconView?
    private var panel: KeyablePanel?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var justOpened = false
    private var isProgrammaticResize = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        PanelKit.configure(.sousVide)
        SousKit.configure(helperBranding: .sousVide)
        CrashReporter.install()

        setupStatusItem()
        setupPanel()
        setupMonitors()
        setupSizeObserver()
        _ = UpdaterManager.shared
        NSApp.setActivationPolicy(.accessory)
        Self.instance = self
        CrashReporter.presentPendingReportIfNeeded()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: 26)
        if let button = statusItem?.button {
            // Custom layer-backed glyph so we can colour the bolt and pounce it.
            button.image = nil
            let icon = PounceIconView(frame: button.bounds)
            icon.autoresizingMask = [.width, .height]
            button.addSubview(icon)
            iconView = icon
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func setupPanel() {
        let initial = PanelLayout.current
        let p = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: initial.width, height: initial.height),
            styleMask: [.borderless, .fullSizeContentView, .resizable],
            backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isMovable = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingController(rootView: SousVideRoot())
        host.sizingOptions = []
        p.contentViewController = host
        p.contentView?.wantsLayer = true
        p.contentView?.layer?.cornerRadius = 20
        p.contentView?.layer?.masksToBounds = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.delegate = self
        panel = p
        applyPanelSize()
    }

    // MARK: Show / hide

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu() } else { toggle() }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open sous-vide", action: #selector(menuOpen), keyEquivalent: "")
        menu.addItem(withTitle: "Settings\u{2026}", action: #selector(menuSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Check for Updates\u{2026}", action: #selector(menuUpdates), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit sous-vide", action: #selector(menuQuit), keyEquivalent: "q")
        menu.items.forEach { if $0.target == nil { $0.target = self } }
        if let button = statusItem?.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
        }
    }

    @objc private func menuOpen() { if panel?.isVisible != true { show() } }
    @objc private func menuSettings() {
        if panel?.isVisible != true { show() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NotificationCenter.default.post(name: .openSettings, object: nil)
        }
    }
    @objc private func menuUpdates() { UpdaterManager.shared.checkForUpdates() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    @objc private func toggle() {
        guard let panel else { return }
        panel.isVisible ? close() : show()
    }

    private func show() {
        guard let button = statusItem?.button, let panel else { return }
        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = button.window?.convertToScreen(buttonRect) ?? .zero
        let size = PanelLayout.current
        let x = screenRect.midX - size.width / 2
        let y = screenRect.minY - size.height - 5
        NSApp.activate(ignoringOtherApps: true)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        iconView?.pounce()
        justOpened = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.justOpened = false }
    }

    private func close() {
        guard panel?.isVisible == true else { return }
        panel?.orderOut(nil)
        iconView?.pounce()
    }

    // MARK: Monitors

    private func setupMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53, self.panel?.isVisible == true { self.close(); return nil }   // esc
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == ",",
               self.panel?.isVisible == true {
                NotificationCenter.default.post(name: .openSettings, object: nil); return nil
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.panel?.isVisible == true, !self.justOpened else { return }
            self.close()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(resignActive),
                                               name: NSApplication.didResignActiveNotification, object: nil)
    }

    @objc private func resignActive() {
        guard panel?.isVisible == true, !justOpened else { return }
        close()
    }

    // MARK: Sizing (mirrors Oxine's eased resize)

    private func setupSizeObserver() {
        NotificationCenter.default.addObserver(self, selector: #selector(sizeChanged),
                                               name: .panelSizeChanged, object: nil)
        if let panel {
            NotificationCenter.default.addObserver(self, selector: #selector(didResize),
                                                   name: NSWindow.didResizeNotification, object: panel)
        }
    }

    @objc private func sizeChanged() { applyPanelSize() }

    @objc private func didResize() {
        guard !isProgrammaticResize, PanelLayout.isResizable, let panel else { return }
        PanelLayout.setCustomSize(panel.frame.size)
    }

    private func applyPanelSize() {
        guard let panel else { return }
        let size = PanelLayout.current
        let lo = PanelLayout.isResizable ? PanelLayout.minSize : size
        let hi = PanelLayout.isResizable ? PanelLayout.maxSize : size
        panel.minSize = lo; panel.maxSize = hi
        panel.contentMinSize = lo; panel.contentMaxSize = hi
        guard panel.isVisible else { return }
        isProgrammaticResize = true
        var frame = panel.frame
        let top = frame.maxY
        frame.size = size
        frame.origin.y = top - size.height
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = PanelLayout.resizeDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.isProgrammaticResize = false }
        }
    }
}

/// The menu-bar glyph: `heart.badge.bolt` with a white heart and an accent-tinted
/// bolt, hosted in its own layer so it can pounce (a quick scale bounce) when the
/// panel opens or closes. Re-tints live when the accent changes. Ignores hit
/// testing so the status button still handles the click.
final class PounceIconView: NSView {
    private let iconLayer = CALayer()
    private var cancellable: AnyCancellable?
    private let dim: CGFloat = 20

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        iconLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        iconLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(iconLayer)
        rebuild()
        cancellable = ThemeManager.shared.$accent.sink { [weak self] _ in self?.rebuild() }
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        iconLayer.bounds = CGRect(x: 0, y: 0, width: dim, height: dim)
        iconLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        iconLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func rebuild() {
        // First palette colour is the bolt badge, second is the heart — so the
        // bolt picks up the accent and the heart stays a soft white.
        let cfg = NSImage.SymbolConfiguration(pointSize: dim, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [
                NSColor(ThemeManager.shared.accent), .white.withAlphaComponent(0.92)]))
        guard let img = NSImage(systemSymbolName: "heart.badge.bolt", accessibilityDescription: "sous-vide")?
            .withSymbolConfiguration(cfg) else { return }
        iconLayer.contents = img
    }

    /// A single playful bounce — overshoot, settle.
    func pounce() {
        let a = CAKeyframeAnimation(keyPath: "transform.scale")
        a.values = [1.0, 1.3, 0.9, 1.08, 1.0]
        a.keyTimes = [0, 0.3, 0.55, 0.8, 1.0]
        a.duration = 0.4
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        iconLayer.add(a, forKey: "pounce")
    }
}
