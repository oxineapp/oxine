import AppKit
import MetalKit

/// Sear: the display past its sliders. The built-in XDR panel tops out at about
/// 500 nits for ordinary content and keeps the rest (1000 sustained, 1600 peak)
/// for HDR video. Two facts get at it for everything:
///
///   * macOS only opens that headroom while something on screen asks for it, so
///     each display gets an overlay whose layer carries extended-range content.
///   * The overlay is composited with a multiply filter, so whatever is under it
///     is scaled by the overlay's value: 1 is a no-op, 2 doubles the light, 0.4
///     is a display dimmer than the brightness keys go.
///
/// One mechanism, both directions. The overlay ignores the mouse, stays out of
/// screenshots and recordings (they'd come out washed or dark otherwise), and
/// holds a 1×1 texture — the cost is a composited layer, not a full-screen
/// float framebuffer. Nothing persists: no gamma table is touched, and a
/// process that dies takes its overlays with it.
@MainActor
final class SearEngine {
    /// 1 = untouched. Above 1 boosts (XDR displays only), below 1 dims.
    var factor: Double = 1 { didSet { if factor != oldValue { sync() } } }
    /// What each display actually got, after clamping to its headroom.
    private(set) var applied: [CGDirectDisplayID: Double] = [:]
    var onChange: (() -> Void)?

    private var overlays: [CGDirectDisplayID: Overlay] = [:]
    private var observer: NSObjectProtocol?

    /// Boost is capped here even when the panel reports more: past ~2× the
    /// panel is in peak-HDR territory it can't hold full-screen, and macOS
    /// starts pulling brightness back on its own.
    static let boostCeiling = 2.0
    static let dimFloor = 0.15

    static var hasXDR: Bool {
        NSScreen.screens.contains { $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.5 }
    }

    func start() {
        guard observer == nil else { return }
        // Fires for display changes and whenever the available headroom moves
        // (the brightness keys change how much room is left above SDR white).
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.sync() } }
        sync()
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        overlays.values.forEach { $0.close() }
        overlays = [:]
        applied = [:]
    }

    private func sync() {
        guard observer != nil else { return }
        var seen: Set<CGDirectDisplayID> = []
        var next: [CGDirectDisplayID: Double] = [:]
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            let xdr = screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.5
            var f = min(max(factor, Self.dimFloor), Self.boostCeiling)
            if f > 1, !xdr { f = 1 }                       // nothing to unlock on this one
            guard abs(f - 1) > 0.001 else { continue }
            seen.insert(id)
            let overlay = overlays[id] ?? Overlay(screen: screen)
            overlays[id] = overlay
            overlay.place(on: screen)
            overlay.set(factor: f)
            next[id] = f
        }
        for (id, overlay) in overlays where !seen.contains(id) { overlay.close(); overlays[id] = nil }
        if next != applied { applied = next; onChange?() }
    }
}

/// One display's overlay window.
@MainActor
private final class Overlay {
    private let window: NSWindow
    private let view: SearMetalView

    init(screen: NSScreen) {
        view = SearMetalView(frame: CGRect(origin: .zero, size: screen.frame.size))
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.sharingType = .none
        window.animationBehavior = .none
        window.contentView = view
        view.layer?.compositingFilter = "multiply"
    }

    func place(on screen: NSScreen) {
        if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
        if !window.isVisible { window.orderFrontRegardless() }
    }

    func set(factor: Double) { view.factor = factor }
    func close() { window.orderOut(nil); window.close() }
}

/// A 1×1 extended-range texture stretched over the screen.
private final class SearMetalView: MTKView, MTKViewDelegate {
    private var queue: MTLCommandQueue?
    var factor: Double = 1 {
        didSet {
            clearColor = MTLClearColorMake(factor, factor, factor, 1)
            (layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = factor > 1
            // macOS holds the extended range open for content that keeps
            // arriving, the way HDR video does; a single still frame gets it
            // for a couple of seconds and is then shown at normal brightness.
            // So a boost keeps presenting its one pixel; a dim, which needs no
            // headroom, is drawn once and left alone.
            isPaused = factor <= 1
            enableSetNeedsDisplay = factor <= 1
            needsDisplay = true
        }
    }

    init(frame: CGRect) {
        super.init(frame: frame, device: MTLCreateSystemDefaultDevice())
        queue = device?.makeCommandQueue()
        delegate = self
        autoResizeDrawable = false
        drawableSize = CGSize(width: 1, height: 1)
        colorPixelFormat = .rgba16Float
        colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        isPaused = true
        enableSetNeedsDisplay = true
        preferredFramesPerSecond = 30
        wantsLayer = true
        layer?.isOpaque = false
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError("not used") }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let queue, let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

