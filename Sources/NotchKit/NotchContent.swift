import SwiftUI
import AppKit
import PanelKit

// MARK: - Glass

/// A glass widget card. Real macOS 26 Liquid Glass (`.glassEffect`) with an
/// album-derived colour gradient sitting *inside* the glass, behind the content,
/// so the card's colour follows the music. The glass stays lively even though our
/// accessory app is never frontmost because the panel's class is patched to report
/// key appearance (see `NSWindow.forceActiveGlassAppearance`).
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 12
    /// Album-derived colour for the gradient. `.clear` = neutral glass.
    var tint: Color = .clear
    @ViewBuilder var content: Content

    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // The album gradient is drawn behind the content but in front of the
            // glass layer, so it tints the glass with the music's colour. Filled
            // *into the rounded shape* (not a bare rectangle) so it can't bleed
            // past the glass corners. A top sheen adds depth.
            .background {
                ZStack {
                    // Always in the tree (`.clear` draws nothing) so a colour
                    // change is one continuous animation, not a view coming and going.
                    shape.fill(
                        LinearGradient(
                            colors: [tint.opacity(0.55), tint.opacity(0.12)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .blendMode(.plusLighter)
                    shape.fill(
                        LinearGradient(
                            colors: [.white.opacity(0.08), .clear],
                            startPoint: .top, endPoint: .center
                        )
                    )
                }
            }
            // Real Liquid Glass, tinted toward the album colour.
            .glassEffect(
                .regular.tint(tint == .clear ? nil : tint.opacity(0.22)),
                in: shape
            )
            .overlay(shape.strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
    }
}

// MARK: - Compact (idle) peeks beside the cutout

struct NotchCompactLeading: View {
    @ObservedObject var controller: NotchController
    let hub: PeekHub
    @ObservedObject private var notices = NotchNotices.shared
    var body: some View {
        Group {
            if let hud = controller.hud {
                // System HUD takes over: icon + label, left of the cutout.
                HUDLeading(hud: hud)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { controller.hudFrames[true] = $0 }
                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .trailing)))
            } else if NoticeSide.shows(notices, .left) {
                NoticeSide(notices: notices, slot: .left)
                    .transition(.opacity)
            } else {
                // Configurable / smart ear (album art, bars, agent grid, CPU…).
                EarView(side: .left, hub: hub)
            }
        }
        .padding(.trailing, 8)
        .frame(height: 24)
    }
}

struct NotchCompactTrailing: View {
    @ObservedObject var controller: NotchController
    let hub: PeekHub
    @ObservedObject private var notices = NotchNotices.shared
    var body: some View {
        Group {
            if let hud = controller.hud {
                // System HUD takes over: slider + value, right of the cutout.
                HUDTrailing(hud: hud)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { controller.hudFrames[false] = $0 }
                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
            } else if NoticeSide.shows(notices, .right) {
                NoticeSide(notices: notices, slot: .right)
                    .transition(.opacity)
            } else if let peek = controller.peekText {
                // Sneak peek: the new track's title, beside the cutout.
                Text(peek)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
                    .frame(maxWidth: 150)
                    .transition(.opacity.combined(with: .scale(scale: 0.7, anchor: .leading)))
            } else {
                EarView(side: .right, hub: hub)
            }
        }
        .padding(.leading, 8)
        .frame(height: 24)
    }
}

// MARK: - System HUD (volume / brightness) compact content

/// The left ear of a system HUD: the level icon plus its name, matching the look
/// of macOS's own volume / brightness overlay but seated in the notch.
private struct HUDLeading: View {
    let hud: NotchHUD
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: hud.icon)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 15)
                // Keep a stable width as the glyph swaps between level variants.
                .contentTransition(.symbolEffect(.replace))
            Text(hud.label)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.white)
        .fixedSize()
    }
}

/// The right ear of a system HUD: a slim filled track plus the 0...100 readout,
/// the number rolling odometer-style as the level changes.
private struct HUDTrailing: View {
    let hud: NotchHUD
    private var value: Int { hud.muted ? 0 : hud.display }
    var body: some View {
        HStack(spacing: 8) {
            HUDSlider(value: hud.muted ? 0 : hud.value)
                .frame(width: 92, height: 4)
            Text("\(value)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.spring(response: 0.3, dampingFraction: 0.9), value: value)
                .frame(width: 22, alignment: .trailing)
        }
        .fixedSize()
    }
}

/// A rounded fill bar: dim track, white fill from the left to `value` (0...1).
private struct HUDSlider: View {
    let value: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white)
                    .frame(width: max(geo.size.height, geo.size.width * value))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.9), value: value)
    }
}

// MARK: - Expanded

/// Sizes its one child to the child's own height at the given width, up to
/// `maxHeight`, and lays it out at that size: a tab that fits its content.
/// A child taller than that gets `maxHeight` and handles it (scrolls).
struct FitHeight: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let ideal = subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: nil)).height ?? 0
        return CGSize(width: width, height: min(ideal, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// The expanded surface. **Fixed size** so the window never resizes (and clips
/// content) when you switch tabs. The tab bar lives in the strip beside the
/// cutout (left ear = tabs, right ear = actions); the active tab fills the rest.
struct NotchExpandedRoot: View {
    @ObservedObject var controller: NotchController
    @ObservedObject private var theme = ThemeManager.shared

    /// The real notch-band height above our content (= the notched screen's
    /// `safeAreaInsets.top`), passed from the presenter, which knows the screen.
    /// We do NOT measure this with a GeometryReader: `.global` reads ~0 here
    /// because our hosting view already starts below DynamicNotchKit's inset, so
    /// the tabs kept landing low. This is the true value.
    let bandHeight: CGFloat
    /// The physical cutout's width (from the presenter, which knows the screen).
    /// The tab strip lives in the ear beside it, so the open width grows with
    /// the tab count until every tab clears the cutout.
    let notchWidth: CGFloat

    /// Reports the cards' real frame in SwiftUI global (window) coordinates, so the
    /// presenter can derive the click-through region by measurement, not constants.
    var onCardsFrame: (CGRect) -> Void = { _ in }

    /// One stable content width for every tab — the cure for the per-tab width
    /// jump that was clipping things. The presenter derives the open hover
    /// region's width from it, so the zone and the rendered window can't drift.
    static let baseContentWidth: CGFloat = 580
    /// One height for every tab too: the Home player card's natural height
    /// (114pt with its padding, measured), which the Weather tab is tuned to
    /// match. The old 100 was shorter than both, so they spilled past it and
    /// ate the bottom margin. A tab's card taller than this spills again, so
    /// re-measure when changing the player or Weather layouts.
    static let contentHeight: CGFloat = 114
    /// The most a tab can ask for (a conversation): room for a chat without
    /// the open notch taking over the screen.
    static let tallestContent: CGFloat = 360

    /// A tab's content height: what it asks for, kept between the standard
    /// height and the tallest.
    static func contentHeight(for module: (any NotchModule)?) -> CGFloat {
        min(max(module?.expandedHeight ?? contentHeight, contentHeight), tallestContent)
    }
    /// The open tab's content height, kept by the presenter, so what hangs
    /// under the open notch (lyrics that follow it, floating notices) clears it.
    static var activeContentHeight: CGFloat = contentHeight
    /// Tab pill width + spacing (see `glassButton` / `tabStrip`).
    static let tabWidth: CGFloat = 38
    static let tabSpacing: CGFloat = 6

    /// The left ear holds this many tabs; the rest go right, beside the pin,
    /// this many at a time. Past that the right ear pages.
    static let leftTabs = 4
    static let rightTabsPerPage = 3
    /// The right ear's page button, a narrower pill than a tab.
    static let pagerWidth: CGFloat = 24

    /// The tabs by ear. The left holds the first `leftTabs` of those that sit
    /// left; the right holds the ones asking for it, then the left's overflow.
    static func tabEars(_ modules: [any NotchModule]) -> (left: [any NotchModule], right: [any NotchModule]) {
        let lefts = modules.filter { $0.tabSide == .left }
        return (Array(lefts.prefix(leftTabs)), modules.filter { $0.tabSide == .right } + lefts.dropFirst(leftTabs))
    }

    /// Each ear's strip width (the right one includes the pin and room for
    /// the notices' bell, and the page button once it pages).
    static func stripWidths(left: Int, right: Int) -> (left: CGFloat, right: CGFloat) {
        func run(_ n: Int) -> CGFloat { CGFloat(n) * tabWidth + CGFloat(max(n - 1, 0)) * tabSpacing }
        let rightCount = min(right, rightTabsPerPage)
        var width = tabWidth * 2 + tabSpacing
        if rightCount > 0 { width += run(rightCount) + tabSpacing }
        if right > rightTabsPerPage { width += pagerWidth + tabSpacing }
        return (run(left), width)
    }

    /// The content width for these tabs: the base width, widened when either
    /// ear's tabs would otherwise run under the cutout. Both ears grow
    /// together so the island stays centred on the notch.
    static func contentWidth(for modules: [any NotchModule], notchWidth: CGFloat) -> CGFloat {
        let ears = tabEars(modules)
        let strips = stripWidths(left: ears.left.count, right: ears.right.count)
        let breathing: CGFloat = 14
        let needed = notchWidth + 2 * (max(strips.left, strips.right) + breathing) - hPadding * 2
        return max(baseContentWidth, needed.rounded(.up))
    }
    /// The open hover zone: the black body (footprint + the kit's inset each
    /// side) plus 3pt of slack per side.
    static func openWidth(for modules: [any NotchModule], notchWidth: CGFloat) -> CGFloat {
        contentWidth(for: modules, notchWidth: notchWidth) + hPadding * 2 + (kitInset + 3) * 2
    }

    private var contentWidth: CGFloat { Self.contentWidth(for: controller.modules, notchWidth: notchWidth) }
    private var cardsHeight: CGFloat { Self.contentHeight(for: controller.activeModule) }
    /// A tab that fits its content: how tall its content came out (see `FitHeight`).
    @State private var fittedHeight: CGFloat?
    /// The cards' height now: a fitting tab's content, kept in range, else the tab's height.
    private var shownHeight: CGFloat {
        guard controller.activeModule?.fitsContent == true, let fittedHeight else { return cardsHeight }
        return min(max(fittedHeight, Self.contentHeight), cardsHeight)
    }
    private var footprintWidth: CGFloat { contentWidth + Self.hPadding * 2 }
    // DynamicNotchKit insets the expanded content by `kitInset` on the sides and
    // bottom, so we add only a hair more here. The cards end up 12pt from the
    // black edge all round, and the tabs keep their place beside the cutout.
    static let hPadding: CGFloat = 4
    /// The margin DynamicNotchKit draws around the expanded content (its
    /// `expandedInset`; upstream's 15 left a heavy border, 31pt at the bottom).
    static let kitInset: CGFloat = 8
    /// Black gap below the notch before the cards begin. The tab strip does NOT
    /// live here — it sits UP in the band beside the notch (see `body`) — but this
    /// gap still has to clear the strip's bottom so the cards never touch it.
    /// (19 is where the player card used to land: 26 minus its 7pt spill.)
    static let topPadding: CGFloat = 19
    static let bottomPadding: CGFloat = 4
    /// The open notch's bottom corners, concentric with the cards' 16pt corners
    /// at the 12pt gap (see `GlassCard`).
    static let bottomCornerRadius: CGFloat = 16 + kitInset + bottomPadding

    /// How far the open notch's black body reaches below the cutout (lyrics
    /// that follow the notch sit just under it).
    static var openDepthBelowNotch: CGFloat { topPadding + activeContentHeight + bottomPadding + kitInset }
    /// The hover zone's reach below the cards: the bottom padding, the kit's
    /// inset, and 7pt of slack.
    static let openSlackBelowCards: CGFloat = bottomPadding + kitInset + 7
    /// The hover zone below the notch before the cards have been measured.
    static var openHeightBelowNotch: CGFloat { topPadding + activeContentHeight + openSlackBelowCards }

    /// Intrinsic height of the tab strip (see `tabStrip`).
    private static let stripHeight: CGFloat = 24

    /// The cards (the active tab), crossfading on switch.
    private var cards: some View {
        ZStack(alignment: .top) {
            Group {
                if let module = controller.activeModule {
                    if module.fitsContent {
                        FitHeight(maxHeight: cardsHeight) { module.expandedView() }
                            .onGeometryChange(for: CGFloat.self, of: \.size.height) { fittedHeight = $0 }
                    } else {
                        module.expandedView()
                    }
                }
            }
            .id(controller.activeModuleID)
            .transition(.opacity)
        }
        .frame(width: contentWidth, height: shownHeight, alignment: .top)
        .animation(.easeInOut(duration: 0.22), value: controller.activeModuleID)
        // A taller tab (a chat), or a fitting one whose content grew or shrank,
        // moves the notch's edge smoothly instead of snapping it.
        .animation(.smooth(duration: 0.32), value: shownHeight)
        // What hangs under the open notch (lyrics, floating notices) clears it.
        .onChange(of: shownHeight, initial: true) { _, height in
            Self.activeContentHeight = height
            NotchNotices.shared.floating?.relayout()
        }
        // The bell's list takes the cards' place while it's up.
        .modifier(NoticeListSwap(notices: .shared, width: contentWidth, height: shownHeight))
        .padding(.horizontal, Self.hPadding)
    }

    var body: some View {
        // The tab strip rides UP into the reserved band, centred in it so it sits
        // level with the notch / menu bar — high near the border, not down by the
        // player. `y = 0` is our content top (the notch's bottom edge), so the
        // band is the region above it: its centre is `-bandHeight / 2`. Cards sit
        // `topPadding` below the content top, well clear of the strip's bottom.
        // The strip is an overlay so it never adds to the height.
        VStack(spacing: 0) {
            cards
            // Notices docked under the open notch (empty: no height).
            NoticeOpenStrip(notices: NotchNotices.shared, width: contentWidth)
        }
            .padding(.top, Self.topPadding)
            // Measure the cards' real on-screen rect (and any docked notices)
            // and hand it up so the presenter's interactive region tracks
            // exactly what's drawn.
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { onCardsFrame(geo.frame(in: .global)) }
                        .onChange(of: geo.frame(in: .global)) { _, f in onCardsFrame(f) }
                }
            )
            .frame(width: footprintWidth, alignment: .top)
            .overlay(alignment: .top) {
                tabStrip
                    .frame(width: footprintWidth, height: Self.stripHeight)
                    .offset(y: -bandHeight / 2 - Self.stripHeight / 2)
            }
            .padding(.bottom, Self.bottomPadding)
    }

    /// Tabs in both ears (see `tabEars`), the right ear's beside the pin and
    /// paged when there are more than fit, the cutout in the gap.
    private var tabStrip: some View {
        let ears = Self.tabEars(controller.modules)
        let right = ears.right
        let pages = max(1, (right.count + Self.rightTabsPerPage - 1) / Self.rightTabsPerPage)
        let page = min(rightPage, pages - 1)
        let shown = right.dropFirst(page * Self.rightTabsPerPage).prefix(Self.rightTabsPerPage)
        return HStack(spacing: Self.tabSpacing) {
            ForEach(ears.left, id: \.id) { tab(for: $0) }
            Spacer(minLength: 0)              // gap = the physical cutout
            ForEach(Array(shown), id: \.id) { tab(for: $0) }
            if pages > 1 {
                let last = page == pages - 1
                glassButton(
                    icon: last ? "chevron.left" : "chevron.right",
                    active: false,
                    help: "More tabs (\(page + 1) of \(pages))",
                    width: Self.pagerWidth
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) { rightPage = last ? 0 : page + 1 }
                }
            }
            NoticeBell(notices: .shared, width: Self.tabWidth, height: Self.stripHeight)
            glassButton(
                icon: controller.pinned ? "pin.fill" : "pin",
                active: controller.pinned,
                help: controller.pinned ? "Unpin" : "Keep open"
            ) { controller.pinned.toggle() }
        }
        .frame(height: Self.stripHeight)
        // Open on the page that holds the active tab.
        .onAppear { showPage(of: controller.activeModuleID) }
        .onChange(of: controller.activeModuleID) { _, id in showPage(of: id) }
    }

    /// The right ear's current page (see `tabStrip`).
    @State private var rightPage = 0

    private func showPage(of id: String) {
        guard let index = Self.tabEars(controller.modules).right.firstIndex(where: { $0.id == id }) else { return }
        rightPage = index / Self.rightTabsPerPage
    }

    private func tab(for module: any NotchModule) -> some View {
        glassButton(
            icon: module.icon,
            active: module.id == controller.activeModuleID,
            help: module.title
        ) {
            // A tab brings the cards back if the list was up.
            NotchNotices.shared.closeList()
            withAnimation(.easeInOut(duration: 0.22)) { controller.select(module.id) }
            // Clicked, so the notch has the keyboard: a chat is ready to type in.
            controller.focusActive()
        }
    }

    /// A Liquid Glass pill button whose *entire* area is tappable (the bug was the
    /// hit area being only the glyph, not the pill).
    private func glassButton(icon: String, active: Bool, help: String, width: CGFloat = tabWidth,
                             _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? Color.panelAccent : .white.opacity(0.7))
                .frame(width: width, height: Self.stripHeight)
                .contentShape(Rectangle())          // whole pill is the hit target
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(active ? Color.panelAccent.opacity(0.30) : nil),
            in: Capsule()
        )
        .help(help)
    }
}
