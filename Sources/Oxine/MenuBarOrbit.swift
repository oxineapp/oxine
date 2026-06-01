import AppKit
import QuartzCore

/// The animated menu-bar mark: an open ring with a bead sitting in the gap.
///
/// The whole glyph (ring + bead) is one rigid CALayer group; every motion is a
/// spring-driven rotation of that group, so the bead always slides *along* the
/// ring and the gap travels with it. Idle is static — no timers, no redraws —
/// so it costs nothing until an event fires. Motion quality comes from
/// `CASpringAnimation` (the "liquid glass" settle), rendered by CoreAnimation at
/// the display's native refresh (60/120 Hz ProMotion), GPU-interpolated.
@MainActor
final class OrbitStatusView: NSView {
    private let glyph = CALayer()        // rotated container (ring + bead)
    private let ring = CAShapeLayer()
    private let ringMask = CAShapeLayer() // knocks a clear moat around the bead
    private let bead = CAShapeLayer()

    // ── Tunables ────────────────────────────────────────────────────────────
    /// Where the bead rests when opening the panel. Negative = clockwise, so the
    /// bead swings over the top and drops into the bottom-right.
    private let openAngle: CGFloat = -165 * .pi / 180
    /// Bead rest angle (top-left). NSView layers are y-up, so +120° is top-left.
    private let restDeg: CGFloat = 120
    private let gapHalfDeg: CGFloat = 25
    private let strokeRel: CGFloat = 8.0 / 100
    private let beadRel: CGFloat = 12.0 / 100
    private let radiusRel: CGFloat = 34.0 / 100
    /// Width of the transparent gap cut around the bead so it floats free of the
    /// ring (as a fraction of the glyph side).
    private let moatRel: CGFloat = 5.0 / 100
    // ────────────────────────────────────────────────────────────────────────

    /// The current rest orientation: 0 idle, `openAngle` while the panel is open.
    /// This is the ONLY persisted angle — it never accumulates, so spins can't
    /// stack (a spin animates to base±2π but leaves the model at base).
    private var baseAngle: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(glyph)
        glyph.addSublayer(ring)
        glyph.addSublayer(bead)
        ring.fillColor = nil
        ring.lineCap = .round
        // Even-odd mask: shows the whole ring except a disc punched around the
        // bead, leaving a transparent moat so the dot reads as separate.
        ringMask.fillRule = .evenOdd
        ring.mask = ringMask
        rebuild()
        applyColor()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    // Clicks belong to the status button, not us.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var allowsVibrancy: Bool { true }

    override func layout() {
        super.layout()
        rebuild()
    }

    /// Rebuild the paths + recentre the rotation container for the current size.
    private func rebuild() {
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0 else { return }
        let side = min(w, h)
        let cx = w / 2, cy = h / 2
        let R = side * radiusRel
        let sw = max(1, side * strokeRel)
        let br = side * beadRel

        CATransaction.begin(); CATransaction.setDisableActions(true)
        glyph.frame = bounds
        glyph.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        glyph.position = CGPoint(x: cx, y: cy)
        glyph.bounds = CGRect(x: 0, y: 0, width: w, height: h)

        func pt(_ deg: CGFloat) -> CGPoint {
            let r = deg * .pi / 180
            return CGPoint(x: cx + R * cos(r), y: cy + R * sin(r))
        }
        // Ring arc = full circle minus the gap centred on the bead.
        let path = CGMutablePath()
        let start = (restDeg + gapHalfDeg) * .pi / 180
        let end = (restDeg - gapHalfDeg + 360) * .pi / 180
        path.addArc(center: CGPoint(x: cx, y: cy), radius: R,
                    startAngle: start, endAngle: end, clockwise: false)
        ring.path = path
        ring.lineWidth = sw

        let beadC = pt(restDeg)
        bead.path = CGPath(ellipseIn: CGRect(x: beadC.x - br, y: beadC.y - br,
                                             width: br * 2, height: br * 2), transform: nil)

        // Ring mask: the whole area, with a hole punched around the bead so the
        // ring is erased there (transparent moat). Even-odd makes the inner disc
        // a hole instead of filling it.
        let moat = side * moatRel
        let holeR = br + moat
        let maskPath = CGMutablePath()
        maskPath.addRect(CGRect(x: 0, y: 0, width: w, height: h))
        maskPath.addEllipse(in: CGRect(x: beadC.x - holeR, y: beadC.y - holeR,
                                       width: holeR * 2, height: holeR * 2))
        ringMask.frame = CGRect(x: 0, y: 0, width: w, height: h)
        ringMask.path = maskPath

        glyph.transform = CATransform3DMakeRotation(baseAngle, 0, 0, 1)
        CATransaction.commit()
    }

    // MARK: Colour (custom layers don't get the template auto-invert)

    override func viewDidChangeEffectiveAppearance() { applyColor() }
    private func applyColor() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let c = (dark ? NSColor.white : NSColor.black).cgColor
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ring.strokeColor = c
        bead.fillColor = c
        CATransaction.commit()
    }

    // MARK: Events

    /// New clipboard capture → one full spin (clockwise) that springs back to
    /// rest, plus a soft scale pop.
    func playCopy() {
        spinOnce(stiffness: 150, damping: 13)
        pop()
    }

    /// Panel shown/hidden → the bead slides to the bottom-right on open, then
    /// *continues the same way round* (down through the bottom-left) on close,
    /// rather than retracing its path, so it completes a full loop.
    func setPanelOpen(_ open: Bool) {
        if open {
            baseAngle = openAngle
            settle(to: openAngle, stiffness: 200, damping: 20)
        } else {
            // Keep going clockwise the rest of the circle: animate to −2π (the
            // bottom-left route) but land the model back at 0 (same as −2π).
            baseAngle = 0
            settle(to: -.pi * 2, modelTo: 0, stiffness: 200, damping: 20)
        }
    }

    // MARK: Motion primitives

    private func presentationAngle() -> CGFloat {
        (glyph.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat)
            ?? (glyph.value(forKeyPath: "transform.rotation.z") as? CGFloat) ?? baseAngle
    }

    /// Spring the rotation visually to `to`, leaving the model at `modelTo`
    /// (defaults to `to`). `modelTo` lets the close animation travel to −2π while
    /// resting the model at 0 — the same angle, so there's no snap.
    private func settle(from: CGFloat? = nil, to: CGFloat, modelTo: CGFloat? = nil,
                        stiffness: CGFloat, damping: CGFloat) {
        let spring = CASpringAnimation(keyPath: "transform.rotation.z")
        spring.fromValue = from ?? presentationAngle()
        spring.toValue = to
        spring.mass = 1
        spring.stiffness = stiffness
        spring.damping = damping
        spring.duration = spring.settlingDuration
        glyph.transform = CATransform3DMakeRotation(modelTo ?? to, 0, 0, 1)
        glyph.add(spring, forKey: "rot")
    }

    /// One full clockwise turn that ends back at `baseAngle`. The model stays at
    /// `baseAngle` (base−2π is the same angle), so turns never accumulate.
    private func spinOnce(stiffness: CGFloat, damping: CGFloat) {
        let spring = CASpringAnimation(keyPath: "transform.rotation.z")
        spring.fromValue = presentationAngle()
        spring.toValue = baseAngle - .pi * 2
        spring.mass = 1
        spring.stiffness = stiffness
        spring.damping = damping
        spring.duration = spring.settlingDuration
        glyph.transform = CATransform3DMakeRotation(baseAngle, 0, 0, 1)
        glyph.add(spring, forKey: "rot")
    }

    /// A soft scale breath layered on top of the rotation (the "glass" pop).
    private func pop() {
        let s = CAKeyframeAnimation(keyPath: "transform.scale")
        s.values = [1.0, 1.16, 1.0]
        s.keyTimes = [0, 0.4, 1]
        s.duration = 0.45
        s.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glyph.add(s, forKey: "pop")
    }
}
