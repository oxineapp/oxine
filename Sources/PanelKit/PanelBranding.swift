import Foundation

/// Per-app identity for the shared panel chrome. PanelKit is brand-neutral; the
/// host app injects this once at launch via `PanelKit.configure(_:)` so the
/// theme, size store, and updater UI know which UserDefaults suite to use and
/// what to call themselves. Mirrors `HelperBranding` on the daemon side.
public struct PanelBranding: Sendable {
    /// UserDefaults suite the chrome persists into (accent, panel size, …).
    public let settingsSuite: String
    /// Display name shown in chrome UI (e.g. the updater dialog).
    public let appName: String

    public init(settingsSuite: String, appName: String) {
        self.settingsSuite = settingsSuite
        self.appName = appName
    }

    /// Oxine's chrome configuration.
    public static let oxine = PanelBranding(settingsSuite: "com.oxine.settings", appName: "Oxine")
}

/// PanelKit's entry point for host configuration.
public enum PanelKit {
    /// The active branding. Defaults to Oxine so existing call sites keep working
    /// even before `configure` runs; a host should still call `configure` early
    /// in launch (before any chrome touches the theme or size store).
    public private(set) nonisolated(unsafe) static var branding: PanelBranding = .oxine

    /// Set the host's branding. Call once, early in `applicationDidFinishLaunching`,
    /// before the first chrome view or `ThemeManager.shared` access.
    public static func configure(_ branding: PanelBranding) {
        self.branding = branding
    }

    /// The configured settings suite (or `.standard` if it can't be opened).
    static var settingsDefaults: UserDefaults {
        UserDefaults(suiteName: branding.settingsSuite) ?? .standard
    }
}

/// PanelKit's own lightweight stderr logger (the host app has its own `log`).
func panelLog(_ msg: String) {
    try? FileHandle.standardError.write(contentsOf: Data((msg + "\n").utf8))
}
