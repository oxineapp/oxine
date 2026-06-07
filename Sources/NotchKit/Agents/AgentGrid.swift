import SwiftUI

/// The pixel-matrix agent glyph: a 5×5 grid tinted by the tool's colour (orange
/// Claude, blue Codex, white opencode). The shape and motion say the status:
///   • working — the FULL grid lit, with a sonar ripple pulsing from the centre
///     outward (the dead-centre cell stays hollow, like the reference).
///   • needs   — a pixel "?" pointer, gently pulsing to draw the eye.
///   • done    — a pixel checkmark.
///   • idle    — faint corners.
/// Unlit cells stay dimly lit so the matrix always reads as a little display.
struct AgentGrid: View {
    let state: AgentState
    var cell: CGFloat = 3
    var gap: CGFloat = 1

    private static let n = 5
    private static let mid = 2          // centre index of a 5×5

    var body: some View {
        let color = state.tool.color
        TimelineView(.animation(paused: !animates)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            VStack(spacing: gap) {
                ForEach(0..<Self.n, id: \.self) { r in
                    HStack(spacing: gap) {
                        ForEach(0..<Self.n, id: \.self) { c in
                            RoundedRectangle(cornerRadius: 0.6, style: .continuous)
                                .fill(color.opacity(opacity(r, c, t)))
                                .frame(width: cell, height: cell)
                        }
                    }
                }
            }
        }
        .help("\(state.tool.rawValue.capitalized): \(state.status.rawValue)")
    }

    private var animates: Bool { state.status == .working || state.status == .needs }

    /// Per-cell opacity for the current status and time.
    private func opacity(_ r: Int, _ c: Int, _ t: TimeInterval) -> Double {
        switch state.status {
        case .working:
            // A round ripple expanding from the centre: use Euclidean distance (so
            // rings are circular, not square) and a sharpened crest so a bright ring
            // travels outward over a darker field — a real ripple, not a shimmer.
            let dr = Double(r - Self.mid), dc = Double(c - Self.mid)
            let dist = (dr * dr + dc * dc).squareRoot()            // 0…2.83
            let wave = 0.5 + 0.5 * sin(t * 4.4 - dist * 2.1)       // travels outward
            let crest = pow(wave, 2.4)                             // sharpen into a ring
            return 0.16 + 0.84 * crest
        case .needs:
            let pulse = 0.5 + 0.5 * abs(sin(t * 2.6))
            return Self.question[r][c] == 1 ? pulse : 0.10
        case .done:
            return Self.check[r][c] == 1 ? 1.0 : 0.10
        case .idle:
            return Self.corners[r][c] == 1 ? 0.4 : 0.08
        }
    }

    // MARK: bitmaps

    /// A pixel "?" pointer (matches the reference question glyph).
    private static let question: [[Int]] = [
        [0,1,1,1,0],
        [0,0,0,1,0],
        [0,0,1,1,0],
        [0,0,1,0,0],
        [0,0,1,0,0],
    ]

    /// A pixel checkmark.
    private static let check: [[Int]] = [
        [0,0,0,0,1],
        [0,0,0,1,0],
        [1,0,1,0,0],
        [0,1,0,0,0],
        [0,0,0,0,0],
    ]

    private static let corners: [[Int]] = [
        [1,0,0,0,1],
        [0,0,0,0,0],
        [0,0,0,0,0],
        [0,0,0,0,0],
        [1,0,0,0,1],
    ]
}
