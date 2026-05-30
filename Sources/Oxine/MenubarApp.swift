import SwiftUI
import AppKit

func log(_ msg: String) {
    try? FileHandle.standardError.write(contentsOf: Data((msg + "\n").utf8))
}

extension Notification.Name {
    static let popoverWillClose = Notification.Name("popoverWillClose")
    static let popoverDidShow = Notification.Name("popoverDidShow")
    static let biometricWillBegin = Notification.Name("biometricWillBegin")
    static let biometricDidEnd = Notification.Name("biometricDidEnd")
    static let authTabActivated = Notification.Name("authTabActivated")
}

@main
struct Oxine: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var instance: AppDelegate?

    var statusItem: NSStatusItem?
    var panel: KeyablePanel?
    var monitor: Any?
    var globalMonitor: Any?
    var resignObserver: Any?
    @Published var isPinned: Bool = false
    var isAuthenticating = false
    var panelJustOpened = false
    var panelJustOpenedTimer: DispatchWorkItem?
    var closeReason = ""
    var isAuthVisible = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupEventMonitoring()
        setupBiometricObservers()
        NSApplication.shared.setActivationPolicy(.accessory)
        Self.instance = self
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "Clipboard")
            button.image?.size = NSSize(width: 16, height: 16)
            button.action = #selector(togglePanel)
            button.target = self
        }

        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 470),
            styleMask: [.borderless, .fullSizeContentView],
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
        panel?.contentView?.layer?.cornerRadius = 18
        panel?.contentView?.layer?.masksToBounds = true
        panel?.isReleasedWhenClosed = false
        panel?.hidesOnDeactivate = false
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
    }

    @objc private func biometricDidEnd() {
        log("biometricDidEnd")
        guard panel?.isVisible == true else { return }
        panelJustOpened = true
        panelJustOpenedTimer?.cancel()
        let t = DispatchWorkItem { [weak self] in
            log("postAuth panelJustOpened reset")
            self?.panelJustOpened = false
        }
        panelJustOpenedTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: t)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            log("biometricDidEnd reset")
            self.isAuthenticating = false
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

        let panelWidth: CGFloat = 360
        let panelHeight: CGFloat = 470
        let x = screenRect.midX - panelWidth / 2
        let y = screenRect.minY - panelHeight - 5

        NSApp.activate(ignoringOtherApps: true)
        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
        panel.makeKeyAndOrderFront(nil)

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
    }

    func setPinned(_ pinned: Bool) {
        isPinned = pinned
    }
}
