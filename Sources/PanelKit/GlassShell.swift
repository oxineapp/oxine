import SwiftUI

/// The single Liquid Glass surface the whole panel sits on. One uniform tint
/// driven by `tint` — no stacked materials, no separate dark slab.
public struct GlassShell: View {
    public let tint: Double
    public init(tint: Double) { self.tint = tint }
    public var body: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color(red: 0.05, green: 0.05, blue: 0.07).opacity(0.06 + tint * 0.46))
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// The bottom-trailing resize affordance: two stacked corner-following fins.
public struct ResizeGrip: View {
    public init() {}
    public var body: some View {
        ZStack {
            // Outer curve following the corner radius.
            grip(inset: 0, length: 15)
                .stroke(.white.opacity(0.45), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            // Inner shorter curve for the fin look.
            grip(inset: 5, length: 9)
                .stroke(.white.opacity(0.30), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .frame(width: 18, height: 18)
        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
    }

    private func grip(inset: CGFloat, length: CGFloat) -> Path {
        Path { p in
            let s: CGFloat = 18
            p.move(to: CGPoint(x: s - inset, y: s - inset - length))
            p.addQuadCurve(
                to: CGPoint(x: s - inset - length, y: s - inset),
                control: CGPoint(x: s - inset, y: s - inset)
            )
        }
    }
}

public extension View {
    /// Softly fades content under the chrome at top and bottom instead of
    /// cutting it with divider lines.
    func scrollEdgeFade(top: CGFloat = 14, bottom: CGFloat = 16) -> some View {
        mask(
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: top)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: bottom)
            }
        )
    }
}
