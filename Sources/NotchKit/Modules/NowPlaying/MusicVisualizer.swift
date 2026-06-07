import SwiftUI

/// The little equaliser bars shown in the idle peek (image 3). Animates while
/// playing, then *winds down* to flat when paused instead of snapping. Cosmetic —
/// not driven by real audio, but shaped to *feel* musical: each bar mixes a couple
/// of incommensurate sines (so the pattern never visibly loops) under a shared,
/// slowly pulsing "energy" envelope, and the whole bank rides a 0…1 `energy` ramp
/// so toggling playback eases in/out rather than cutting.
struct MusicVisualizer: View {
    var isPlaying: Bool
    var color: Color = .white
    var bars = 5

    private let minH: CGFloat = 3
    private let maxH: CGFloat = 16
    private let rampUp: Double = 0.3
    private let rampDown: Double = 0.55

    /// A linear segment we interpolate (with smoothstep) to get the live envelope.
    /// Derived from the timeline clock — not from animatable state — so the value
    /// read inside the render closure is the genuinely interpolated one each frame.
    private struct Ramp { var from: CGFloat; var to: CGFloat; var since: Date; var dur: Double }
    @State private var ramp = Ramp(from: 0, to: 0, since: .distantPast, dur: 0)
    /// Whether the render loop is live. Stays true through the wind-down, then
    /// idles so a paused notch isn't repainting forever.
    @State private var ticking = false
    @State private var appeared = false

    var body: some View {
        // Swap between a live timeline and a truly static flat row instead of
        // toggling `paused` on a single TimelineView — toggling `paused` to resume
        // an `.animation` schedule is unreliable (the glitchy play/pause), and the
        // static row means a paused notch does zero repainting.
        Group {
            if ticking {
                TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
                    let now = timeline.date
                    row(energy: energy(at: now), t: now.timeIntervalSinceReferenceDate)
                }
            } else {
                row(energy: 0, t: 0)            // settled: flat, no animation
            }
        }
        // Fires on appear and on every play/pause flip; ramps the envelope and
        // keeps the loop alive long enough to render the wind-down.
        .task(id: isPlaying) {
            let now = Date()
            let cur = energy(at: now)
            let dur = appeared ? (isPlaying ? rampUp : rampDown) : 0
            ramp = Ramp(from: cur, to: isPlaying ? 1 : 0, since: now, dur: dur)
            appeared = true
            if isPlaying {
                ticking = true
            } else if dur > 0 {
                ticking = true
                try? await Task.sleep(for: .seconds(dur))
                if !isPlaying { ticking = false }   // skipped if a new flip cancelled us
            } else {
                ticking = false
            }
        }
    }

    private func row(energy: CGFloat, t: TimeInterval) -> some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<bars, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 2.5, height: barHeight(i, t: t, energy: energy))
            }
        }
        .frame(height: maxH)
    }

    /// Smoothstepped position along the current ramp → the live 0…1 envelope.
    private func energy(at now: Date) -> CGFloat {
        guard ramp.dur > 0 else { return ramp.to }
        let p = min(max(now.timeIntervalSince(ramp.since) / ramp.dur, 0), 1)
        let eased = p * p * (3 - 2 * p)
        return ramp.from + (ramp.to - ramp.from) * CGFloat(eased)
    }

    private func barHeight(_ i: Int, t: TimeInterval, energy: CGFloat) -> CGFloat {
        guard energy > 0.001 else { return minH }
        let fi = Double(i)
        // Two detuned oscillators per bar at non-integer ratios → no visible loop.
        let a = sin(t * (5.3 + fi * 1.31) + fi * 1.7)
        let b = sin(t * (8.9 + fi * 0.77) + fi * 2.6)
        var s = (a * 0.6 + b * 0.4 + 1) / 2                      // 0…1
        // A shared slow envelope so the whole bank breathes together, like volume.
        let envelope = 0.55 + 0.45 * (sin(t * 1.7) * 0.5 + 0.5)
        s *= envelope
        // Centre bars a touch taller than the edges (typical EQ silhouette).
        let shape = 1 - abs(fi - Double(bars - 1) / 2) / Double(bars)
        s *= 0.7 + 0.3 * shape
        // Scale the whole bar by the ramp so it grows in / winds down smoothly.
        let full = minH + CGFloat(s) * (maxH - minH)
        return minH + (full - minH) * energy
    }
}
