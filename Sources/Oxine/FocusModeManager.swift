import AppKit
import SwiftUI

@MainActor
class FocusModeManager: ObservableObject {
    static let shared = FocusModeManager()

    @Published var isEnabled = false

    private var overlayWindows: [NSWindow] = []
    private var overlayDisplayIDs: [CGDirectDisplayID] = []
    private var visualEffectViews: [NSVisualEffectView] = []
    private var dimViews: [NSView] = []
    private var observers: [Any] = []
    private var pollTimer: Timer?
    private var lastFrontNumber: Int?
    private var lastFrontDisplay: CGDirectDisplayID?

    var overlayOpacity: CGFloat {
        get { CGFloat(UserDefaults.standard.object(forKey: "focusOverlayOpacity") as? Double ?? 0.3) }
        set {
            UserDefaults.standard.set(Double(newValue), forKey: "focusOverlayOpacity")
            adjustOpacity()
        }
    }

    var blurIntensity: CGFloat {
        get { CGFloat(UserDefaults.standard.object(forKey: "focusBlurIntensity") as? Double ?? 1.0) }
        set {
            UserDefaults.standard.set(Double(newValue), forKey: "focusBlurIntensity")
            adjustBlur()
        }
    }

    var timerRemaining: TimeInterval? { nil }

    private init() {}

    func toggle() {
        if isEnabled { disable() } else { enable() }
    }

    func enable() {
        guard !isEnabled else { return }
        isEnabled = true
        createOverlays()
        startMonitoring()
    }

    func disable() {
        guard isEnabled else { return }
        isEnabled = false
        removeOverlays()
        stopMonitoring()
    }

    func startTimer(duration: TimeInterval) {}
    func cancelTimer() {}

    // MARK: - Overlay management

    private func createOverlays() {
        guard !NSScreen.screens.isEmpty else { return }
        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = true
            // Must persist across Spaces and stay put regardless of which app is
            // active — this is a background dimmer, not a helper panel. `.transient`
            // would hide it when Oxine deactivates, which is exactly when we need it.
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenNone, .ignoresCycle]
            window.level = .normal
            window.title = ""

            let visualEffect = NSVisualEffectView()
            // A dimmer wants a *dark* frosted backdrop. `.fullScreenUI` is an
            // appearance-adaptive vibrancy material — as alpha climbs it lightens
            // bright pixels behind it, which reads as glowing "backlight bleed"
            // blobs. Pinning a dark appearance + the dark `.hudWindow` material
            // darkens the blurred content instead, so raising blur frosts the
            // screen without blooming.
            visualEffect.appearance = NSAppearance(named: .darkAqua)
            visualEffect.material = .hudWindow
            visualEffect.blendingMode = .behindWindow
            visualEffect.state = .active
            visualEffect.alphaValue = blurIntensity

            let dimView = NSView()
            dimView.wantsLayer = true
            dimView.layer?.backgroundColor = NSColor.black.withAlphaComponent(overlayOpacity).cgColor

            let container = NSView()
            container.addSubview(visualEffect)
            container.addSubview(dimView)

            visualEffect.translatesAutoresizingMaskIntoConstraints = false
            dimView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                visualEffect.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                visualEffect.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                visualEffect.topAnchor.constraint(equalTo: container.topAnchor),
                visualEffect.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                dimView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                dimView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                dimView.topAnchor.constraint(equalTo: container.topAnchor),
                dimView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])

            window.contentView = container
            window.orderFront(nil)

            overlayWindows.append(window)
            overlayDisplayIDs.append(displayID(of: screen) ?? 0)
            visualEffectViews.append(visualEffect)
            dimViews.append(dimView)
        }

        // Stack each overlay correctly for its own monitor (see `restack`).
        lastFrontNumber = nil
        lastFrontDisplay = nil
        restack()
    }

    private func removeOverlays() {
        for window in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
        overlayDisplayIDs.removeAll()
        visualEffectViews.removeAll()
        dimViews.removeAll()
    }

    /// Re-stack the existing overlays for the monitor each one lives on, but only
    /// when the frontmost window actually changed. Cheap reorder — no
    /// teardown/rebuild — so the live dim/blur views (and their slider
    /// animations) survive and there's no flicker.
    ///
    /// Per-monitor is the key to dual-display behaviour: ordering an overlay
    /// `.below` a window that lives on *another* display is unreliable when
    /// "Displays have separate Spaces" is on — the overlay can drop behind that
    /// screen's content and never dim it. So the overlay sharing a screen with
    /// the focused window tucks just beneath it (that one window stays lit);
    /// every other monitor floats its overlay to the front and dims fully.
    private func restack() {
        guard !overlayWindows.isEmpty else { return }
        let front = frontmostWindow()
        // Re-stack when focus moves to a different window *or* when the focused
        // window is dragged onto another display (same number, new screen).
        guard front?.number != lastFrontNumber || front?.displayID != lastFrontDisplay else { return }
        lastFrontNumber = front?.number
        lastFrontDisplay = front?.displayID

        for (index, window) in overlayWindows.enumerated() {
            let display = index < overlayDisplayIDs.count ? overlayDisplayIDs[index] : 0
            if let front, front.displayID == display {
                window.order(.below, relativeTo: front.number)
            } else {
                window.orderFront(nil)
            }
        }
    }

    private func adjustBlur() {
        let intensity = blurIntensity
        for view in visualEffectViews {
            view.animator().alphaValue = intensity
        }
    }

    private func adjustOpacity() {
        let alpha = overlayOpacity
        for view in dimViews {
            guard let layer = view.layer else { continue }
            let anim = CABasicAnimation(keyPath: "backgroundColor")
            anim.fromValue = layer.backgroundColor
            anim.toValue = NSColor.black.withAlphaComponent(alpha).cgColor
            anim.duration = 0.2
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(anim, forKey: "backgroundColor")
            layer.backgroundColor = NSColor.black.withAlphaComponent(alpha).cgColor
        }
    }

    private func frontmostWindow() -> (number: Int, displayID: CGDirectDisplayID?)? {
        // Exclude our own process — the overlay windows are also layer-0 and would
        // otherwise be picked as "frontmost", stacking the dimmer against itself.
        let myPID = Int(ProcessInfo.processInfo.processIdentifier)
        let options = CGWindowListOption([.excludeDesktopElements, .optionOnScreenOnly])
        guard let info = CGWindowListCopyWindowInfo(options, CGWindowID(0)) as? [[String: Any]] else { return nil }
        let normalWindows = info.filter {
            ($0["kCGWindowLayer"] as? Int) == 0 && ($0["kCGWindowOwnerPID"] as? Int) != myPID
        }
        guard let front = normalWindows.first,
              let number = front["kCGWindowNumber"] as? Int else { return nil }
        return (number, displayID(forWindow: front))
    }

    /// Which display the front window sits on, so the overlay on that screen can
    /// tuck beneath it while the others dim fully.
    private func displayID(forWindow window: [String: Any]) -> CGDirectDisplayID? {
        guard let boundsDict = window["kCGWindowBounds"] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return nil }
        // CGWindowBounds is in Quartz global coordinates (top-left origin, y down);
        // NSScreen.frame is AppKit (bottom-left origin, y up). Flip the window's
        // centre about the primary display's height before matching.
        let primaryHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.main?.frame.height ?? rect.maxY
        let center = CGPoint(x: rect.midX, y: primaryHeight - rect.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) }
        return screen.flatMap { displayID(of: $0) }
    }

    private func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(
            nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restack() }
            }
        )

        // The activation notification can arrive a beat after the new window is
        // already on screen — long enough to flash the previous, un-dimmed app
        // during Cmd-Tab / Dock switches. Poll the frontmost window frequently and
        // re-stack only on change to close that gap. Runs in `.common` mode so it
        // keeps firing during scroll/resize tracking.
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.restack() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopMonitoring() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
        lastFrontNumber = nil
        lastFrontDisplay = nil
    }
}
