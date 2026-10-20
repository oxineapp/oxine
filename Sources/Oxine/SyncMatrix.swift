import SwiftUI

/// A "working" indicator: a 5×4 grid of cells whose sizes flicker
/// fluidly-but-abruptly at semi-random — reads like work is happening. When the
/// work finishes the cells collapse and a bare checkmark strokes itself in (no
/// circular outline).
///
/// Made for the justtype sync in the Notes tab. That integration is off for
/// now; this is kept to reuse elsewhere.
struct SyncMatrix: View {
    var color: Color
    var isDone: Bool

    private let cols = 5
    private let rows = 4
    private let cell: CGFloat = 2.2     // dot size at full scale
    private let gap: CGFloat = 1.8

    @State private var scales: [CGFloat]
    @State private var checkProgress: CGFloat = 0
    private let timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    init(color: Color, isDone: Bool) {
        self.color = color
        self.isDone = isDone
        // Start collapsed so the grid grows in fluidly rather than popping.
        _scales = State(initialValue: Array(repeating: 0, count: 20))
    }

    private var gridWidth: CGFloat { CGFloat(cols) * cell + CGFloat(cols - 1) * gap }
    private var gridHeight: CGFloat { CGFloat(rows) * cell + CGFloat(rows - 1) * gap }

    var body: some View {
        ZStack {
            // Dot matrix — fades out as the check draws in.
            VStack(spacing: gap) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: gap) {
                        ForEach(0..<cols, id: \.self) { c in
                            let i = r * cols + c
                            RoundedRectangle(cornerRadius: 0.7, style: .continuous)
                                .fill(color)
                                .frame(width: cell, height: cell)
                                .scaleEffect(scales[i])
                                .opacity(0.3 + 0.7 * scales[i])
                        }
                    }
                }
            }
            .opacity(1 - checkProgress)

            // Bare checkmark, stroked in on completion.
            Checkmark()
                .trim(from: 0, to: checkProgress)
                .stroke(color, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                .frame(width: gridWidth, height: gridHeight)
        }
        .frame(width: gridWidth, height: gridHeight)
        .onAppear {
            guard !isDone else { return }
            // Fluid grow-in from the collapsed initial state.
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                for i in scales.indices { scales[i] = CGFloat.random(in: 0.3...1.0) }
            }
        }
        .onReceive(timer) { _ in
            guard !isDone else { return }
            // Re-roll most cells each tick; the eased spring gives the
            // "fluid but abruptish" computing feel.
            withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
                for i in scales.indices where Int.random(in: 0..<3) != 0 {
                    scales[i] = CGFloat.random(in: 0.25...1.0)
                }
            }
        }
        .onChange(of: isDone) { _, done in
            if done {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.72)) {
                    checkProgress = 1
                    for i in scales.indices { scales[i] = 0 }
                }
            } else {
                checkProgress = 0
                for i in scales.indices { scales[i] = CGFloat.random(in: 0.3...1.0) }
            }
        }
    }
}

/// Two-segment checkmark with no enclosing circle. Drawn within its frame so it
/// can be `.trim`-animated.
struct Checkmark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + rect.width * 0.10, y: rect.minY + rect.height * 0.55))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.82))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.92, y: rect.minY + rect.height * 0.18))
        return p
    }
}
