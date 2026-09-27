import AppKit
import SwiftUI

// The playful and personal parts of a notice: a person's picture, emoji
// reactions, a reply field, buttons you hold, how it arrives, and the
// floating island that rests as a circle or a pill and opens like the
// Dynamic Island.

// MARK: - Color

extension NotchNotice {
    /// The notice's own color: its tint when it has one, else its picture's
    /// or its person's, so a message from someone with a photo glows in it.
    @MainActor var accent: Color {
        if let color = person?.color { return color }
        if !Self.isPlain(tint) { return tint }
        if let image = person?.image ?? image, let color = PictureColor.of(image) { return color }
        if let person, person.image == nil { return PersonAvatar.colors(for: person.name)[0] }
        return tint
    }

    /// White or grey: no color of its own.
    @MainActor static func isPlain(_ color: Color) -> Bool {
        guard let c = NSColor(color).usingColorSpace(.deviceRGB) else { return true }
        return c.saturationComponent < 0.15
    }
}

/// A picture's average color, brightened enough to glow on black.
enum PictureColor {
    @MainActor private static var cache: [ObjectIdentifier: Color] = [:]

    @MainActor static func of(_ image: NSImage) -> Color? {
        let key = ObjectIdentifier(image)
        if let cached = cache[key] { return cached }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: 1, height: 1))
        NSGraphicsContext.restoreGraphicsState()
        guard let average = rep.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) else { return nil }
        let color = Color(hue: average.hueComponent, saturation: min(1, average.saturationComponent * 1.25),
                          brightness: max(average.brightnessComponent, 0.8))
        if cache.count > 64 { cache.removeAll() }
        cache[key] = color
        return color
    }
}

// MARK: - A person

/// Someone's picture, or their initials on their color: the one they were
/// given, else one from their name that's the same every time. Notices and
/// app chats draw people with this, so a person looks the same in both.
public struct PersonAvatar: View {
    let name: String
    let image: NSImage?
    let initials: String?
    let color: Color?
    let size: CGFloat

    public init(name: String, image: NSImage? = nil, initials: String? = nil, color: Color? = nil,
                size: CGFloat) {
        self.name = name
        self.image = image
        self.initials = initials
        self.color = color
        self.size = size
    }

    init(_ person: NotchNotice.Person, size: CGFloat) {
        self.init(name: person.name, image: person.image, color: person.color, size: size)
    }

    public var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: Self.colors(for: name, color: color),
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay {
                        Text(initials ?? Self.initials(of: name))
                            .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    /// Up to two initials.
    public static func initials(of name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    /// The gradient behind the initials: from their color, else from the
    /// name (a stable hash, not `hashValue`, which changes every launch).
    public static func colors(for name: String, color: Color? = nil) -> [Color] {
        if let color { return [color, color.mix(with: .black, by: 0.3)] }
        let hash = name.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value }
        let hue = Double(hash % 360) / 360
        return [Color(hue: hue, saturation: 0.55, brightness: 0.95),
                Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.7)]
    }
}

// MARK: - Answering

/// Emoji to answer with in one press. The picked one jumps up and the others
/// fade, then it's sent. Notices and app chats both react with this.
public struct ReactionPicker: View {
    let emojis: [String]
    let size: CGFloat
    let react: (String) -> Void
    @State private var picked: String?

    public init(emojis: [String], size: CGFloat, react: @escaping (String) -> Void) {
        self.emojis = emojis
        self.size = size
        self.react = react
    }

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(emojis, id: \.self) { emoji in
                ReactionButton(emoji: emoji, size: size, picked: picked) {
                    guard picked == nil else { return }
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.5)) { picked = emoji }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { react(emoji) }
                }
            }
        }
    }
}

private struct ReactionButton: View {
    let emoji: String
    let size: CGFloat
    let picked: String?
    let run: () -> Void
    @State private var hovering = false

    var body: some View {
        let chosen = picked == emoji
        Button(action: run) {
            Text(emoji)
                .font(.system(size: size * 0.52))
                .frame(width: size, height: size)
                .scaleEffect(chosen ? 1.6 : hovering ? 1.18 : 1)
                .offset(y: chosen ? -12 : 0)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .opacity(picked != nil && !chosen ? 0.25 : 1)
        .onHover { h in withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { hovering = h } }
    }
}

/// A reply field. Its window (the notch, or the floating panel) takes the
/// keyboard while it's typed in, and the notice stays open meanwhile.
struct NoticeReply: View {
    let placeholder: String
    let tint: Color
    let font: CGFloat
    let onTyping: (Bool) -> Void
    let send: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: font))
                .foregroundStyle(.white)
                .focused($focused)
                .onSubmit(submit)
                .onExitCommand { focused = false }
            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: font - 1, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(text.isEmpty ? Color.white.opacity(0.15) : tint, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(text.isEmpty)
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(.white.opacity(focused ? 0.12 : 0.08), in: Capsule())
        .onChange(of: focused) { _, on in onTyping(on) }
    }

    private func submit() {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return }
        // Hand the keyboard back before the notice goes (it won't be here to hear focus leave).
        focused = false
        onTyping(false)
        send(reply)
    }
}

/// A button that runs only when held: it fills while held and runs when
/// full; let go early and it empties, and a quick click shakes it.
struct NoticeHoldButton<Label: View>: View {
    let fill: Color
    let duration: Double
    let run: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var filling = false
    @State private var shakes = 0
    @State private var pressedAt: Date?

    var body: some View {
        label()
            .background(alignment: .leading) {
                GeometryReader { g in
                    Capsule().fill(fill)
                        .frame(width: filling ? g.size.width : 0)
                }
            }
            .clipShape(Capsule())
            .modifier(Shake(shakes: CGFloat(shakes)))
            .onLongPressGesture(minimumDuration: duration, maximumDistance: 30) {
                filling = false
                run()
            } onPressingChanged: { pressing in
                if pressing {
                    pressedAt = Date()
                    withAnimation(.linear(duration: duration)) { filling = true }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { filling = false }
                    if let start = pressedAt, Date().timeIntervalSince(start) < 0.25 {
                        withAnimation(.linear(duration: 0.4)) { shakes += 1 }
                    }
                    pressedAt = nil
                }
            }
            .help("Press and hold")
    }
}

/// A horizontal shake, one per step of `shakes`.
private struct Shake: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 5 * sin(shakes * .pi * 6), y: 0))
    }
}

// MARK: - Arriving

/// How a floating notice arrives: the motion for its entrance, played once
/// over its first second, then still. Drawn with a timeline that pauses when
/// it's done, so nothing runs while it just sits there.
struct NoticeEntrance: ViewModifier {
    let kind: NotchNotice.Entrance
    let tint: Color
    /// When it first showed; a notice that moved (floated off the opening
    /// notch, say) doesn't play it again.
    let firstShown: Date?
    @State private var start = Date()
    @State private var done = false

    private var length: Double {
        switch kind {
        case .knock: 1.2
        case .celebrate: 1.6
        case .ring: 2.2
        default: 0.7
        }
    }

    func body(content: Content) -> some View {
        TimelineView(.animation(paused: done)) { context in
            let pose = Self.pose(kind, at: done ? 99 : context.date.timeIntervalSince(start))
            content
                .scaleEffect(x: pose.scale, y: pose.scale * pose.stretch, anchor: .top)
                .rotationEffect(.degrees(pose.angle), anchor: .top)
                .offset(x: pose.x, y: pose.y)
        }
        .overlay {
            if kind == .celebrate && !done {
                Confetti(tint: tint, start: start)
                    .frame(width: 420, height: 260)
                    .allowsHitTesting(false)
            } else if kind == .ring && !done {
                RingHalo(tint: tint, start: start)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            guard firstShown.map({ Date().timeIntervalSince($0) < 1 }) ?? true else { done = true; return }
            start = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + length) { done = true }
        }
    }

    private struct Pose {
        var x: CGFloat = 0, y: CGFloat = 0, angle: Double = 0, scale: CGFloat = 1, stretch: CGFloat = 1
    }

    /// Where it is `t` seconds in. Nothing springs past where it's going:
    /// floating glass that wobbles or bounces reads as cheap.
    private static func pose(_ kind: NotchNotice.Entrance, at t: Double) -> Pose {
        var p = Pose()
        switch kind {
        case .automatic, .drop, .bounce, .ring:
            // The drop is the transition; a ring calls with its halo instead.
            break
        case .pop, .celebrate:
            // Grows in from smaller, easing out, no overshoot.
            if t < 0.3 {
                let k = t / 0.3
                p.scale = 0.7 + 0.3 * (1 - pow(1 - k, 3))
            }
        case .shake:
            if t < 0.6 { p.x = 9 * sin(2 * .pi * 6 * t) * (1 - t / 0.6) }
        case .knock:
            // Two taps, a pause, two taps: knock-knock.
            for tap in [0.05, 0.22, 0.62, 0.79] where t >= tap && t < tap + 0.14 {
                let k = sin((t - tap) / 0.14 * .pi)
                p.y = -3 * k
                p.scale = 1 - 0.035 * k
            }
        }
        return p
    }
}

/// A call's ring: soft halos spreading out from the glass and fading, three
/// of them, like a phone ringing. The glass itself stays still.
private struct RingHalo: View {
    let tint: Color
    let start: Date

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSince(start)
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let k = (t - Double(i) * 0.55) / 1.1
                    if k > 0 && k < 1 {
                        Capsule()
                            .stroke(tint.opacity(0.7 * (1 - k)), lineWidth: 2)
                            .padding(-CGFloat(k) * 12)
                    }
                }
            }
        }
    }
}

/// A burst of confetti from the card, falling away over a second and a half.
private struct Confetti: View {
    let tint: Color
    let start: Date

    private static let palette: [Color] = [.pink, .yellow, .mint, .cyan, .orange, .purple]
    private static let pieces: [(angle: Double, speed: Double, spin: Double, size: Double, round: Bool)] =
        (0..<28).map { i in
            let r = { (n: Int) in Double((i &* 2654435761 &+ n &* 40503) % 1000) / 1000 }
            return (angle: -.pi / 2 + (r(1) - 0.5) * .pi * 1.3, speed: 150 + r(2) * 170,
                    spin: (r(3) - 0.5) * 14, size: 4 + r(4) * 4, round: r(5) > 0.6)
        }

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { g, size in
                let t = context.date.timeIntervalSince(start)
                guard t < 1.6 else { return }
                let origin = CGPoint(x: size.width / 2, y: size.height / 2)
                for (i, piece) in Self.pieces.enumerated() {
                    let x = origin.x + cos(piece.angle) * piece.speed * t
                    let y = origin.y + sin(piece.angle) * piece.speed * t + 260 * t * t
                    var ctx = g
                    ctx.opacity = max(0, 1 - t / 1.6)
                    ctx.translateBy(x: x, y: y)
                    ctx.rotate(by: .radians(piece.spin * t))
                    let rect = CGRect(x: -piece.size / 2, y: -piece.size / 2, width: piece.size,
                                      height: piece.round ? piece.size : piece.size * 1.8)
                    let color = i % 4 == 0 ? tint : Self.palette[i % Self.palette.count]
                    ctx.fill(piece.round ? Path(ellipseIn: rect) : Path(roundedRect: rect, cornerRadius: 1),
                             with: .color(color))
                }
            }
        }
    }
}

// MARK: - The floating island

/// A floating notice: at rest a circle (a ring, an emoji, a short value) or a
/// pill (its one line). Pointed at, a pill opens into the full card and a
/// circle grows only into a small capsule with a button or two, morphing like
/// the Dynamic Island; anything bigger is a pill's job. Both states are laid
/// out at their own size and the glass grows between them, so nothing is
/// squeezed on the way.
struct IslandNotice: View {
    let notice: NotchNotice
    let peeking: Bool
    let metrics: NoticeMetrics
    /// The pill's width at rest (nil: its natural width).
    let restWidth: CGFloat?
    /// The card's width open.
    let openWidth: CGFloat
    let firstShown: Date?
    let onAction: (String) -> Void
    let onClose: () -> Void
    let onTyping: (Bool) -> Void

    var body: some View {
        let m = metrics
        let circle = notice.restsAsCircle
        let accent = notice.accent
        let corner = circle ? m.circleSize / 2 : peeking ? m.floatingPeekCorner : m.floatingCorner
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        SwapLayout(showing: peeking ? 1 : 0, anchor: .top) {
            Group {
                if circle {
                    IslandDot(notice: notice, accent: accent, size: m.circleSize, metrics: m)
                } else {
                    NoticeCard(notice: notice, peeking: false, metrics: m, floating: true, width: restWidth,
                               onAction: onAction, onClose: onClose)
                }
            }
            .opacity(peeking ? 0 : 1)
            .blur(radius: peeking ? 3 : 0)
            .allowsHitTesting(!peeking)
            .animation(.easeOut(duration: 0.18), value: peeking)
            Group {
                if circle {
                    IslandDotOpen(notice: notice, accent: accent, metrics: m, onAction: onAction, onClose: onClose)
                } else {
                    NoticeCard(notice: notice, peeking: true, metrics: m, floating: true, openWidth: openWidth,
                               canType: true, onTyping: onTyping, onAction: onAction, onClose: onClose)
                }
            }
                .opacity(peeking ? 1 : 0)
                .blur(radius: peeking ? 0 : 3)
                .allowsHitTesting(peeking)
                .animation(.easeOut(duration: 0.22).delay(peeking ? 0.06 : 0), value: peeking)
        }
        .background {
            // Its own color, rising from the top edge.
            if !NotchNotice.isPlain(accent) || notice.person != nil || notice.image != nil {
                LinearGradient(colors: [accent.opacity(peeking ? 0.26 : 0.34), accent.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .clipShape(shape)
        .glassEffect(.regular.tint(.black.opacity(0.35)), in: shape)
        // Opens and closes smoothly, without springing past its size.
        .animation(.smooth(duration: 0.32), value: peeking)
        .modifier(NoticeEntrance(kind: notice.arrival, tint: accent, firstShown: firstShown))
    }
}

/// A circle pointed at: about two circles wide, never a card. Two buttons
/// take it whole (icons); otherwise its circle stays and one button sits
/// beside it, or × when it has none.
private struct IslandDotOpen: View {
    let notice: NotchNotice
    let accent: Color
    let metrics: NoticeMetrics
    let onAction: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        let size = metrics.circleSize
        HStack(spacing: 3) {
            if notice.actions.count >= 2 {
                ForEach(notice.actions.prefix(2)) { action in
                    IslandButton(action: action, accent: accent, size: size, holdDuration: metrics.holdDuration) {
                        onAction(action.id)
                    }
                }
            } else {
                IslandDot(notice: notice, accent: accent, size: size - 4, metrics: metrics)
                if let action = notice.actions.first {
                    IslandButton(action: action, accent: accent, size: size, holdDuration: metrics.holdDuration) {
                        onAction(action.id)
                    }
                } else {
                    NoticeCloseButton(size: size - 8, action: onClose)
                        .frame(width: size - 4, height: size - 4)
                }
            }
        }
        .padding(.horizontal, 2)
        .frame(height: size)
        .frame(maxWidth: size * 3.4)
        .fixedSize()
    }
}

/// A button in a circle's capsule: its icon in a round, or its title cut short.
private struct IslandButton: View {
    let action: NotchNotice.Action
    let accent: Color
    let size: CGFloat
    let holdDuration: Double
    let run: () -> Void

    private var fill: Color {
        switch action.role {
        case .normal: .white.opacity(0.18)
        case .primary: accent.opacity(0.9)
        case .destructive: .red.opacity(0.85)
        }
    }

    var body: some View {
        let label = Group {
            if let icon = action.icon {
                Image(systemName: icon).font(.system(size: size * 0.36, weight: .bold))
            } else {
                Text(action.title)
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: size * 2)
            }
        }
        .foregroundStyle(.white)
        .frame(minWidth: size - 6, minHeight: size - 6, maxHeight: size - 6)
        .padding(.horizontal, action.icon == nil ? 9 : 0)
        .contentShape(Capsule())
        if action.hold {
            NoticeHoldButton(fill: fill, duration: holdDuration, run: run) {
                label.background(.white.opacity(0.12), in: Capsule())
            }
        } else {
            Button(action: run) { label.background(fill, in: Capsule()) }
                .buttonStyle(.plain)
                .help(action.title)
        }
    }
}

/// A floating circle's inside: a person, a ring, an emoji, a short value or
/// the icon, in that order of preference.
private struct IslandDot: View {
    let notice: NotchNotice
    let accent: Color
    let size: CGFloat
    let metrics: NoticeMetrics

    var body: some View {
        ZStack {
            if let person = notice.person {
                PersonAvatar(person, size: size - 6)
            } else if let progress = notice.progress {
                NoticeRing(value: progress, tint: accent, size: size - 9)
                if let emoji = notice.emoji {
                    Text(emoji).font(.system(size: size * 0.32))
                } else {
                    Image(systemName: notice.icon)
                        .font(.system(size: size * 0.28, weight: .bold))
                        .foregroundStyle(accent)
                }
            } else if let emoji = notice.emoji {
                Text(emoji).font(.system(size: size * 0.5))
            } else if let hero = notice.hero {
                Text(hero)
                    .font(.system(size: hero.count <= 2 ? size * 0.42 : size * 0.3, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(NotchNotice.isPlain(accent) ? .white : accent)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 3)
            } else {
                NoticeIcon(notice: notice, size: size * 0.4)
            }
        }
        .frame(width: size, height: size)
    }
}

/// The floating row under the notch: a pill on the left, then circles,
/// together as wide as the notch (when they match it) and centered under it.
/// A pill pointed at opens in the middle, over the others; a circle grows
/// outward, away from the middle, so its neighbours stay put.
struct FloatingRow: Layout {
    /// Each one's width at rest, in order.
    let restWidths: [CGFloat]
    let gap: CGFloat
    /// The one that's open, and whether it opens in the middle (a pill's card).
    let open: Int?
    let openCentered: Bool

    private var total: CGFloat {
        restWidths.reduce(0, +) + gap * CGFloat(max(restWidths.count - 1, 0))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: proposal.width ?? total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.midX - total / 2
        for (i, view) in subviews.enumerated() {
            let w = i < restWidths.count ? restWidths[i] : 0
            let size = view.sizeThatFits(.unspecified)
            let middle = x + w / 2
            let fit = ProposedViewSize(size)
            if i == open && openCentered {
                view.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top, proposal: fit)
            } else if i == open && abs(middle - bounds.midX) > 1 {
                if middle < bounds.midX {
                    view.place(at: CGPoint(x: x + w, y: bounds.minY), anchor: .topTrailing, proposal: fit)
                } else {
                    view.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: fit)
                }
            } else {
                view.place(at: CGPoint(x: middle, y: bounds.minY), anchor: .top, proposal: fit)
            }
            x += w + gap
        }
    }
}

/// Several states of one view laid over each other, each at its own natural
/// width (up to `max`). It's as big as the one showing, so switching grows or
/// shrinks it toward the other, from `anchor`; neither is ever squeezed, so
/// text never turns into "…" on the way, and the bigger one is clipped while
/// it grows into view. The ears use it to widen only while pointed at; the
/// floating island to open from its circle or pill.
struct SwapLayout: Layout {
    enum Anchor { case leading, trailing, top }
    let showing: Int
    var max: CGFloat = .infinity
    let anchor: Anchor

    private func size(_ view: LayoutSubview) -> CGSize {
        let ideal = view.sizeThatFits(.unspecified)
        return ideal.width <= max ? ideal : view.sizeThatFits(ProposedViewSize(width: max, height: nil))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map(size)
        guard !sizes.isEmpty else { return .zero }
        let shown = sizes[Swift.min(showing, sizes.count - 1)]
        // Beside the notch both states share the line's height; floating, the
        // open card is taller than the pill and the island grows down.
        return anchor == .top ? shown : CGSize(width: shown.width, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews {
            let s = size(view)
            switch anchor {
            case .leading:
                view.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(s))
            case .trailing:
                view.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(s))
            case .top:
                view.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top, proposal: ProposedViewSize(s))
            }
        }
    }
}
