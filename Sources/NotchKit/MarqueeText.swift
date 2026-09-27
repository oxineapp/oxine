import SwiftUI

/// A single line of text that scrolls only when it doesn't fit — the Apple Now
/// Playing behaviour: hold at the start, ease across to reveal the end, hold,
/// ease back, repeat. Short text just sits still, left-aligned.
///
/// Critically it is **width-bounded**: it fills the width offered by its parent
/// and never grows it. (An earlier version used `.fixedSize()` on the visible
/// text, which let a long title drive the whole card wider — a YouTube title
/// would balloon the notch.) The text is measured in a non-layout background and
/// rendered clamped to the available width, clipped, with a soft fade on each
/// edge that has more text beyond it (none on the left at the start, none on
/// the right at the end).
struct MarqueeText: View {
    let text: String
    var font: Font = .system(size: 15, weight: .semibold)
    var color: Color = .white
    /// Fixed line height for the row (the visible text is clamped to the parent's
    /// width, so the row needs an explicit height rather than the text's own).
    var height: CGFloat = 20
    /// How long to dwell at each end before sliding.
    var pause: Double = 1.8
    /// Scroll speed in points per second.
    var speed: Double = 28
    /// Width of the edge fade while scrolling.
    var fade: CGFloat = 12

    @State private var textWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let distance = max(textWidth - geo.size.width, 0)
            let scrolling = distance > 1
            Text(text)
                .font(font)
                .foregroundColor(color)
                .lineLimit(1)
                .fixedSize()                        // full intrinsic width, measured below
                .background(
                    GeometryReader { t in
                        Color.clear
                            .onAppear { textWidth = t.size.width }
                            .onChange(of: text) { _, _ in textWidth = t.size.width }
                            .onChange(of: t.size.width) { _, w in textWidth = w }
                    }
                )
                .modifier(MarqueeMotion(distance: distance, active: scrolling, speed: speed,
                                        pause: pause, fade: fade, size: geo.size))
        }
        .frame(height: height)
    }
}

/// Drives the back-and-forth offset. `PhaseAnimator` cycles `0 → -distance → 0 …`;
/// the per-transition `.delay(pause)` is what makes it dwell at each end. It
/// also clamps the text to the available width and clips it (what stops a long
/// title from widening the card), and fades only the edge that hides text:
/// the fades animate with the scroll, so the ends read clean.
private struct MarqueeMotion: ViewModifier {
    let distance: CGFloat
    let active: Bool
    let speed: Double
    let pause: Double
    let fade: CGFloat
    let size: CGSize

    func body(content: Content) -> some View {
        if active {
            content.phaseAnimator([CGFloat(0), -distance]) { view, offset in
                let atStart = offset == 0
                clamped(view.offset(x: offset))
                    .mask(edgeFade(leading: atStart ? 0 : 1, trailing: atStart ? 1 : 0))
            } animation: { _ in
                .easeInOut(duration: Double(distance) / speed).delay(pause)
            }
        } else {
            clamped(content)
        }
    }

    private func clamped<V: View>(_ view: V) -> some View {
        view
            .frame(width: size.width, height: size.height, alignment: .leading)
            .clipped()
    }

    /// 1 = that edge fades out, 0 = it's solid. Opacity (not the gradient) is
    /// what changes, so it animates.
    private func edgeFade(leading: Double, trailing: Double) -> some View {
        HStack(spacing: 0) {
            ZStack {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                Color.black.opacity(1 - leading)
            }
            .frame(width: fade)
            Color.black
            ZStack {
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                Color.black.opacity(1 - trailing)
            }
            .frame(width: fade)
        }
    }
}
