import SwiftUI
import AppKit

/// App-wide accent tint. One source of truth so the whole UI can be re-tinted
/// from Settings. The stored value is either a hex string (a manual swatch) or
/// the sentinel `"system"`, which follows the user's macOS accent colour
/// (System Settings → Appearance → Accent colour) and updates live when they
/// change it. Persists into the host's configured settings suite (see
/// `PanelBranding`).
@MainActor
public final class ThemeManager: ObservableObject {
    public static let shared = ThemeManager()

    public static let systemSentinel = "system"
    private static let storeKey = "accentHex"
    private static let defaultHex = "#66D9FF"   // the original Oxine blue

    private let suite = PanelKit.settingsDefaults

    /// Republished whenever the tint changes so observing views re-render.
    @Published public private(set) var accent: Color = Color(hex: ThemeManager.defaultHex)

    /// Raw stored mode: a hex string, or `systemSentinel`.
    public var mode: String {
        suite.string(forKey: Self.storeKey) ?? Self.defaultHex
    }

    public var isSystem: Bool { mode == Self.systemSentinel }

    private init() {
        recompute()
        // macOS posts this when the system accent/highlight colours change.
        NotificationCenter.default.addObserver(
            self, selector: #selector(systemColorsChanged),
            name: NSColor.systemColorsDidChangeNotification, object: nil)
    }

    @objc private func systemColorsChanged() {
        if isSystem { recompute() }
    }

    /// Pick a manual swatch (pass a hex) or follow macOS (pass `systemSentinel`).
    public func setMode(_ value: String) {
        suite.set(value, forKey: Self.storeKey)
        recompute()
    }

    private func recompute() {
        accent = isSystem ? Color(nsColor: .controlAccentColor) : Color(hex: mode)
    }

    /// A concrete hex for the *current* accent — used as the default colour when
    /// creating a new tinted item (so it inherits the app tint).
    public var resolvedHex: String {
        isSystem ? NSColor.controlAccentColor.panelHexString : mode
    }
}

public extension Color {
    /// Snapshot of the current app accent. Reactive inside any view that
    /// observes `ThemeManager.shared` (re-evaluated on each body pass).
    @MainActor static var panelAccent: Color { ThemeManager.shared.accent }

    /// Hex string ("#RRGGBB" or "RRGGBB") → Color. Falls back to the default blue
    /// (a literal, to avoid recursing through the themed accent).
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
        var rgb: UInt64 = 0
        if s.count == 6, Scanner(string: s).scanHexInt64(&rgb) {
            self = Color(
                red: Double((rgb & 0xFF0000) >> 16) / 255,
                green: Double((rgb & 0x00FF00) >> 8) / 255,
                blue: Double(rgb & 0x0000FF) / 255
            )
        } else {
            self = Color(red: 0.4, green: 0.85, blue: 1.0)
        }
    }
}

public extension NSColor {
    /// "#RRGGBB" for this colour (converted to sRGB first). Falls back to the
    /// default blue if conversion fails.
    var panelHexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#66D9FF" }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
