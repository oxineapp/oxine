import SwiftUI

/// What the overlay draws: the current line, its caption, the look, and whether
/// it should be on screen at all. The controller writes; the view animates.
@MainActor
final class LyricsOverlayModel: ObservableObject {
    @Published private(set) var line: String?
    @Published private(set) var caption = ""
    @Published private(set) var settings = LyricsSettings()
    /// Step aside (notch expanded) — the pill slides up and fades, then returns.
    @Published private(set) var hidden = true
    /// Monotonic per *line change*, so identical consecutive lines (a repeated
    /// chorus) still get their entrance.
    @Published private(set) var lineID = 0
    /// The cursor is over the pill: it fades back so whatever's under it shows.
    @Published private(set) var hovered = false
    /// The pill's frame in window coordinates (top-left origin), reported by
    /// the view so the controller can hit-test the cursor against a
    /// click-through panel.
    var pillFrame: CGRect = .zero

    func setHovered(_ on: Bool) {
        guard on != hovered else { return }
        withAnimation(.easeInOut(duration: 0.25)) { hovered = on }
    }

    func update(line: String?, caption: String, settings: LyricsSettings, hidden: Bool, animate: Bool) {
        let changed = line != self.line
        let apply = {
            if changed { self.lineID &+= 1 }
            self.line = line
            self.caption = caption
            self.settings = settings
            self.hidden = hidden
        }
        if animate {
            // A new line resizes the pill: snap the width (no diagonal drift) and
            // let only the text run its entrance; everything else springs.
            if changed {
                withAnimation(nil) {
                    self.lineID &+= 1
                    self.line = line
                    self.caption = caption
                }
            }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                self.caption = caption
                self.settings = settings
                self.hidden = hidden
            }
        } else {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { apply() }
        }
    }
}

/// The overlay's content: a Liquid Glass pill hugging the notch, sized to the
/// text — one or two lines, optionally the artist and song underneath, in
/// seven size steps (`LyricsSettings.steps`). New lines rise up through the
/// pill; it eases away in gaps and while the notch is open.
struct LyricsOverlayView: View {
    @ObservedObject var model: LyricsOverlayModel

    /// Height of the panel band the pill positions itself in.
    static func bandHeight(for s: LyricsSettings) -> CGFloat {
        CGFloat(s.metrics.text * 2 + s.metrics.caption + s.metrics.vPad * 2) + 40
    }

    private var s: LyricsSettings { model.settings }
    private var m: LyricsSettings.Metrics { model.settings.metrics }
    private var showing: Bool { model.line != nil && !model.hidden }
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var body: some View {
        ZStack(alignment: .top) {
            if showing {
                pill
                    .opacity(model.hovered ? 0.28 : 1)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.pillFrame = $0 }
                    .padding(.top, s.gap)
                    .transition(pillTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: showing)
    }

    private var pill: some View {
        VStack(spacing: 3) {
            lineText
                .font(font)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            if s.showTrack, !model.caption.isEmpty {
                Text(model.caption)
                    .font(.system(size: m.caption, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, m.hPad)
        .padding(.vertical, m.vPad)
        .frame(maxWidth: m.maxWidth)
        .fixedSize(horizontal: true, vertical: false)
        // The pill masks the line's vertical entrance/exit.
        .clipShape(RoundedRectangle(cornerRadius: m.radius, style: .continuous))
        .glassEffect(.regular.tint(.black.opacity(0.45)),
                     in: RoundedRectangle(cornerRadius: m.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: m.radius, style: .continuous)
            .strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
    }

    /// The line itself. A hidden copy of the *current* line sizes the pill, so
    /// the width snaps to the new text; the visible copies live in an overlay
    /// and only ever move vertically through the change.
    private var lineText: some View {
        Text(model.line ?? "")
            .hidden()
            .overlay {
                ZStack {
                    Text(model.line ?? "")
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .id(model.lineID)
                        .transition(lineTransition)
                }
                .animation(lineAnimation, value: model.lineID)
            }
    }

    private var font: Font {
        let size = m.text
        let weight: Font.Weight = s.size < 3 ? .medium : .semibold
        switch s.fontFamily {
        case .system: return .system(size: size, weight: weight)
        case .rounded: return .system(size: size, weight: weight, design: .rounded)
        case .serif: return .system(size: size, weight: .medium, design: .serif)
        case .monospaced: return .system(size: size, weight: .medium, design: .monospaced)
        }
    }

    private var lineAnimation: Animation? {
        guard s.appearance != .none, !reduceMotion else { return nil }
        return .spring(duration: s.animationDuration, bounce: s.appearance == .pop ? 0.25 : 0.1)
    }

    private var lineTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        switch s.appearance {
        case .none: return .identity
        case .fade: return .opacity
        case .slide: return .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .move(edge: .top).combined(with: .opacity))
        case .pop: return .scale(scale: 0.88).combined(with: .opacity)
        }
    }

    /// Whole-pill entrance/exit: out of the notch and back into it.
    private var pillTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.92, anchor: .top))
    }
}
