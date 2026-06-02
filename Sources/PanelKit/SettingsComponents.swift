import SwiftUI

/// The canonical accent swatches offered in the theme picker (and the default
/// palette for tinted items). Hex strings so they round-trip through storage.
public enum AccentPalette {
    public static let swatches = ["#66D9FF", "#7CF6A0", "#FFD166", "#FF8FA3", "#C792EA", "#FF9F66", "#9AA7B2"]
}

/// A titled, glass-backed settings group. The shared container every settings
/// screen builds its rows inside, so Oxine and the standalone app match.
public struct SettingSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    public init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.4))
                .textCase(.uppercase)
                .tracking(1.0)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                    )
            )
            .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

/// Accent-tint selector: an "Auto" chip that follows the macOS system accent,
/// then the fixed swatch palette. Writes straight to `ThemeManager.shared`.
/// Renders its own label + subtitle so it drops into a `SettingSection` whole.
public struct ThemeAccentPicker: View {
    @ObservedObject private var theme = ThemeManager.shared
    private let subtitle: String

    /// `subtitle` lets a host tweak the description line; defaults to a generic one.
    public init(subtitle: String = "Colors buttons and highlights throughout the app.") {
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Accent tint").foregroundColor(.white.opacity(0.85))
            Text(subtitle).font(.caption2).foregroundColor(.white.opacity(0.5))

            HStack(spacing: 10) {
                // Auto chip — follows the macOS system accent, live.
                Button(action: { theme.setMode(ThemeManager.systemSentinel) }) {
                    ZStack {
                        Circle().fill(Color(nsColor: .controlAccentColor))
                        Image(systemName: "a.circle")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white.opacity(0.9))
                    }
                    .frame(width: 24, height: 24)
                    .overlay(Circle().stroke(.white, lineWidth: theme.isSystem ? 2 : 0))
                    .help("Match macOS accent color")
                }
                .buttonStyle(.plain)

                Rectangle().fill(.white.opacity(0.1)).frame(width: 1, height: 20)

                ForEach(AccentPalette.swatches, id: \.self) { hex in
                    Button(action: { theme.setMode(hex) }) {
                        Circle().fill(Color(hex: hex)).frame(width: 24, height: 24)
                            .overlay(Circle().stroke(.white, lineWidth: (!theme.isSystem && theme.mode == hex) ? 2 : 0))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Panel size preset picker (Compact / Standard / Tall / Custom) plus the
/// custom-size hint, writing to the shared settings suite. Re-clicking the
/// active Custom toggles its drag-resize lock. Renders its own "Size" label so
/// it drops into a `SettingSection` whole.
public struct PanelSizeEditor: View {
    @AppStorage("panelSizePreset", store: PanelKit.settingsDefaults) private var panelSizePreset = PanelSize.standard.rawValue
    @AppStorage("panelCustomWidth", store: PanelKit.settingsDefaults) private var panelCustomWidth = 380.0
    @AppStorage("panelCustomHeight", store: PanelKit.settingsDefaults) private var panelCustomHeight = 560.0
    @AppStorage("panelCustomLocked", store: PanelKit.settingsDefaults) private var panelCustomLocked = false

    public init() {}

    /// Selecting a preset switches to it. Re-clicking the already-active Custom
    /// toggles its lock; a fresh switch to Custom starts unlocked.
    private func select(_ size: PanelSize) {
        if size == .custom {
            if panelSizePreset == PanelSize.custom.rawValue {
                panelCustomLocked.toggle()
            } else {
                panelSizePreset = PanelSize.custom.rawValue
                panelCustomLocked = false
            }
        } else {
            panelSizePreset = size.rawValue
        }
        NotificationCenter.default.post(name: .panelSizeChanged, object: nil)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Size").foregroundColor(.white.opacity(0.8))

            HStack(spacing: 4) {
                ForEach(PanelSize.allCases) { size in
                    let isActive = panelSizePreset == size.rawValue
                    Button(action: { select(size) }) {
                        HStack(spacing: 4) {
                            Text(size.label).font(.system(size: 11, weight: .medium))
                            if size == .custom && isActive {
                                Image(systemName: panelCustomLocked ? "lock.fill" : "lock.open")
                                    .font(.system(size: 9))
                            }
                        }
                        .foregroundColor(.white.opacity(isActive ? 0.9 : 0.4))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isActive ? Color.panelAccent.opacity(0.14) : Color.white.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(.white.opacity(isActive ? 0.10 : 0.05), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if panelSizePreset == PanelSize.custom.rawValue {
                HStack(spacing: 6) {
                    Image(systemName: panelCustomLocked ? "lock.fill" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10)).foregroundColor(.white.opacity(0.45))
                    Text(panelCustomLocked
                         ? "Locked. Click Custom again to unlock and resize."
                         : "Drag the panel edges to resize, then click Custom to lock it.")
                        .font(.system(size: 10)).foregroundColor(.white.opacity(0.4))
                    Spacer()
                    Text("\(Int(panelCustomWidth))×\(Int(panelCustomHeight))")
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.35))
                }
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
            }
        }
    }
}
