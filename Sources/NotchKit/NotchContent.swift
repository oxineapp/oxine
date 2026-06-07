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
                    if tint != .clear {
                        shape.fill(
                            LinearGradient(
                                colors: [tint.opacity(0.55), tint.opacity(0.12)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .blendMode(.plusLighter)
                    }
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
    var body: some View {
        Group {
            if let hud = controller.hud {
                // System HUD takes over: icon + label, left of the cutout.
                HUDLeading(hud: hud)
                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .trailing)))
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
    var body: some View {
        Group {
            if let hud = controller.hud {
                // System HUD takes over: slider + value, right of the cutout.
                HUDTrailing(hud: hud)
                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
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

    /// Reports the cards' real frame in SwiftUI global (window) coordinates, so the
    /// presenter can derive the click-through region by measurement, not constants.
    var onCardsFrame: (CGRect) -> Void = { _ in }

    /// One stable content size for every tab — the cure for the per-tab width
    /// jump that was clipping things. These are the single source of truth: the
    /// presenter derives the open hover region from them, so the zone and the
    /// rendered window can never drift apart.
    static let contentWidth: CGFloat = 580
    static let contentHeight: CGFloat = 100
    // DynamicNotchKit already insets the expanded content by ~30pt per side
    // (corner radius + its own safe-area inset), so we add only a hair more here —
    // a big hPadding stacked on top of that was the dead left/right column.
    static let hPadding: CGFloat = 4
    /// Black gap below the notch before the cards begin. The tab strip does NOT
    /// live here — it sits UP in the band beside the notch (see `body`) — but this
    /// gap still has to clear the strip's bottom so the cards never touch it.
    static let topPadding: CGFloat = 26
    static let bottomPadding: CGFloat = 16

    /// The full footprint we render into (cards + padding).
    static var openWidth: CGFloat { contentWidth + hPadding * 2 + 36 }
    static var openHeightBelowNotch: CGFloat { topPadding + contentHeight + bottomPadding + 22 }
    private static var footprintWidth: CGFloat { contentWidth + hPadding * 2 }
    private static var footprintHeight: CGFloat { topPadding + contentHeight + bottomPadding }

    /// Intrinsic height of the tab strip (see `tabStrip`).
    private static let stripHeight: CGFloat = 24

    /// The cards (the active tab), crossfading on switch.
    private var cards: some View {
        ZStack {
            controller.activeModule?.expandedView()
                .id(controller.activeModuleID)
                .transition(.opacity)
        }
        .frame(width: Self.contentWidth, height: Self.contentHeight)
        .animation(.easeInOut(duration: 0.22), value: controller.activeModuleID)
        .padding(.horizontal, Self.hPadding)
    }

    var body: some View {
        // The tab strip rides UP into the reserved band, centred in it so it sits
        // level with the notch / menu bar — high near the border, not down by the
        // player. `y = 0` is our content top (the notch's bottom edge), so the
        // band is the region above it: its centre is `-bandHeight / 2`. Cards sit
        // `topPadding` below the content top, well clear of the strip's bottom.
        ZStack(alignment: .top) {
            cards
                .padding(.top, Self.topPadding)
                // Measure the cards' real on-screen rect and hand it up so the
                // presenter's interactive region tracks exactly what's drawn.
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { onCardsFrame(geo.frame(in: .global)) }
                            .onChange(of: geo.frame(in: .global)) { _, f in onCardsFrame(f) }
                    }
                )

            tabStrip
                .frame(width: Self.footprintWidth, height: Self.stripHeight)
                .position(x: Self.footprintWidth / 2, y: -bandHeight / 2)
        }
        .frame(width: Self.footprintWidth, height: Self.footprintHeight, alignment: .top)
    }

    /// Tabs in the left ear, the pin in the right ear, the cutout in the gap.
    private var tabStrip: some View {
        HStack(spacing: 6) {
            ForEach(controller.modules, id: \.id) { tab(for: $0) }
            Spacer(minLength: 0)              // gap = the physical cutout
            glassButton(
                icon: controller.pinned ? "pin.fill" : "pin",
                active: controller.pinned,
                help: controller.pinned ? "Unpin" : "Keep open"
            ) { controller.pinned.toggle() }
        }
        .frame(height: Self.stripHeight)
    }

    private func tab(for module: any NotchModule) -> some View {
        glassButton(
            icon: module.icon,
            active: module.id == controller.activeModuleID,
            help: module.title
        ) {
            withAnimation(.easeInOut(duration: 0.22)) { controller.select(module.id) }
        }
    }

    /// A Liquid Glass pill button whose *entire* area is tappable (the bug was the
    /// hit area being only the glyph, not the pill).
    private func glassButton(icon: String, active: Bool, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? Color.panelAccent : .white.opacity(0.7))
                .frame(width: 38, height: Self.stripHeight)
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
