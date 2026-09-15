import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore

/// fn + trackpad gestures, the small way: hold fn and scroll vertically for a
/// continuous volume/brightness ramp, or flick horizontally to skip tracks.
///
/// One session-level CGEvent tap, three event types, no private frameworks.
/// The scroll events themselves carry the fn flag, so there's no modifier state
/// machine to drift out of sync — the tap just asks each scroll "is fn down?".
/// Actions are posted as ordinary system-defined key events (the same ones the
/// keyboard's volume/brightness/media keys send), from a background queue so a
/// posted event can never re-enter the tap that's still handling the trigger.
///
/// Needs Accessibility (to create a modifying tap and to post events); the
/// engine polls for the grant and comes up by itself once it's given.
@MainActor
final class FnGestureEngine {
    struct Config: Equatable {
        enum Vertical: String, CaseIterable {
            case volume, brightness, off
            var label: String {
                switch self {
                case .volume: "Volume"
                case .brightness: "Brightness"
                case .off: "Off"
                }
            }
        }
        enum Horizontal: String, CaseIterable {
            case track, off
            var label: String { self == .track ? "Next & previous track" : "Off" }
        }
        var enabled = true
        var vertical: Vertical = .volume
        var horizontal: Horizontal = .track
        /// 0.5 (needs a long swipe) … 2 (twitchy).
        var sensitivity = 1.0
        /// Keep the page from scrolling under a fn-scroll.
        var swallowScroll = true
        /// Flip the vertical direction (natural-scroll taste varies).
        var invert = false
    }

    enum Status: Equatable {
        case needsAccessibility, disabled, ready
        var label: String {
            switch self {
            case .needsAccessibility: "Needs Accessibility permission"
            case .disabled: "Gestures off"
            case .ready: "Ready — hold fn and scroll"
            }
        }
    }

    var config = Config() {
        didSet { if config != oldValue { reconfigure() } }
    }
    private(set) var status: Status = .disabled {
        didSet { if status != oldValue { onStatusChanged?(status) } }
    }
    var onStatusChanged: ((Status) -> Void)?
    /// Fired after a horizontal flick — "Next track" / "Previous track".
    var onSkip: ((String) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var permissionTimer: Timer?
    private var started = false

    // Gesture state (main thread only — the tap's run-loop source is on main).
    private var fnHeld = false
    private var gestureActive = false
    private var vertAccum = 0.0
    private var horizAccum = 0.0
    private var horizFired = false
    private var lastScrollAt: TimeInterval = 0

    private let actions = DispatchQueue(label: "com.oxine.fngestures.actions", qos: .userInteractive)

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        reconfigure()
        // Re-check the grant: the tap comes up by itself once Accessibility is on.
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.started else { return }
                if self.tap == nil, self.config.enabled, Self.accessibilityGranted { self.reconfigure() }
                else if let tap = self.tap, !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        permissionTimer = t
    }

    func stop() {
        started = false
        permissionTimer?.invalidate(); permissionTimer = nil
        removeTap()
        status = .disabled
    }

    /// Ask macOS for Accessibility (shows the system prompt the first time,
    /// otherwise opens the pane).
    static func requestAccessibility() {
        // The literal key string sidesteps the non-Sendable global constant.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func reconfigure() {
        removeTap()
        guard started, config.enabled else { status = .disabled; return }
        guard Self.accessibilityGranted else { status = .needsAccessibility; return }
        installTap()
        status = tap == nil ? .needsAccessibility : .ready
    }

    private func removeTap() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        source = nil; tap = nil
        resetGesture()
        fnHeld = false
    }

    private func installTap() {
        let types: [CGEventType] = [.flagsChanged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let engine = Unmanaged<FnGestureEngine>.fromOpaque(userInfo).takeUnretainedValue()
            // The tap's source lives on the main run loop, so this is the main thread.
            let consume = MainActor.assumeIsolated { engine.handle(type: type, event: event) }
            return consume ? nil : Unmanaged.passUnretained(event)
        }
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback, userInfo: info),
              let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { return }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // MARK: - Events

    /// Returns true to swallow the event.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            resetGesture()
            return false
        case .flagsChanged:
            // Keycode 63 is fn/Globe; other modifiers may or may not carry the
            // fn bit, so only the fn transition itself updates the tracked state.
            if event.getIntegerValueField(.keyboardEventKeycode) == 63 {
                fnHeld = event.flags.contains(.maskSecondaryFn)
                if !fnHeld, !gestureActive { resetGesture() }
            }
            return false
        case .scrollWheel:
            return handleScroll(event)
        default:
            return false
        }
    }

    private func handleScroll(_ event: CGEvent) -> Bool {
        let fnDown = fnHeld || event.flags.contains(.maskSecondaryFn)
        // NSEvent.Phase raw values: began 1, changed 4, ended 8, cancelled 16, mayBegin 32.
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        let now = CACurrentMediaTime()

        // A trackpad gesture is decided at its start and then owned to the end
        // (momentum included), so releasing fn mid-flick can't dump the leftover
        // scroll into the page. Wheels (no phases) are judged per event.
        if phase == 1 || phase == 32 {
            resetGesture()
            gestureActive = fnDown
        } else if phase == 0 && momentum == 0 {
            if now - lastScrollAt > 0.3 { resetGesture() }
            gestureActive = fnDown
        }
        lastScrollAt = now
        guard gestureActive else { return false }
        // Momentum after the fingers lift: keep swallowing, never act on it.
        if momentum == 8 || momentum == 16 { gestureActive = false }
        guard momentum == 0 else { return config.swallowScroll }
        // Fingers lifted: arm the next flick; momentum (if any) follows.
        if phase == 8 || phase == 16 {
            horizFired = false; horizAccum = 0; vertAccum = 0
            return config.swallowScroll
        }

        var dx = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        var dy = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        if dx == 0 && dy == 0 {
            dx = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)) * 10
            dy = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) * 10
        }
        let sens = max(0.25, config.sensitivity)

        if abs(dy) >= abs(dx) {
            guard config.vertical != .off else { return config.swallowScroll }
            // Natural scrolling is already folded into the point delta's sign;
            // `invert` is the user's taste on top of that.
            let step = 22.0 / sens
            vertAccum += config.invert ? -dy : dy
            var steps = Int(vertAccum / step)
            if steps != 0 {
                vertAccum -= Double(steps) * step
                steps = max(-2, min(2, steps))
                let up = steps > 0
                let key: Int32 = config.vertical == .volume ? (up ? 0 : 1) : (up ? 2 : 3)
                for _ in 0..<abs(steps) { postSystemKey(key) }
            }
        } else {
            guard config.horizontal != .off, !horizFired else { return config.swallowScroll }
            horizAccum += dx
            if abs(horizAccum) >= 44 / sens {
                horizFired = true
                let forward = horizAccum > 0
                postSystemKey(forward ? 17 : 18)      // next / previous
                onSkip?(forward ? "Next track" : "Previous track")
            }
        }
        return config.swallowScroll
    }

    private func resetGesture() {
        gestureActive = false
        vertAccum = 0; horizAccum = 0
        horizFired = false
    }

    // MARK: - Actions

    /// Post a system-defined key (NX_KEYTYPE_*): the keyboard's own volume /
    /// brightness / media keys, so macOS handles the change and its HUD.
    private func postSystemKey(_ key: Int32) {
        actions.async {
            func post(_ down: Bool) {
                let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
                let data1 = Int(key) << 16 | ((down ? 0xA : 0xB) << 8)
                NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                   context: nil, subtype: 8, data1: data1, data2: -1)?
                    .cgEvent?.post(tap: .cghidEventTap)
            }
            post(true)
            post(false)
        }
    }
}
