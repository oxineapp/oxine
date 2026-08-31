import AppKit
import ApplicationServices
import CoreGraphics

// These module-private globals retain the upstream menu's small callbacks.
var configManager: ConfigManager!
var engine: GestureEngine!
var multitouchRef: Multitouch?
var menuController: MenuController!

func appLog(_ message: String) { NSLog("[Oxine Gestures] %@", message) }
func openPane(_ pane: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
}
func rebuildMenu() { GestureService.shared.refreshMenu() }

/// Embeds FnGestures into Oxine with one event tap and one shared touch reader.
/// Call its lifecycle/menu methods on the main thread.
public final class GestureService {
    public static let shared = GestureService()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var watchdog: Timer?
    private var modifierTimer: Timer?
    private var activeTap = false
    private var started = false
    private var permissionState = ""
    private var middleClickCount = 0

    private init() {}

    public func start() {
        guard !started else { return }
        started = true
        let base = FileManager.default.homeDirectoryForCurrentUser
        let url = base.appendingPathComponent("Library/Application Support/Oxine/Gestures/config.json")
        // Copy, never change, the standalone FnGestures configuration.
        let legacy = base.appendingPathComponent(".config/fngestures/config.json")
        if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: legacy, to: url)
        }
        configManager = ConfigManager(url: url)
        engine = GestureEngine(fnState: FnState(), configManager: configManager, debug: false)
        menuController = MenuController(configManager: configManager, onReload: { [weak self] in self?.configure() })
        engine.onFnChanged = { held in menuController?.updateFnIndicator(held: held) }
        engine.onMiddleClick = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.middleClickCount += 1
                appLog("middle-click tap recognized (\(self.middleClickCount))")
                self.updateTouchIndicator()
            }
        }
        Multitouch.setFrameHandler { device, touches in engine.mtFrame(device: device, touches: touches) }
        configure()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let state = "\(CGPreflightListenEventAccess())-\(AXIsProcessTrusted())"
            if state != self.permissionState || (self.tap == nil && CGPreflightListenEventAccess() && configManager.current.enabled) {
                self.configure()
            } else if let tap = self.tap, !CGEvent.tapIsEnabled(tap: tap) {
                engine.resetInputState()
                self.synchronizeFn()
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        watchdog = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    public func stop() {
        watchdog?.invalidate(); watchdog = nil
        removeTap()
        multitouchRef?.disable()
    }

    public func menu() -> NSMenu { start(); refreshMenu(); return menuController.menu }

    public func showMenu() { menu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }

    public func requestPermissions() {
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        configure()
    }

    func refreshMenu() {
        guard started else { return }
        let status: String
        if !configManager.current.enabled { status = "Gestures disabled" }
        else if tap == nil { status = "Grant Input Monitoring to Oxine Beta" }
        else if !activeTap { status = "Grant Accessibility for middle click & click remapping" }
        else if multitouchRef == nil || multitouchRef?.deviceCount == 0 { status = "Event tap active · no touch device connected" }
        else { status = "Gestures & middle click ready" }
        menuController.build(tapStatus: status)
        updateTouchIndicator()
    }

    private func removeTap() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        source = nil; tap = nil; activeTap = false
        modifierTimer?.invalidate(); modifierTimer = nil
        engine?.resetInputState()
    }

    private func configure() {
        removeTap()
        permissionState = "\(CGPreflightListenEventAccess())-\(AXIsProcessTrusted())"
        let cfg = configManager.current
        let captureTouch = cfg.enabled && (cfg.multitouch || cfg.middleClick) && CGPreflightListenEventAccess()
        if captureTouch {
            if multitouchRef == nil { multitouchRef = Multitouch() }
            multitouchRef?.setActive(true)
        } else { multitouchRef?.disable() }
        guard cfg.enabled, CGPreflightListenEventAccess() else {
            appLog("input status: enabled=\(cfg.enabled) monitoring=\(CGPreflightListenEventAccess()) accessibility=\(AXIsProcessTrusted())")
            refreshMenu(); return
        }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .scrollWheel,
                                    .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        activeTap = AXIsProcessTrusted()
        let callback: CGEventTapCallBack = { _, type, event, _ in
            let service = GestureService.shared
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                engine.resetInputState()
                service.synchronizeFn()
                if let tap = service.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            // Click remapping needs an active tap even when scroll swallowing is off.
            let scroll = type == .scrollWheel
            let consume = service.activeTap && (!scroll || configManager.current.swallowScroll)
            let handled = engine.handle(type: type, event: event, swallow: consume, physicalFlags: service.physicalModifiers())
            return consume && handled ? nil : Unmanaged.passUnretained(event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                options: activeTap ? .defaultTap : .listenOnly,
                                eventsOfInterest: mask, callback: callback, userInfo: nil)
        if let tap, let source = CFMachPortCreateRunLoopSource(nil, tap, 0) {
            self.source = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            synchronizeFn()
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.synchronizeFn() }
            modifierTimer = timer
            // Keep tracking even while a menu is open or a slider is being dragged.
            RunLoop.main.add(timer, forMode: .common)
        }
        appLog("input status: monitoring=\(CGPreflightListenEventAccess()) accessibility=\(AXIsProcessTrusted()) tap=\(tap != nil)")
        refreshMenu()
    }

    private func physicalModifiers() -> CGEventFlags {
        var flags = CGEventSource.flagsState(.hidSystemState)
        if CGEventSource.keyState(.hidSystemState, key: 63) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    private func synchronizeFn() {
        engine?.synchronizeModifiers(flags: physicalModifiers())
        menuController?.updateFnIndicator(held: engine?.fnState.held ?? false)
        updateTouchIndicator()
    }

    private func updateTouchIndicator() {
        menuController?.updateTouchIndicator(status: multitouchRef?.statusText ?? "Trackpad: unavailable",
                                            clicks: middleClickCount)
    }
}
