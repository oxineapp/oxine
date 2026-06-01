import SwiftUI
import SousShared

/// A real Sankey power-flow diagram in the AlDente spirit: energy enters from
/// the left (charger and/or battery) and is consumed on the right (the Mac, and
/// the battery while it charges). Each flow is a **constant-thickness Liquid
/// Glass ribbon** whose height is its share of the total power; ribbons curve to
/// merge at a shared source and fan out to separate consumers, with soft light
/// drifting left→right at a speed scaled to the wattage. Glass is the surface —
/// colour is only a whisper of tint so it reads its meaning without going loud.
/// Reads only the unprivileged `BatteryMetrics`.
struct PowerFlowView: View {
    let metrics: BatteryMetrics
    let state: SousState
    private var accent: Color { .oxineAccent }

    private struct Port { let symbol: String }
    private struct Band { let from: Int; let to: Int; let watts: Double; let color: Color }
    private struct Model { var left: [Port]; var right: [Port]; var bands: [Band] }

    private func model() -> Model {
        let load = max(metrics.systemLoadW ?? max(0, -metrics.batteryPowerW), 0)
        let charge = max(0, metrics.batteryPowerW)      // into the battery
        let drain = max(0, -metrics.batteryPowerW)      // out of the battery
        let adapterIn = metrics.adapterInputW ?? (load + charge)
        let green = Color(red: 0.34, green: 0.80, blue: 0.48)
        let orange = Color(red: 0.96, green: 0.62, blue: 0.26), blue = accent

        if metrics.externalConnected {
            if charge > 0.5 {
                // Charging: the charger feeds both the Mac and the battery.
                return Model(
                    left: [Port(symbol: "bolt.fill")],
                    right: [Port(symbol: "battery.100.bolt"), Port(symbol: "laptopcomputer")],
                    bands: [Band(from: 0, to: 0, watts: charge, color: green),
                            Band(from: 0, to: 1, watts: max(load, 0.05), color: blue)])
            }
            if drain > 0.5 {
                // Plugged but the battery is chipping in (underpowered charger).
                return Model(
                    left: [Port(symbol: "bolt.fill"), Port(symbol: "battery.50")],
                    right: [Port(symbol: "laptopcomputer")],
                    bands: [Band(from: 0, to: 0, watts: adapterIn, color: blue),
                            Band(from: 1, to: 0, watts: drain, color: orange)])
            }
            // Paused at the limit: charger powers the Mac only.
            return Model(
                left: [Port(symbol: "bolt.fill")],
                right: [Port(symbol: "laptopcomputer")],
                bands: [Band(from: 0, to: 0, watts: max(load, 0.05), color: blue)])
        }
        // On battery.
        return Model(
            left: [Port(symbol: "battery.50")],
            right: [Port(symbol: "laptopcomputer")],
            bands: [Band(from: 0, to: 0, watts: max(drain, 0.05), color: orange)])
    }

    var body: some View {
        let m = model()
        let total = max(m.bands.reduce(0) { $0 + $1.watts }, 0.05)
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let cw: CGFloat = 32
            let padV: CGFloat = 6
            let gap: CGFloat = 6
            let x0 = cw + 2                 // ribbon start, flush to the left chips' flat edge
            let x1 = w - cw - 2             // ribbon end, flush to the right chips' flat edge

            // Gaps appear only between *different* chips on a side; a shared chip
            // keeps its ribbons merged. Constant ribbon thickness uses whichever
            // side needs the most gaps so it fits both.
            let gapsL = boundaryCount(m.bands, side: .from)
            let gapsR = boundaryCount(m.bands, side: .to)
            let usableH = h - padV * 2 - gap * CGFloat(max(gapsL, gapsR))
            // Clamp each flow to a minimum so a tiny ribbon never detaches from its
            // chip, then scale to fit if the minimums overflow the height. The chip
            // is sized to exactly this span (see chipFrame), so they stay flush.
            let minThk: CGFloat = 30
            let raw = m.bands.map { max(usableH * CGFloat($0.watts / total), minThk) }
            let rawSum = raw.reduce(0, +)
            let thk = rawSum > usableH ? raw.map { $0 * usableH / rawSum } : raw

            let lTop = tops(m.bands, side: .from, thk: thk, h: h, pad: padV, gap: gap)
            let rTop = tops(m.bands, side: .to, thk: thk, h: h, pad: padV, gap: gap)

            ZStack {
                ForEach(Array(m.bands.enumerated()), id: \.offset) { i, band in
                    RibbonLayer(
                        w: w, h: h,
                        x0: x0, x1: x1,
                        leftTop: lTop[i] ?? padV, rightTop: rTop[i] ?? padV,
                        thickness: thk[i],
                        color: band.color, watts: band.watts
                    )
                }
                ForEach(Array(m.left.enumerated()), id: \.offset) { i, p in
                    let (y, ch) = chipFrame(port: i, side: .from, bands: m.bands, thk: thk, tops: lTop, h: h, pad: padV)
                    chip(p.symbol, roundLeading: true).frame(width: cw, height: ch).position(x: cw / 2 + 2, y: y)
                }
                ForEach(Array(m.right.enumerated()), id: \.offset) { i, p in
                    let (y, ch) = chipFrame(port: i, side: .to, bands: m.bands, thk: thk, tops: rTop, h: h, pad: padV)
                    chip(p.symbol, roundLeading: false).frame(width: cw, height: ch).position(x: w - cw / 2 - 2, y: y)
                }
            }
        }
    }

    private enum Side { case from, to }
    private func chipOf(_ b: Band, _ side: Side) -> Int { side == .from ? b.from : b.to }

    /// Number of chip-boundaries on a side: a gap opens only between *different*
    /// chips, so ribbons merge at a shared source (the bolt) and fan apart to
    /// separate consumers — that divergence is the Sankey wedge.
    private func boundaryCount(_ bands: [Band], side: Side) -> Int {
        let order = bands.indices.sorted { (chipOf(bands[$0], side), $0) < (chipOf(bands[$1], side), $1) }
        guard order.count > 1 else { return 0 }
        return (1..<order.count).reduce(0) { acc, k in
            acc + (chipOf(bands[order[k]], side) != chipOf(bands[order[k - 1]], side) ? 1 : 0)
        }
    }

    /// Top Y of each ribbon at one side, stacked by chip — merged within a chip,
    /// a gap between different chips — and centred in the height. The left/right
    /// asymmetry (merged source, split targets) is what curves the ribbons.
    private func tops(_ bands: [Band], side: Side, thk: [CGFloat],
                      h: CGFloat, pad: CGFloat, gap: CGFloat) -> [Int: CGFloat] {
        let order = bands.indices.sorted { (chipOf(bands[$0], side), $0) < (chipOf(bands[$1], side), $1) }
        var gaps = 0
        if order.count > 1 {
            for k in 1..<order.count where chipOf(bands[order[k]], side) != chipOf(bands[order[k - 1]], side) { gaps += 1 }
        }
        let used = order.map { thk[$0] }.reduce(0, +) + gap * CGFloat(gaps)
        var cursor = pad + max(0, (h - pad * 2 - used)) / 2
        var out: [Int: CGFloat] = [:]
        for (k, i) in order.enumerated() {
            if k > 0 && chipOf(bands[order[k]], side) != chipOf(bands[order[k - 1]], side) { cursor += gap }
            out[i] = cursor
            cursor += thk[i]
        }
        return out
    }

    /// Centre-Y and height for a chip: spans the union of the ribbons touching it.
    private func chipFrame(port: Int, side: Side, bands: [Band], thk: [CGFloat],
                           tops: [Int: CGFloat], h: CGFloat, pad: CGFloat) -> (CGFloat, CGFloat) {
        let idxs = bands.indices.filter { chipOf(bands[$0], side) == port }
        guard let top = idxs.compactMap({ tops[$0] }).min(),
              let bot = idxs.compactMap({ i in tops[i].map { $0 + thk[i] } }).max()
        else { return (h / 2, 40) }
        // Match the chip to the exact span of its flow(s) so they're always flush.
        let height = min(bot - top, h - pad * 2)
        return ((top + bot) / 2, height)
    }

    /// A D-shaped glass tile: rounded on its *outer* edge, flat on the edge
    /// facing the Sankey so ribbons sit flush against it. `roundLeading` rounds
    /// the left side (for left chips); false rounds the right (for right chips).
    private func chip(_ symbol: String, roundLeading: Bool) -> some View {
        let r: CGFloat = 13
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: roundLeading ? r : 0,
            bottomLeadingRadius: roundLeading ? r : 0,
            bottomTrailingRadius: roundLeading ? 0 : r,
            topTrailingRadius: roundLeading ? 0 : r,
            style: .continuous)
        return ZStack {
            // Same translucent glass panel as the ribbons (no blur layer).
            shape.fill(.white.opacity(0.16))
            shape.fill(LinearGradient(colors: [.white.opacity(0.14), .clear],
                                      startPoint: .top, endPoint: .center))
            shape.stroke(.white.opacity(0.22), lineWidth: 0.6)
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)          // crisp glyph on top
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One Sankey ribbon: a curved constant-thickness Liquid Glass band carrying its
/// wattage label, with soft light drifting along it left→right.
private struct RibbonLayer: View {
    let w: CGFloat, h: CGFloat
    let x0: CGFloat, x1: CGFloat
    let leftTop: CGFloat, rightTop: CGFloat
    let thickness: CGFloat
    let color: Color
    let watts: Double

    private var shape: RibbonShape {
        RibbonShape(x0: x0, x1: x1, leftTop: leftTop, rightTop: rightTop, thickness: thickness)
    }
    private var leftMid: CGFloat { leftTop + thickness / 2 }
    private var rightMid: CGFloat { rightTop + thickness / 2 }

    var body: some View {
        ZStack {
            // A translucent glassy panel sitting *on* the card's liquid glass — no
            // extra backdrop-blur layer, so nothing frosts over the content.
            shape.fill(.white.opacity(0.14))
            // Top gloss for the glass sheen.
            shape.fill(LinearGradient(colors: [.white.opacity(0.13), .clear],
                                      startPoint: .top, endPoint: .center))
            // A faint identity tint so green vs accent reads even at rest.
            shape.fill(color.opacity(0.10))
            // The colour lives in the wave, which sweeps left→right.
            colorWave.mask(shape)
            // Crisp edge.
            shape.stroke(.white.opacity(0.22), lineWidth: 0.6)
            // Wattage, riding the ribbon's centre — drawn last, fully crisp.
            if thickness > 15 {
                Text(String(format: "%.1f W", watts))
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.5), radius: 1.5, y: 0.5)
                    .position(x: (x0 + x1) / 2, y: (leftMid + rightMid) / 2)
            }
        }
        .frame(width: w, height: h)
    }

    /// A soft pulse of `color` that sweeps the ribbon left→right, then rests.
    /// The rest shrinks with wattage, so heavier flow pulses more often; near
    /// zero it's a rare, slow shimmer.
    private var colorWave: some View {
        TimelineView(.animation) { ctx in
            Canvas { gc, _ in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let span = x1 - x0
                let sweep = 1.1                                   // seconds to cross
                let rest = min(max(7.0 - Double(min(watts, 90)) * 0.075, 0.5), 7.0)
                let cycle = sweep + rest
                let phase = t.truncatingRemainder(dividingBy: cycle)
                guard phase < sweep else { return }               // resting → just the panel

                // Eased position of the wave's centre.
                let raw = phase / sweep
                let p = raw * raw * (3 - 2 * raw)                 // smoothstep
                let cx = x0 + CGFloat(p) * span
                let cy = leftMid + (rightMid - leftMid) * CGFloat(p)
                let half = max(span * 0.22, 40)
                // Brighter at mid-sweep, fading in at the start and out at the end.
                let envelope = sin(Double(raw) * .pi)
                let peak = 0.7 * envelope

                let band = CGRect(x: cx - half, y: cy - thickness, width: half * 2, height: thickness * 2)
                let grad = Gradient(stops: [
                    .init(color: color.opacity(0), location: 0),
                    .init(color: color.opacity(peak), location: 0.5),
                    .init(color: color.opacity(0), location: 1),
                ])
                gc.fill(Path(band),
                        with: .linearGradient(grad,
                                              startPoint: CGPoint(x: band.minX, y: cy),
                                              endPoint: CGPoint(x: band.maxX, y: cy)))
            }
            .frame(width: w, height: h)
        }
    }
}

/// A closed Sankey ribbon path: two cubic edges (top and bottom) of equal
/// thickness running x0→x1, easing horizontally so flows curve smoothly.
private struct RibbonShape: Shape {
    var x0: CGFloat, x1: CGFloat
    var leftTop: CGFloat, rightTop: CGFloat
    var thickness: CGFloat

    func path(in rect: CGRect) -> Path {
        let mid = (x0 + x1) / 2
        var p = Path()
        p.move(to: CGPoint(x: x0, y: leftTop))
        p.addCurve(to: CGPoint(x: x1, y: rightTop),
                   control1: CGPoint(x: mid, y: leftTop),
                   control2: CGPoint(x: mid, y: rightTop))
        p.addLine(to: CGPoint(x: x1, y: rightTop + thickness))
        p.addCurve(to: CGPoint(x: x0, y: leftTop + thickness),
                   control1: CGPoint(x: mid, y: rightTop + thickness),
                   control2: CGPoint(x: mid, y: leftTop + thickness))
        p.closeSubpath()
        return p
    }
}
