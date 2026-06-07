import SwiftUI
import AppKit
import Combine

/// DynamicNotchKit's collapsed-notch geometry, lifted verbatim from its
/// `NotchView` so our bar lands exactly on the cutout the kit renders — derived,
/// not guessed:
///   • `compactNotchCornerRadii = (top: 6, bottom: 14)`
///   • rendered width = `notchSize.width + topCornerRadius * 2`  (its `minWidth`)
/// File-level so the nonisolated `Shape` can use them as defaults.
enum NotchBarMetrics {
    static let topCorner: CGFloat = 6
    static let bottomCorner: CGFloat = 14
    /// Panel margin around the stroke so its round caps aren't clipped at the edge.
    static let margin: CGFloat = 4
    /// Stroke weight for both the track and the fill (kept slim/subtle).
    static let lineWidth: CGFloat = 2.0
    /// A measured ear narrower than this is just its padding (no content), so that
    /// side collapses to the bare notch edge instead of leaving a stub.
    static let emptyEar: CGFloat = 12
    /// The kit's own margin around each compact ear, beyond our content: its
    /// `safeAreaInset` (8) + the `.padding(.horizontal, compact topCornerRadius=6)`
    /// it wraps the whole island in. Derived from DynamicNotchKit's `NotchView`,
    /// not guessed — the black island edge sits this far past our ear content.
    static let kitMargin: CGFloat = 14
    /// How far the silhouette's *bottom* sits below the notch's bottom edge.
    static let outset: CGFloat = 2
    /// The visible gap between each vertical edge and the island it hugs. The shape
    /// insets its verticals by `topCorner` for the flare, so the rect must extend
    /// `topCorner + sideGap` past the real ear edge for the stroke to clear it.
    static let sideGap: CGFloat = 1
}

/// The "bar" peek mode: a progress bar shaped like the notch's inner silhouette
/// (left edge down, the rounded bottom, right edge up — not the top line) that
/// fills left → right by the chosen metric (CPU / GPU / fan / Claude 5h). It's a
/// separate, fully click-through overlay panel so it can never reintroduce a click
/// deadzone. It steps aside only when the notch itself is expanded or a HUD has
/// taken over the ears. Opt-in.
@MainActor
final class NotchBarOverlay {
    private let hub: PeekHub
    private let screen: NSScreen
    private var panel: NSPanel?
    private var timer: Timer?
    /// Set by the presenter: the notch is open, so the bar (which traces the
    /// collapsed island) should step aside.
    private var expanded = false
    /// Set by the presenter: a HUD / sneak-peek has taken over the ears (which
    /// balloons the island), so hide rather than wrap it.
    private var suppressed = false

    /// The frame currently applied to the panel, so we can tell a grow from a shrink.
    private var appliedFrame: CGRect = .zero
    /// A queued shrink, held until the ear's retract animation has settled.
    private var pendingShrink: DispatchWorkItem?
    /// Roughly the kit's compact-ear animation (`.smooth`) duration — long enough
    /// that the bar follows the ear *back* instead of snapping through it mid-retract.
    private let shrinkDelay: TimeInterval = 0.55
    /// After a HUD / sneak-peek takeover ends, wait this long before the bar returns,
    /// so it never reappears while the ballooned ear is still retracting.
    private let reappearDelay: TimeInterval = 1.0
    /// While set (and in the future), the bar stays hidden even though nothing is
    /// actively suppressing it — the post-takeover settle window.
    private var holdHiddenUntil: Date?
    private var reappearWork: DispatchWorkItem?

    /// The bar's fill fractions, refreshed by the timer (not the hub firehose).
    private let fill = BarFillModel()

    private var bag = Set<AnyCancellable>()

    init(hub: PeekHub, screen: NSScreen) {
        self.hub = hub
        self.screen = screen
    }

    func start() {
        build()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshFill()
                self?.tick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // React to ear-frame changes only while the bar is *visible* — during an
        // open the ears churn as they animate out, and reacting then would storm
        // tick() for a bar that's hidden anyway.
        hub.$leftEarFrame.combineLatest(hub.$rightEarFrame)
            .sink { [weak self] _ in
                guard let self, !self.isHidden else { return }
                self.tick()
            }
            .store(in: &bag)
        refreshFill()
        tick()
    }

    /// True whenever the bar should not be on screen (notch open, a takeover owns
    /// the ears, or the post-takeover settle window hasn't elapsed).
    private var isHidden: Bool {
        expanded || suppressed || (holdHiddenUntil.map { Date() < $0 } ?? false)
    }

    /// Read the selected metric(s) into the fill model — the only place that touches
    /// the live monitors, at the timer's cadence, so the SwiftUI bar re-renders at
    /// most ~2×/sec instead of on every hub publish.
    private func refreshFill() {
        guard !isHidden else { return }   // nothing visible to update
        func value(_ m: BarMetric) -> Double {
            switch m {
            case .cpu:    return hub.usage.cpu
            case .gpu:    return hub.usage.gpu
            case .fan:    return NotchKit.fanReadout?()?.fraction ?? 0
            case .claude: return hub.claude.readout?.fraction ?? 0
            }
        }
        fill.primary = value(BarMetric.selected)
        if BarMetric.splitEnabled { fill.secondary = value(BarMetric.secondary) }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        pendingShrink?.cancel(); pendingShrink = nil
        reappearWork?.cancel(); reappearWork = nil
        bag.removeAll()
        panel?.orderOut(nil)
        panel = nil
    }

    private func build() {
        let frame = barFrame()
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        // Above DynamicNotchKit's own window (`.screenSaver`) so the silhouette
        // outline draws on top of the notch edge instead of being occluded by it.
        p.level = .screenSaver + 1
        p.ignoresMouseEvents = true                 // never eat clicks
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.contentView = NSHostingView(rootView: NotchBarView(fill: fill))
        p.orderFrontRegardless()
        panel = p
    }

    /// Called by the presenter as the notch opens/closes.
    func setExpanded(_ e: Bool) {
        guard expanded != e else { return }
        expanded = e
        tick()
    }

    /// Called by the presenter when a HUD / sneak-peek takes over (or releases) the ears.
    func setSuppressed(_ s: Bool) {
        guard suppressed != s else { return }
        suppressed = s
        reappearWork?.cancel(); reappearWork = nil
        if s {
            holdHiddenUntil = nil
        } else {
            // Hold the bar back until the ballooned ear has finished retracting, so
            // it never reappears mid-shrink or sized to the (gone) takeover.
            holdHiddenUntil = Date().addingTimeInterval(reappearDelay)
            let work = DispatchWorkItem { [weak self] in
                self?.holdHiddenUntil = nil
                self?.reappearWork = nil
                self?.tick()
            }
            reappearWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + reappearDelay, execute: work)
        }
        tick()
    }

    private func tick() {
        guard let panel else { return }
        if isHidden {
            // Hidden: do NO geometry work (the ears churn while the notch animates
            // open — recomputing/committing the frame then was pure waste). Just
            // pull the panel off-screen; geometry is recomputed when it reappears.
            pendingShrink?.cancel(); pendingShrink = nil
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        applyGeometry(barFrame(), to: panel)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Apply a grow at once (the bar should be ready as the ear expands), but hold a
    /// shrink for `shrinkDelay` so the outline follows the ear *back* after its
    /// retract animation instead of snapping through it.
    private func applyGeometry(_ target: CGRect, to panel: NSPanel) {
        if appliedFrame == .zero { commit(target, to: panel); return }
        let grows = target.minX < appliedFrame.minX - 0.5 || target.maxX > appliedFrame.maxX + 0.5
        let shrinks = target.minX > appliedFrame.minX + 0.5 || target.maxX < appliedFrame.maxX - 0.5
        if shrinks && !grows {
            guard pendingShrink == nil else { return }   // a shrink is already queued
            let work = DispatchWorkItem { [weak self] in
                guard let self, let panel = self.panel else { return }
                self.pendingShrink = nil
                guard !self.expanded, !self.suppressed else { return }
                self.commit(self.barFrame(), to: panel)   // re-read the latest edges
            }
            pendingShrink = work
            DispatchQueue.main.asyncAfter(deadline: .now() + shrinkDelay, execute: work)
        } else {
            pendingShrink?.cancel(); pendingShrink = nil   // a grow supersedes a queued shrink
            commit(target, to: panel)
        }
    }

    private func commit(_ frame: CGRect, to panel: NSPanel) {
        // Ignore sub-pixel churn (the 24fps visualizer jitters the measured ear
        // frame); only move the panel on a real, >0.5pt change.
        if abs(frame.minX - appliedFrame.minX) < 0.5, abs(frame.maxX - appliedFrame.maxX) < 0.5,
           abs(frame.minY - appliedFrame.minY) < 0.5, abs(frame.height - appliedFrame.height) < 0.5 {
            return
        }
        appliedFrame = frame
        panel.setFrame(frame, display: false)
    }

    /// DynamicNotchKit's notch window, used to flip the ears' window-space frames
    /// into screen coordinates (same approach as the presenter's `currentWindow`).
    /// Cached: `barFrame()` runs on every ear-frame change (the visualizer churns it
    /// at 24fps), and an `NSApp.windows` scan per frame was the open-stutter source.
    private var cachedWindow: NSWindow?
    private func notchWindow() -> NSWindow? {
        if let w = cachedWindow { return w }
        cachedWindow = NSApp.windows.first {
            NSStringFromClass(type(of: $0)) == "DynamicNotchKit.DynamicNotchPanel"
        }
        return cachedWindow
    }

    /// The panel is sized and positioned to the *real* island: the notch plus
    /// whichever ears actually carry content, read from their live on-screen
    /// frames. No notch-width constant, no per-ear chrome, no centering math —
    /// the geometry is measured, not reconstructed. A side with an empty ear
    /// collapses to the notch edge.
    private func barFrame() -> CGRect {
        let n = NotchGeometry.notchFrame(for: screen)
        var left = n.minX, right = n.maxX
        if let window = notchWindow() {
            let wx = window.frame.minX
            let lf = hub.leftEarFrame, rf = hub.rightEarFrame
            // Hug the real island edge = the ear content's measured edge plus the
            // kit's own margin. An empty side collapses to the bare notch.
            let m = NotchBarMetrics.kitMargin
            if lf.width > NotchBarMetrics.emptyEar { left = min(left, wx + lf.minX - m) }
            if rf.width > NotchBarMetrics.emptyEar { right = max(right, wx + rf.maxX + m) }
        }
        // Slack = the 1px gap + the panel margin only. The shape already insets its
        // verticals by `topCorner` to draw the flare, so adding it here too would
        // double-count the corner and push the outline ~7px past the real edge.
        let slack = NotchBarMetrics.sideGap + NotchBarMetrics.margin
        let h = n.height + NotchBarMetrics.outset + NotchBarMetrics.margin
        return CGRect(x: left - slack, y: screen.frame.maxY - h,
                      width: (right - left) + slack * 2, height: h)
    }
}

/// Just the fill fractions the bar draws, published at the overlay timer's cadence
/// (~2 Hz) rather than off `PeekHub`'s firehose (CPU/GPU/agents/now-playing/ear
/// frames all republish there). Observing the firehose made the transparent overlay
/// re-render — and recomposite over whatever's behind it — far too often, which was
/// the bulk of the bar's runtime cost. This caps the bar's re-render rate.
@MainActor
final class BarFillModel: ObservableObject {
    @Published var primary: Double = 0
    @Published var secondary: Double = 0
}

/// The silhouette progress bar: a dim full-length track with a bright fill that
/// sweeps to the chosen metric's 0…1 value. It simply fills the panel the overlay
/// has already sized and positioned to the real island, so it holds no geometry of
/// its own — only the metric reveal.
private struct NotchBarView: View {
    @ObservedObject var fill: BarFillModel

    /// Geometry-check mode: bold bright-red full outline, ignoring the metric.
    /// Enable with `defaults write com.oxine.settings notchBarDebug -bool true`.
    private var debug: Bool { NotchKit.settingsDefaults.bool(forKey: "notchBarDebug") }

    var body: some View {
        let lw: CGFloat = debug ? 6 : NotchBarMetrics.lineWidth
        ZStack {
            // Dim track over the whole silhouette (one continuous outline either way).
            NotchBarShape()
                .stroke(Color.white.opacity(debug ? 0.4 : 0.14),
                        style: StrokeStyle(lineWidth: lw, lineCap: .round))
            if debug {
                stroke(tint: .red, lw: lw)
            } else if BarMetric.splitEnabled {
                // Each half fills from its outer edge inward to the centre.
                stroke(tint: BarMetric.selected.color, lw: lw)
                    .mask { reveal(0.5 * fill.primary, .leading) }
                    .animation(.easeInOut(duration: 0.55), value: fill.primary)
                stroke(tint: BarMetric.secondary.color, lw: lw)
                    .mask { reveal(0.5 * fill.secondary, .trailing) }
                    .animation(.easeInOut(duration: 0.55), value: fill.secondary)
            } else {
                stroke(tint: BarMetric.selected.color, lw: lw)
                    .mask { reveal(fill.primary, .leading) }
                    .animation(.easeInOut(duration: 0.55), value: fill.primary)
            }
        }
        // Fill the panel minus the stroke margin; the top stays flush to the screen.
        .padding(.horizontal, NotchBarMetrics.margin)
        .padding(.bottom, NotchBarMetrics.margin)
    }

    /// A reveal mask that exposes `frac` of the width from `anchor`, scaled (so it
    /// needs no pixel width) and animatable.
    private func reveal(_ frac: Double, _ anchor: UnitPoint) -> some View {
        Rectangle().scaleEffect(x: max(0, frac), y: 1, anchor: anchor)
    }

    /// The bright, tinted silhouette stroke before masking.
    private func stroke(tint: Color, lw: CGFloat) -> some View {
        NotchBarShape()
            .stroke(
                LinearGradient(colors: [tint, tint.opacity(debug ? 1 : 0.8)],
                               startPoint: .leading, endPoint: .trailing),
                style: StrokeStyle(lineWidth: lw, lineCap: .round))
    }
}

/// The notch's screen-facing silhouette: the top-corner flares, both sides, and
/// the rounded bottom — but NOT the straight top line. This is DynamicNotchKit's
/// own `NotchShape` path reproduced exactly, just left open at the top, so the
/// stroke traces the precise edge of the rendered cutout.
struct NotchBarShape: Shape {
    var top: CGFloat = NotchBarMetrics.topCorner
    var bottom: CGFloat = NotchBarMetrics.bottomCorner

    func path(in r: CGRect) -> Path {
        var p = Path()
        // Top-left, flaring down into the notch.
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + top, y: r.minY + top),
                       control: CGPoint(x: r.minX + top, y: r.minY))
        // Down the left side.
        p.addLine(to: CGPoint(x: r.minX + top, y: r.maxY - bottom))
        // Bottom-left inner corner.
        p.addQuadCurve(to: CGPoint(x: r.minX + top + bottom, y: r.maxY),
                       control: CGPoint(x: r.minX + top, y: r.maxY))
        // Across the bottom.
        p.addLine(to: CGPoint(x: r.maxX - top - bottom, y: r.maxY))
        // Bottom-right inner corner.
        p.addQuadCurve(to: CGPoint(x: r.maxX - top, y: r.maxY - bottom),
                       control: CGPoint(x: r.maxX - top, y: r.maxY))
        // Up the right side.
        p.addLine(to: CGPoint(x: r.maxX - top, y: r.minY + top))
        // Top-right, flaring up to the edge. (No closing top line.)
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY),
                       control: CGPoint(x: r.maxX - top, y: r.minY))
        return p
    }
}
