import AppKit
import SwiftUI

@MainActor
class FocusModeManager: ObservableObject {
    static let shared = FocusModeManager()

    @Published var isEnabled = false

    private var overlayWindows: [NSWindow] = []
    private var visualEffectViews: [NSVisualEffectView] = []
    private var dimViews: [NSView] = []
    private var observers: [Any] = []
    private var pollTimer: Timer?
    private var lastFrontNumber: Int?

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
        let frontNumber = frontmostWindowNumber()
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
            visualEffect.material = .fullScreenUI
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

            if let windowNumber = frontNumber {
                window.order(.below, relativeTo: windowNumber)
            } else {
                window.orderFront(nil)
            }

            overlayWindows.append(window)
            visualEffectViews.append(visualEffect)
            dimViews.append(dimView)
        }
    }

    private func removeOverlays() {
        for window in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
        visualEffectViews.removeAll()
        dimViews.removeAll()
    }

    /// Re-stack the existing overlays just beneath whatever window is now
    /// frontmost, but only when that window actually changed. Cheap reorder — no
    /// teardown/rebuild — so the live dim/blur views (and their slider
    /// animations) survive, there's no flicker, and we never thrash the z-order
    /// when focus hasn't moved. The overlays stay visible no matter which app is
    /// active.
    private func refreshOverlays() {
        guard !overlayWindows.isEmpty else { return }
        let frontNumber = frontmostWindowNumber()
        guard frontNumber != lastFrontNumber else { return }
        lastFrontNumber = frontNumber
        guard let frontNumber else {
            for window in overlayWindows { window.orderFront(nil) }
            return
        }
        for window in overlayWindows {
            window.order(.below, relativeTo: frontNumber)
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

    private func frontmostWindowNumber() -> Int? {
        // Exclude our own process — the overlay windows are also layer-0 and would
        // otherwise be picked as "frontmost", stacking the dimmer against itself.
        let myPID = Int(ProcessInfo.processInfo.processIdentifier)
        let options = CGWindowListOption([.excludeDesktopElements, .optionOnScreenOnly])
        guard let info = CGWindowListCopyWindowInfo(options, CGWindowID(0)) as? [[String: Any]] else { return nil }
        let normalWindows = info.filter {
            ($0["kCGWindowLayer"] as? Int) == 0 && ($0["kCGWindowOwnerPID"] as? Int) != myPID
        }
        guard let front = normalWindows.first else { return nil }
        return front["kCGWindowNumber"] as? Int
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(
            nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshOverlays() }
            }
        )

        // The activation notification can arrive a beat after the new window is
        // already on screen — long enough to flash the previous, un-dimmed app
        // during Cmd-Tab / Dock switches. Poll the frontmost window frequently and
        // re-stack only on change to close that gap. Runs in `.common` mode so it
        // keeps firing during scroll/resize tracking.
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshOverlays() }
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
    }
}
