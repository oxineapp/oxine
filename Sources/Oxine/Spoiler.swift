import SwiftUI
import PanelKit

enum SpoilerStyle {
    /// Hides the content outright.
    case text
    /// Denser, larger specks for a picture such as a QR code. Nothing of it
    /// shows until it's revealed (a blurred copy used to, and its light edges
    /// read as a frame). Clip it to the content's shape at the call site.
    case image
}

/// Invisible ink, after iMessage's: hidden content turns into a field of
/// drifting, twinkling specks. Revealing blows them outward in a ring from
/// `origin` while the content clears behind it; hiding pulls them back in.
struct Spoiler<Content: View>: View {
    var isHidden: Bool
    /// Where a reveal starts and a hide closes in, in the content's unit space.
    var origin: UnitPoint
    var style: SpoilerStyle
    var content: Content

    /// The cleared share of the content when the last change happened.
    @State private var startFraction: Double
    @State private var changedAt = Date.distantPast
    /// `isHidden` as of the last change. It trails `isHidden` by one update,
    /// which keeps the first frame of a reveal from flashing the content.
    @State private var recorded: Bool
    @State private var transitioning = false
    @ObservedObject private var visibility = PanelVisibility.shared

    private static var revealDuration: Double { 0.8 }
    private static var hideDuration: Double { 0.6 }
    /// Width of the soft edge between cleared content and specks.
    private static var feather: Double { 16 }

    init(isHidden: Bool, origin: UnitPoint = .center, style: SpoilerStyle = .text, @ViewBuilder content: () -> Content) {
        self.isHidden = isHidden
        self.origin = origin
        self.style = style
        self.content = content()
        _startFraction = State(initialValue: isHidden ? 0 : 1)
        _recorded = State(initialValue: isHidden)
    }

    var body: some View {
        content
            .hidden()
            .overlay {
                if isHidden || recorded || transitioning {
                    GeometryReader { geo in
                        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !visibility.isOpen)) { timeline in
                            veil(at: timeline.date, size: geo.size)
                        }
                    }
                    .accessibilityHidden(true)
                } else {
                    content
                }
            }
            .onChange(of: isHidden) {
                let now = Date()
                startFraction = fraction(at: now)
                recorded = isHidden
                changedAt = now
                transitioning = true
                let duration = isHidden ? Self.hideDuration : Self.revealDuration
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                    if changedAt == now { transitioning = false }
                }
            }
    }

    /// How much of the content is cleared, 0 (veiled) to 1 (shown). Reveals
    /// ease out like a burst; hides ease in and out like a tide.
    private func fraction(at date: Date) -> Double {
        let target: Double = recorded ? 0 : 1
        let duration = recorded ? Self.hideDuration : Self.revealDuration
        let p = min(max(date.timeIntervalSince(changedAt) / duration, 0), 1)
        let eased = recorded ? p * p * (3 - 2 * p) : 1 - pow(1 - p, 3)
        return startFraction + (target - startFraction) * eased
    }

    @ViewBuilder
    private func veil(at date: Date, size: CGSize) -> some View {
        let o = CGPoint(x: origin.x * size.width, y: origin.y * size.height)
        let corners = [CGPoint.zero, CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)]
        let reach = corners.map { hypot($0.x - o.x, $0.y - o.y) }.max()! + Self.feather + 2
        let front = fraction(at: date) * reach
        let time = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 100_000)

        ZStack {
            if front > 0.5 {
                content.mask(
                    RadialGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: max(front - Self.feather, 0) / reach),
                            .init(color: .clear, location: front / reach),
                        ],
                        center: origin, startRadius: 0, endRadius: reach)
                )
            }
            Canvas { ctx, canvasSize in
                SpeckField.draw(in: ctx, size: canvasSize, style: style, origin: o, front: front, time: time)
            }
        }
    }
}

/// The specks themselves. Every speck is a pure function of its index and the
/// clock, so nothing is stored between frames: each lives a second or three,
/// fades in and out while it drifts, then respawns somewhere new.
private enum SpeckField {
    /// Specks group into four brightness levels so a frame is four fills,
    /// not one per speck.
    private static let levels: [Double] = [0.22, 0.45, 0.7, 0.95]

    static func draw(in ctx: GraphicsContext, size: CGSize, style: SpoilerStyle,
                        origin o: CGPoint, front: Double, time t: Double) {
        let isText = style == .text
        let area = Double(size.width * size.height)
        let count = min(isText ? 700 : 2400, Int(area / (isText ? 5 : 8)))
        var paths = [Path](repeating: Path(), count: levels.count)

        for i in 0..<count {
            let seed = mix(UInt64(i) &+ 1)
            let lifespan = 1.2 + 1.8 * unit(seed, 1)
            let age = (t + unit(seed, 2) * lifespan) / lifespan
            let life = age.rounded(.down)
            let local = age - life
            let s = mix(seed ^ UInt64(bitPattern: Int64(life)))

            let angle = unit(s, 3) * 2 * .pi
            let drift = (2 + 6 * unit(s, 4)) * local * lifespan
            var x = unit(s, 5) * size.width + cos(angle) * drift
            var y = unit(s, 6) * size.height + sin(angle) * drift
            var alpha = sin(.pi * local) * (0.45 + 0.55 * unit(s, 7))
            var diameter = (isText ? 0.9 : 1.2) + 0.8 * unit(s, 8)

            if front > 0 {
                let dx = x - o.x, dy = y - o.y
                let distance = max(hypot(dx, dy), 0.001)
                let past = distance - front
                if past < 0 {
                    // Inside the cleared circle: thrown out past the edge, fading.
                    let push = -past * 1.15
                    x += dx / distance * push
                    y += dy / distance * push
                    alpha *= max(0, 1 + past / 18)
                }
                // Specks riding the edge flare.
                let flare = max(0, 1 - abs(past) / 12)
                alpha *= 1 + 0.9 * flare
                diameter *= 1 + 0.45 * flare
            }
            guard alpha > 0.04 else { continue }

            let level = min(levels.count - 1, Int(alpha / 0.95 * Double(levels.count)))
            paths[level].addEllipse(in: CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter))
        }
        for (path, level) in zip(paths, levels) where !path.isEmpty {
            ctx.fill(path, with: .color(.white.opacity(level)))
        }
    }

    /// SplitMix64: a fast, well-spread hash for per-speck randomness.
    private static func mix(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    private static func unit(_ seed: UInt64, _ salt: UInt64) -> Double {
        Double(mix(seed &+ salt &* 0xA24B_AED4_963E_E407) >> 11) / Double(1 << 53)
    }
}
