import AppKit
import SwiftUI

/// One notice under the notch or floating, in either state: the short version
/// (a single line) or the peek, in its look: standard (title, detail,
/// progress, buttons), a message from a person, one big value, or a big
/// picture. The same view draws inside the notch and floating; `floating`
/// only evens out the padding, since in the notch the ears sit right above it.
struct NoticeCard: View {
    let notice: NotchNotice
    let peeking: Bool
    let metrics: NoticeMetrics
    var floating = false
    /// Fills this width (a row docked in the open notch, or a floating pill
    /// matching the notch), its content centered and its glow edge to edge.
    var width: CGFloat?
    /// The peek's width floating (nil: `peekWidth`).
    var openWidth: CGFloat?
    /// Show the reply field: wherever the window can take the keyboard (the
    /// notch and the floating panel both can), and not in the list.
    var canType = false
    var onTyping: (Bool) -> Void = { _ in }
    let onAction: (String) -> Void
    let onClose: () -> Void
    /// The closed notch's content width, when drawn inside it.
    @Environment(\.notchCompactWidth) private var notchWidth
    /// The icon and title glide between the two states instead of fading.
    @Namespace private var morph

    /// The width it opened at, held while it's open: if an ear changes or
    /// goes away meanwhile, the text mustn't reflow under the reader's eyes.
    @State private var lockedPeekWidth: CGFloat?

    private var currentPeekWidth: CGFloat {
        if floating { return openWidth ?? metrics.peekWidth }
        guard metrics.peekMatchesNotch, notchWidth > 0 else { return metrics.peekWidth }
        return max(notchWidth, metrics.peekMinWidth)
    }
    private var peekWidth: CGFloat { lockedPeekWidth ?? currentPeekWidth }

    var body: some View {
        ZStack(alignment: .top) {
            if peeking {
                peek.transition(.opacity)
            } else {
                short.transition(.opacity)
            }
        }
        .frame(width: width)
        .background { if notice.emphasis == .urgent { UrgentGlow(tint: notice.tint, bleed: floating ? 0 : 240) } }
        .onChange(of: peeking, initial: true) { _, open in
            lockedPeekWidth = open ? currentPeekWidth : nil
        }
    }

    // MARK: short

    private var short: some View {
        let accent = notice.accent
        return VStack(spacing: 5) {
            HStack(spacing: 6) {
                NoticeIcon(notice: notice, size: metrics.belowIcon)
                    .glides("icon", notice, in: morph)
                Text(notice.title)
                    .font(.system(size: metrics.belowFont, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .layoutPriority(1)
                    .glides("title", notice, in: morph)
                if notice.look == .hero, let hero = notice.hero {
                    Text(hero)
                        .font(.system(size: metrics.belowFont, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(NotchNotice.isPlain(accent) ? .white : accent)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                } else if notice.look == .message, let words = notice.detail {
                    // A message shows its first words, like a phone's banner.
                    Text(words)
                        .font(.system(size: metrics.belowFont, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                } else if let subtitle = notice.subtitle {
                    Text(subtitle)
                        .font(.system(size: metrics.belowFont, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
                NoticeCount(notice: notice, font: metrics.belowFont - 2)
            }
            if let progress = notice.progress {
                NoticeProgressBar(value: progress, tint: accent, height: 3)
            }
        }
        .padding(.horizontal, metrics.belowHorizontalPadding)
        .padding(.top, floating ? 8 : 1)
        .padding(.bottom, floating ? 8 : metrics.belowBottomPadding)
        .frame(maxWidth: width.map { $0 } ?? metrics.belowMaxWidth)
    }

    // MARK: peek

    private var peek: some View {
        Group {
            switch notice.look {
            case .standard: standard
            case .message: message
            case .hero: hero
            case .media: media
            }
        }
        .padding(.horizontal, metrics.peekPadding)
        .padding(.top, floating ? 12 : 6)
        .padding(.bottom, 12)
        .frame(width: peekWidth, alignment: .leading)
    }

    private var standard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                NoticeIcon(notice: notice, size: metrics.peekTitleFont)
                    .frame(width: metrics.peekIconBadge, height: metrics.peekIconBadge)
                    .background(badgeFill, in: Circle())
                    .glides("icon", notice, in: morph)
                titles(lines: 2)
                Spacer(minLength: 4)
                NoticeCloseButton(size: 20, action: onClose)
            }
            detailText()
            progressRow
            answers
        }
    }

    /// From a person: their picture, their words in a bubble, reactions, a reply.
    private var message: some View {
        let accent = notice.accent
        let person = notice.person ?? NotchNotice.Person(name: notice.title)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                PersonAvatar(person, size: metrics.avatarSize)
                    .glides("icon", notice, in: morph)
                VStack(alignment: .leading, spacing: 1) {
                    Text(person.name)
                        .font(.system(size: metrics.peekTitleFont, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .glides("title", notice, in: morph)
                    if let subtitle = notice.subtitle {
                        Text(subtitle)
                            .font(.system(size: metrics.peekDetailFont - 1, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                NoticeCount(notice: notice, font: metrics.peekDetailFont - 1)
                NoticeCloseButton(size: 20, action: onClose)
            }
            if let words = notice.detail {
                Text(words)
                    .font(.system(size: metrics.peekDetailFont + 0.5))
                    .foregroundStyle(.white.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(accent.opacity(0.24),
                                in: UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 14,
                                                           bottomTrailingRadius: 14, topTrailingRadius: 14,
                                                           style: .continuous))
            }
            progressRow
            answers
        }
    }

    /// One big value under the title.
    private var hero: some View {
        let accent = notice.accent
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                NoticeIcon(notice: notice, size: metrics.peekDetailFont)
                    .glides("icon", notice, in: morph)
                Text(notice.title)
                    .font(.system(size: metrics.peekDetailFont, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .glides("title", notice, in: morph)
                if let subtitle = notice.subtitle {
                    Text(subtitle)
                        .font(.system(size: metrics.peekDetailFont, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                NoticeCloseButton(size: 20, action: onClose)
            }
            if let value = notice.hero {
                Text(value)
                    .font(.system(size: metrics.heroFont, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(NotchNotice.isPlain(accent) ? .white : accent)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            detailText()
            VStack(alignment: .leading, spacing: 8) {
                progressRow
                answers
            }
            .padding(.top, 4)
        }
    }

    /// A big picture beside the words.
    private var media: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 11) {
                picture
                    .frame(width: metrics.mediaImage, height: metrics.mediaImage)
                    .clipShape(RoundedRectangle(cornerRadius: metrics.mediaImage * 0.2, style: .continuous))
                    .shadow(color: notice.accent.opacity(0.45), radius: 10, y: 3)
                    .glides("icon", notice, in: morph)
                VStack(alignment: .leading, spacing: 3) {
                    titles(lines: 2)
                    detailText(lines: 3)
                }
                Spacer(minLength: 4)
                NoticeCloseButton(size: 20, action: onClose)
            }
            progressRow
            answers
        }
    }

    @ViewBuilder private var picture: some View {
        if let image = notice.person?.image ?? notice.image {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else if let id = notice.appIcon, let icon = NoticeIcon.appIcon(id) {
            Image(nsImage: icon).resizable()
        } else {
            ZStack {
                notice.accent.opacity(0.25)
                if let emoji = notice.emoji {
                    Text(emoji).font(.system(size: metrics.mediaImage * 0.5))
                } else {
                    Image(systemName: notice.icon)
                        .font(.system(size: metrics.mediaImage * 0.38, weight: .semibold))
                        .foregroundStyle(notice.accent)
                }
            }
        }
    }

    // MARK: parts

    private var badgeFill: Color {
        notice.image == nil && notice.appIcon == nil && notice.person == nil && notice.emoji == nil
            ? notice.accent.opacity(0.18) : .clear
    }

    private func titles(lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(notice.title)
                .font(.system(size: metrics.peekTitleFont, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(lines)
                .glides("title", notice, in: morph)
            if let subtitle = notice.subtitle {
                Text(subtitle)
                    .font(.system(size: metrics.peekDetailFont - 1, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder private func detailText(lines: Int? = nil) -> some View {
        if let detail = notice.detail {
            Text(detail)
                .font(.system(size: metrics.peekDetailFont))
                .foregroundStyle(.white.opacity(0.68))
                .lineLimit(lines)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var progressRow: some View {
        if let progress = notice.progress {
            HStack(spacing: 8) {
                NoticeProgressBar(value: progress, tint: notice.accent, height: 4)
                NoticePercent(progress: progress, font: metrics.peekDetailFont - 1)
            }
        }
    }

    /// Reactions, the reply field and the buttons, whichever it has.
    @ViewBuilder private var answers: some View {
        let accent = notice.accent
        if !notice.reactions.isEmpty {
            ReactionPicker(emojis: notice.reactions, size: metrics.reactionSize) { onAction("react:" + $0) }
        }
        if canType, let placeholder = notice.reply {
            NoticeReply(placeholder: placeholder, tint: accent, font: metrics.peekDetailFont,
                        onTyping: onTyping) { onAction("reply:" + $0) }
        }
        if !notice.actions.isEmpty {
            HStack(spacing: 6) {
                ForEach(notice.actions) { action in
                    NoticeButton(action: action, tint: accent, font: metrics.peekDetailFont,
                                 holdDuration: metrics.holdDuration) {
                        onAction(action.id)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

extension View {
    /// Ties this part of a notice to the same part in its other state, so it
    /// glides between the two. Position only: each keeps its own size, so a
    /// title is never squeezed to "…" partway through.
    func glides(_ part: String, _ notice: NotchNotice, in namespace: Namespace.ID) -> some View {
        matchedGeometryEffect(id: "\(part)-\(notice.id)", in: namespace, properties: .position)
    }

    /// Tells the notices where this notice is drawn in the notch window, so
    /// the presenter can hand it the pointer.
    func reportsNoticeFrame(_ id: UUID, to notices: NotchNotices) -> some View {
        background(GeometryReader { g in
            Color.clear.onChange(of: NoticeFrame(id: id, rect: g.frame(in: .global)), initial: true) { _, frame in
                notices.reportFrame(frame.id, frame.rect)
            }
        })
    }
}

private struct NoticeFrame: Equatable {
    let id: UUID
    let rect: CGRect
}

/// The notice's picture: a person, an image, an app's icon, an emoji, or its
/// How many messages are stacked here (this one and the ones under it), in
/// the notice's color. Nothing when it's alone.
struct NoticeCount: View {
    let notice: NotchNotice
    let font: CGFloat

    var body: some View {
        if !notice.stack.isEmpty {
            let count = notice.stack.count + 1
            Text("\(count)")
                .font(.system(size: font, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .padding(.horizontal, 5)
                .frame(minWidth: font + 7, minHeight: font + 7)
                .background(notice.accent, in: Capsule())
                .help("\(count) messages")
                .transition(.scale.combined(with: .opacity))
        }
    }
}

/// SF Symbol with the chosen motion.
struct NoticeIcon: View {
    let notice: NotchNotice
    let size: CGFloat

    var body: some View {
        if let person = notice.person {
            PersonAvatar(person, size: size * 1.55)
        } else if let image = notice.image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size * 1.3, height: size * 1.3)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
        } else if let id = notice.appIcon, let icon = Self.appIcon(id) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: size * 1.45, height: size * 1.45)
        } else if let emoji = notice.emoji {
            Text(emoji).font(.system(size: size * 1.2))
        } else {
            symbol
        }
    }

    @ViewBuilder private var symbol: some View {
        let base = Image(systemName: notice.icon)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(notice.tint)
        switch notice.iconMotion {
        case .none: base
        case .bounce: base.symbolEffect(.bounce, options: .repeat(.periodic(delay: 0.8)))
        case .pulse: base.symbolEffect(.pulse, options: .repeat(.continuous))
        case .wiggle: base.symbolEffect(.wiggle, options: .repeat(.periodic(delay: 0.6)))
        case .breathe: base.symbolEffect(.breathe, options: .repeat(.continuous))
        case .rotate: base.symbolEffect(.rotate, options: .repeat(.continuous))
        case .waves: base.symbolEffect(.variableColor.iterative, options: .repeat(.continuous))
        }
    }

    @MainActor private static var icons: [String: NSImage] = [:]
    @MainActor static func appIcon(_ bundleID: String) -> NSImage? {
        if let cached = icons[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = icon
        return icon
    }
}

/// A slim bar that fills with the notice's tint.
struct NoticeProgressBar: View {
    let value: Double
    let tint: Color
    let height: CGFloat

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule().fill(tint)
                    .frame(width: max(height, g.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: height)
        .frame(minWidth: 40)
    }
}

/// Progress as a ring, where an icon would go.
struct NoticeRing: View {
    let value: Double
    let tint: Color
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.2), lineWidth: 2)
            Circle().trim(from: 0, to: min(max(value, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

/// "42%", rolling as it changes.
struct NoticePercent: View {
    let progress: Double
    let font: CGFloat

    var body: some View {
        Text("\(Int((min(max(progress, 0), 1) * 100).rounded()))%")
            .font(.system(size: font, weight: .semibold))
            .foregroundStyle(.white.opacity(0.6))
            .monospacedDigit()
            .contentTransition(.numericText())
    }
}

/// The round × that dismisses a notice.
struct NoticeCloseButton: View {
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: size, height: size)
                .background(.white.opacity(0.12), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Dismiss")
    }
}

/// A button in the peek or the list, styled by its role.
struct NoticeButton: View {
    let action: NotchNotice.Action
    let tint: Color
    let font: CGFloat
    var holdDuration: Double = 0.9
    let run: () -> Void

    var body: some View {
        if action.hold {
            held
        } else {
            pressed
        }
    }

    /// Held to run: a track that fills, red or in the tint.
    private var held: some View {
        NoticeHoldButton(fill: action.role == .destructive ? .red.opacity(0.85) : tint.opacity(0.9),
                         duration: holdDuration, run: run) {
            HStack(spacing: 4) {
                Image(systemName: "hand.tap.fill").font(.system(size: font - 2, weight: .semibold))
                Text(action.title).font(.system(size: font, weight: .semibold))
            }
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.white.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
    }

    @ViewBuilder private var pressed: some View {
        let label = Text(action.title)
            .font(.system(size: font, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Capsule())
        switch action.role {
        case .normal:
            Button(action: run) { label }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(tint.opacity(0.28)).interactive(), in: Capsule())
        case .primary:
            Button(action: run) { label.background(tint.opacity(0.85), in: Capsule()) }
                .buttonStyle(.plain)
        case .destructive:
            Button(action: run) { label }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(.red.opacity(0.55)).interactive(), in: Capsule())
        }
    }
}

/// A button in an ear: small flat capsules that sit on the notch's black.
struct NoticeEarButton: View {
    let action: NotchNotice.Action
    let tint: Color
    let metrics: NoticeMetrics
    let run: () -> Void

    private var fill: Color {
        switch action.role {
        case .normal: .white.opacity(0.16)
        case .primary: tint.opacity(0.9)
        case .destructive: .red.opacity(0.8)
        }
    }

    var body: some View {
        Button(action: run) {
            Text(action.title)
                .font(.system(size: metrics.sideButtonFont, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: metrics.sideButtonHeight)
                .background(fill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// An urgent notice's glow: its tint rising from the bottom edge and fading
/// out upward, pulsing slowly. In the notch it bleeds past the card so the
/// notch's own shape clips it (the glow follows the real corners, no box);
/// floating or in the list, the card's shape clips it.
struct UrgentGlow: View {
    let tint: Color
    var bleed: CGFloat = 0
    @State private var bright = false

    var body: some View {
        LinearGradient(colors: [tint.opacity(0), tint.opacity(bright ? 0.5 : 0.2)],
                       startPoint: .top, endPoint: .bottom)
            .padding(.horizontal, -bleed)
            .padding(.bottom, -bleed)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { bright = true }
            }
    }
}

/// Keeps its content at its natural width up to `max`, and makes it fit
/// (text truncates) past that, even where it's offered unlimited room, as
/// in the closed notch's ears.
struct CappedWidth: Layout {
    let max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let ideal = child.sizeThatFits(.unspecified)
        let width = Swift.min(ideal.width, max, proposal.width ?? .infinity)
        return child.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

// MARK: - In an ear

/// A notice in an ear beside the cutout (left or right spot): one line, its
/// icon and title. Pointing at it swaps the icon for a close button and the
/// title for its buttons, in place. Both states are laid out all the time
/// and the ear takes the wider, so the notch never changes size under the
/// pointer. (The first version grew a peek under the notch instead: the
/// notch reshaping under the pointer made it flicker, cut titles short
/// mid-move, and stop answering after a few passes.) Progress shows as a
/// ring for the icon, and its percentage while pointed at.
struct NoticeSide: View {
    @ObservedObject var notices: NotchNotices
    let slot: NoticePlacement

    /// Whether this ear holds a notice right now.
    static func shows(_ notices: NotchNotices, _ slot: NoticePlacement) -> Bool {
        notices.visible(slot) != nil
    }

    var body: some View {
        if let notice = notices.visible(slot) {
            let m = notices.metrics
            let pointed = notice.id == notices.peekingID
            SwapLayout(showing: pointed ? 1 : 0, max: m.sideMaxWidth, anchor: slot == .left ? .trailing : .leading) {
                line(notice, m)
                    .opacity(pointed ? 0 : 1)
                    .blur(radius: pointed ? 2 : 0)
                    .allowsHitTesting(false)
                    .animation(.easeOut(duration: 0.18), value: pointed)
                controls(notice, m)
                    .opacity(pointed ? 1 : 0)
                    .blur(radius: pointed ? 0 : 2)
                    .allowsHitTesting(pointed)
                    .animation(.easeOut(duration: 0.18), value: pointed)
            }
            .clipped()
            // The notch's shape follows an ear's width with .smooth; match it.
            .animation(.smooth, value: pointed)
            .reportsNoticeFrame(notice.id, to: notices)
        }
    }

    /// At rest: icon (or ring), title, subtitle.
    private func line(_ notice: NotchNotice, _ m: NoticeMetrics) -> some View {
        HStack(spacing: m.sideSpacing) {
            if let progress = notice.progress {
                NoticeRing(value: progress, tint: notice.tint, size: m.sideIcon + 2)
            } else {
                NoticeIcon(notice: notice, size: m.sideIcon)
            }
            title(notice, m)
        }
    }

    /// Pointed at: × where the icon was, then the buttons (or, with none, the
    /// title again with the percentage for progress).
    private func controls(_ notice: NotchNotice, _ m: NoticeMetrics) -> some View {
        HStack(spacing: m.sideSpacing) {
            NoticeCloseButton(size: m.sideIcon + 5) { notices.close(notice.id) }
            if notice.actions.isEmpty {
                title(notice, m)
                if let progress = notice.progress {
                    NoticePercent(progress: progress, font: m.sideFont)
                }
            } else {
                ForEach(notice.actions.prefix(max(m.sideMaxActions, 1))) { action in
                    NoticeEarButton(action: action, tint: notice.tint, metrics: m) {
                        notices.perform(notice.id, action.id)
                    }
                }
            }
        }
    }

    private func title(_ notice: NotchNotice, _ m: NoticeMetrics) -> some View {
        HStack(spacing: 4) {
            Text(notice.title)
                .font(.system(size: m.sideFont, weight: .semibold))
                // Urgent in an ear: the title takes the tint (no box in the ear).
                .foregroundStyle(notice.emphasis == .urgent ? notice.tint : .white.opacity(0.92))
                .lineLimit(1)
                .layoutPriority(1)
            if let subtitle = notice.subtitle {
                Text(subtitle)
                    .font(.system(size: m.sideFont, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Under the notch

/// The row DynamicNotchKit stacks under the closed notch's ears
/// (`compactBottom`): the notice in the `below` spot, which opens into its
/// peek there when pointed at. Zero-sized when there's nothing to show, so
/// the notch keeps its usual shape.
struct NoticeNudge: View {
    @ObservedObject var notices: NotchNotices
    @Environment(\.notchCompactWidth) private var notchWidth

    var body: some View {
        content
            // Floating notices take this width, so they sit under it like part of it.
            .onChange(of: notchWidth, initial: true) { _, width in notices.reportNotchWidth(width) }
    }

    private var content: some View {
        Group {
            if let notice = notices.visible(.below) {
                NoticeCard(notice: notice, peeking: notice.id == notices.peekingID, metrics: notices.metrics,
                           canType: true, onTyping: { notices.typingOnNotch(notice.id, $0) },
                           onAction: { notices.perform(notice.id, $0) }, onClose: { notices.close(notice.id) })
                    .reportsNoticeFrame(notice.id, to: notices)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        }
    }
}

/// The notices docked under the open notch: short rows that open into their
/// peek in place when pointed at. The open notch's window takes the pointer
/// there, so plain SwiftUI hover works. Hidden while the list is showing,
/// since they're in it.
struct NoticeOpenStrip: View {
    @ObservedObject var notices: NotchNotices
    let width: CGFloat

    var body: some View {
        let rows = notices.notchOpen && !notices.listOpen ? notices.openStrip : []
        VStack(spacing: notices.metrics.openStripSpacing) {
            ForEach(rows) { notice in
                NoticeCard(notice: notice, peeking: notice.id == notices.peekingID, metrics: notices.metrics,
                           floating: true, width: width,
                           canType: true, onTyping: { notices.typingOnNotch(notice.id, $0) },
                           onAction: { notices.perform(notice.id, $0) }, onClose: { notices.close(notice.id) })
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(Rectangle())
                    .onHover { notices.pointerOnOpenRow(notice.id, hovering: $0) }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, rows.isEmpty ? 0 : NotchExpandedRoot.hPadding * 2)
        .background(GeometryReader { g in
            Color.clear.onChange(of: g.size.height, initial: true) { _, h in notices.openStripHeight = h }
        })
    }
}

// MARK: - The list

/// The bell's list in the open notch: everything that needs you, showing or
/// timed out, newest first, each with its buttons and a close button. It
/// takes the tab's place at the cards' size and scrolls past two rows.
struct NoticeList: View {
    @ObservedObject var notices: NotchNotices
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let items = notices.listed
        let m = notices.metrics
        Group {
            if items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.3))
                    Text("Nothing waiting")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: m.listSpacing) {
                        ForEach(items) { notice in
                            NoticeListRow(notice: notice, metrics: m,
                                          onAction: { notices.perform(notice.id, $0) },
                                          onClose: { notices.close(notice.id) })
                                .transition(.opacity.combined(with: .move(edge: .trailing)))
                        }
                        if items.count > 1 {
                            Button {
                                for notice in items { notices.close(notice.id) }
                            } label: {
                                Text("Clear all")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.6))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: Capsule())
                            .padding(.vertical, 2)
                        }
                    }
                }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(width: width, height: height)
    }
}

/// One row of the list: icon, title and detail on one line each, age,
/// buttons, close.
struct NoticeListRow: View {
    let notice: NotchNotice
    let metrics: NoticeMetrics
    let onAction: (String) -> Void
    let onClose: () -> Void

    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        HStack(spacing: 10) {
            NoticeIcon(notice: notice, size: 13)
                .frame(width: 30, height: 30)
                .background(notice.image == nil && notice.appIcon == nil ? notice.tint.opacity(0.18) : .clear,
                            in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(notice.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(notice.emphasis == .urgent ? notice.tint : .white)
                        .lineLimit(1)
                    if let subtitle = notice.subtitle {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                }
                if let progress = notice.progress {
                    HStack(spacing: 6) {
                        NoticeProgressBar(value: progress, tint: notice.tint, height: 3)
                        NoticePercent(progress: progress, font: 10)
                    }
                } else if let detail = notice.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(Self.age(of: notice.posted, now: context.date))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                    .monospacedDigit()
            }
            ForEach(notice.actions) { action in
                NoticeButton(action: action, tint: notice.tint, font: 11) { onAction(action.id) }
            }
            NoticeCloseButton(size: 20, action: onClose)
        }
        .padding(.horizontal, 12)
        .frame(height: metrics.listRowHeight)
        .background {
            ZStack {
                shape.fill(.white.opacity(0.06))
                if notice.emphasis == .urgent { UrgentGlow(tint: notice.tint) }
            }
            .clipShape(shape)
        }
    }

    /// "now", "5m", "2h", then the time of day.
    static func age(of date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 6 * 3600 { return "\(Int(seconds / 3600))h" }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

/// The bell beside the pin in the open notch: shows the list in place of the
/// tab, and back. There only while something is listed (or the list is up),
/// with the count in the newest one's tint.
struct NoticeBell: View {
    @ObservedObject var notices: NotchNotices
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let items = notices.listed
        if !items.isEmpty || notices.listOpen {
            Button { notices.toggleList() } label: {
                Image(systemName: notices.listOpen ? "bell.fill" : "bell")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(notices.listOpen ? Color.panelAccent : .white.opacity(0.7))
                    .frame(width: width, height: height)
                    .contentShape(Rectangle())
                    .overlay(alignment: .topTrailing) {
                        if !items.isEmpty && !notices.listOpen {
                            Text("\(items.count)")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(.black)
                                .monospacedDigit()
                                .padding(.horizontal, 4)
                                .frame(minWidth: 13, minHeight: 13)
                                .background(items[0].tint == .white ? Color.panelAccent : items[0].tint, in: Capsule())
                                .offset(x: -3, y: 1)
                                .contentTransition(.numericText())
                        }
                    }
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(notices.listOpen ? Color.panelAccent.opacity(0.30) : nil), in: Capsule())
            .help(notices.listOpen ? "Back" : "Notifications")
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
    }
}

/// Swaps the open notch's cards for the list while it's up. The cards stay
/// alive underneath, so the player doesn't rebuild on the way back.
struct NoticeListSwap: ViewModifier {
    @ObservedObject var notices: NotchNotices
    let width: CGFloat
    let height: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(notices.listOpen ? 0 : 1)
            .allowsHitTesting(!notices.listOpen)
            .overlay {
                if notices.listOpen {
                    NoticeList(notices: notices, width: width, height: height)
                        .transition(.opacity)
                }
            }
    }
}

// MARK: - Floating

/// Where the floating pill sits in its band, animated like ScreenLyrics' pill.
@MainActor
final class FloatingNoticeModel: ObservableObject {
    /// Distance from the notch's bottom edge to the pill's top.
    @Published private(set) var drop: CGFloat = 6

    func setDrop(_ value: CGFloat, animated: Bool) {
        guard abs(value - drop) > 0.5 else { return }
        if animated {
            withAnimation(.snappy(duration: 0.4)) { drop = value }
        } else {
            drop = value
        }
    }
}

/// The detached pills: glass cards under the notch, one or two side by side,
/// in their own click-through panel like ScreenLyrics. The panel is a deep
/// band hanging from the notch that stays put; the pills slide inside it,
/// below whatever hangs from the notch (the strip under the closed notch, or
/// the open notch and its docked notices), so they never land on top of
/// another notice and glide, rather than jump, when the notch opens and
/// closes. Only the cards take the pointer; everywhere else clicks pass
/// through.
@MainActor
final class FloatingNoticePanel {
    private unowned let notices: NotchNotices
    private var panel: KeyablePanel?
    private var hoverTimer: Timer?
    private var orderOutWork: DispatchWorkItem?
    fileprivate let model = FloatingNoticeModel()
    /// Each card's frame in the panel (SwiftUI global space), by notice, from the view.
    fileprivate var cardFrames: [UUID: CGRect] = [:]
    private static let height: CGFloat = 760
    private var refronter: OverlayRefronter?

    init(notices: NotchNotices) {
        self.notices = notices
        // A Space switch, sleep or unlock can leave the panel behind, "visible"
        // but nowhere on screen; bring it back while a pill is up.
        refronter = OverlayRefronter { [weak self] in
            guard let self, let panel = self.panel, !self.pills.isEmpty, self.orderOutWork == nil else { return }
            panel.orderFrontRegardless()
        }
    }

    /// The notices floating now, in order.
    private var pills: [NotchNotice] { NoticePlacement.floats.compactMap { notices.visible($0) } }

    /// Each card on screen, while it's up.
    private var cardScreenFrames: [(UUID, CGRect)] {
        guard let panel, panel.isVisible else { return [] }
        return pills.compactMap { pill in
            guard let r = cardFrames[pill.id], !r.isEmpty else { return nil }
            return (pill.id, CGRect(x: panel.frame.minX + r.minX, y: panel.frame.maxY - r.maxY,
                                    width: r.width, height: r.height))
        }
    }

    /// The cards on screen together, while they're up (the open notch's hover
    /// reaches down to them).
    var cardScreenFrame: CGRect? {
        cardScreenFrames.map(\.1).reduce(nil) { $0?.union($1) ?? $1 }
    }

    func update() {
        cardFrames = cardFrames.filter { id, _ in pills.contains { $0.id == id } }
        if !pills.isEmpty { show() } else { hideAfterExit() }
    }

    /// Move the pill under whatever hangs from the notch now.
    func relayout() {
        model.setDrop(currentDrop(), animated: panel?.isVisible == true)
    }

    private func currentDrop() -> CGFloat {
        let gap = notices.metrics.floatingGap
        guard let screen = NotchGeometry.preferredScreen() else { return gap }
        if notices.notchOpen {
            guard NotchGeometry.hasNotch(screen) else { return gap }
            return NotchExpandedRoot.openDepthBelowNotch + notices.openStripHeight + gap
        }
        if let below = notices.attachedRect(.below) {
            // The notch window's top is the screen's top, so the strip's
            // bottom in it, less the notch's height, is how far it hangs.
            return max(below.maxY - NotchGeometry.notchFrame(for: screen).height, 0) + gap
        }
        return gap
    }

    private func show() {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        let wasVisible = panel?.isVisible == true
        let panel = ensurePanel()
        let frame = Self.frame(on: screen, metrics: notices.metrics)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        // Arriving: start where it belongs; after that, glide.
        model.setDrop(currentDrop(), animated: wasVisible)
        orderOutWork?.cancel(); orderOutWork = nil
        if !panel.isShowingOnScreen { panel.orderFrontRegardless() }
        if hoverTimer == nil {
            let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tickHover() }
            }
            RunLoop.main.add(t, forMode: .common)
            hoverTimer = t
        }
    }

    /// Let the card's exit play, then take the panel away.
    private func hideAfterExit() {
        hoverTimer?.invalidate(); hoverTimer = nil
        notices.pointerOnFloating(nil)
        guard let panel, panel.isVisible, orderOutWork == nil else { return }
        panel.ignoresMouseEvents = true
        let work = DispatchWorkItem { [weak self] in
            self?.orderOutWork = nil
            self?.panel?.orderOut(nil)
        }
        orderOutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func tickHover() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let frames = cardScreenFrames.filter { $0.1.insetBy(dx: -4, dy: -4).contains(mouse) }
        // The open one first: its card can lie over the others' places.
        let under = frames.first { $0.0 == notices.peekingID }?.0 ?? frames.first?.0
        panel.ignoresMouseEvents = under == nil
        notices.pointerOnFloating(under)
    }

    /// Typing in a reply ended: give the keyboard back to the app in front.
    /// Ordering the panel out and in hands key back without activating anything.
    func returnKey() {
        panel?.giveBackKey()
    }

    /// A band hanging from the notch's bottom edge, deep enough for the pills
    /// to sit under the open notch and its docked notices, and wide enough
    /// for two open side by side.
    private static func frame(on screen: NSScreen, metrics m: NoticeMetrics) -> CGRect {
        let width = min(screen.frame.width, 960)
        let top = NotchGeometry.notchFrame(for: screen).minY
        return CGRect(x: screen.frame.midX - width / 2, y: max(screen.frame.minY, top - height),
                      width: width, height: min(height, top - screen.frame.minY))
    }

    private func ensurePanel() -> KeyablePanel {
        if let panel { return panel }
        let p = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        // Key only when a reply field is clicked, and never activating Oxine.
        p.becomesKeyOnlyIfNeeded = true
        p.title = "Oxine Notice"
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .mainMenu + 3
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        // Key appearance only: faking key itself would stop it ever becoming key.
        p.forceActiveGlassAppearance(keyToo: false)
        // Hosted inside a plain container, not as the contentView (see ScreenLyrics).
        let container = NSView(frame: .zero)
        container.autoresizesSubviews = true
        let host = NSHostingView(rootView: FloatingNoticeView(notices: notices, model: model, owner: self))
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        host.frame = container.bounds
        container.addSubview(host)
        p.contentView = container
        panel = p
        return p
    }
}

private struct FloatingNoticeView: View {
    @ObservedObject var notices: NotchNotices
    @ObservedObject var model: FloatingNoticeModel
    let owner: FloatingNoticePanel

    var body: some View {
        let m = notices.metrics
        let here = NoticePlacement.floats.compactMap { notices.visible($0) }
        // The pill on the left, then the circles, as wide as the notch together.
        let row = here.filter { !$0.restsAsCircle } + here.filter(\.restsAsCircle)
        let pillWidth = pillWidth(in: row)
        let open = row.firstIndex { $0.id == notices.peekingID }
        let pillOpen = open.map { !row[$0].restsAsCircle } ?? false
        VStack(spacing: 0) {
            FloatingRow(restWidths: row.map { $0.restsAsCircle ? m.circleSize : pillWidth }, gap: m.floatingGap,
                        open: open, openCentered: pillOpen) {
                ForEach(row) { notice in
                    let covered = pillOpen && notice.id != notices.peekingID
                    island(notice, restWidth: pillWidth)
                        // A pill's card opens over the others; they step back meanwhile.
                        .opacity(covered ? 0 : 1)
                        .allowsHitTesting(!covered)
                        .zIndex(notice.id == notices.peekingID ? 1 : 0)
                        .animation(.easeOut(duration: 0.2), value: covered)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, model.drop)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Lively glass though the panel is only key while a reply is typed.
        .environment(\.controlActiveState, .key)
    }

    /// The row's width: the closed notch's, when they match it.
    private var shared: CGFloat {
        let m = notices.metrics
        guard m.floatingMatchesNotch, notices.notchWidth > 0, notices.notchPresent else { return m.peekWidth }
        return notices.notchWidth
    }

    /// A pill's width at rest: what the circles beside it leave of the row
    /// (shared, should an update ever leave two).
    private func pillWidth(in row: [NotchNotice]) -> CGFloat {
        let m = notices.metrics
        let circles = CGFloat(row.filter(\.restsAsCircle).count)
        let pills = CGFloat(row.count) - circles
        guard pills > 0 else { return 0 }
        return max(80, (shared - circles * (m.circleSize + m.floatingGap) - (pills - 1) * m.floatingGap) / pills)
    }

    private func island(_ notice: NotchNotice, restWidth: CGFloat) -> some View {
        let m = notices.metrics
        return IslandNotice(
            notice: notice, peeking: notice.id == notices.peekingID, metrics: m, restWidth: restWidth,
            openWidth: max(shared, m.peekWidth), firstShown: notices.firstShown[notice.id],
            onAction: { notices.perform(notice.id, $0) }, onClose: { notices.close(notice.id) },
            onTyping: { on in
                notices.typing(notice.id, on)
                if !on { owner.returnKey() }
            })
            .background(GeometryReader { g in
                Color.clear.onChange(of: g.frame(in: .global), initial: true) { _, frame in
                    owner.cardFrames[notice.id] = frame
                }
            })
            .transition(.opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.6, anchor: .top)))
    }
}
