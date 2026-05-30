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
    private var mouseMonitor: Any?

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
            window.collectionBehavior = [.transient, .fullScreenNone, .ignoresCycle]
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

    private func refreshOverlays() {
        guard NSApp.isActive else {
            for w in overlayWindows { w.alphaValue = 0 }
            return
        }
        for w in overlayWindows { w.alphaValue = 1 }
        removeOverlays()
        createOverlays()
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
        let options = CGWindowListOption([.excludeDesktopElements, .optionOnScreenOnly])
        guard let info = CGWindowListCopyWindowInfo(options, CGWindowID(0)) as? [[String: Any]] else { return nil }
        let normalWindows = info.filter { ($0["kCGWindowLayer"] as? Int) == 0 }
        guard let front = normalWindows.first else { return nil }
        return front["kCGWindowNumber"] as? Int
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(
            nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                self?.refreshOverlays()
            }
        )

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            self?.refreshOverlays()
        }
    }

    private func stopMonitoring() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }
}
