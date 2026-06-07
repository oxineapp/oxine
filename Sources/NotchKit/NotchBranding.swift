import Foundation

/// Per-app identity for the notch engine. NotchKit is brand-neutral — the host
/// injects this once at launch via `NotchKit.configure(_:)` so the engine knows
/// which UserDefaults suite to persist into and what to call itself. Mirrors
/// `PanelBranding` on the panel side (same suite for Oxine, so notch settings
/// live alongside panel settings).
public struct NotchBranding: Sendable {
    /// UserDefaults suite the engine persists into (enabled modules, behavior, …).
    public let settingsSuite: String
    /// Display name used in any chrome the notch surfaces.
    public let appName: String

    public init(settingsSuite: String, appName: String) {
        self.settingsSuite = settingsSuite
        self.appName = appName
    }

    /// Oxine's notch configuration — shares Oxine's panel settings suite.
    public static let oxine = NotchBranding(settingsSuite: "com.oxine.settings", appName: "Oxine")
}

/// NotchKit's entry point for host configuration.
public enum NotchKit {
    /// The active branding. Defaults to Oxine so call sites work even before the
    /// host calls `configure`; a host should still configure early in launch.
    public private(set) nonisolated(unsafe) static var branding: NotchBranding = .oxine

    /// Set the host's branding. Call once, early in `applicationDidFinishLaunching`.
    public static func configure(_ branding: NotchBranding) {
        self.branding = branding
    }

    /// The configured settings suite (or `.standard` if it can't be opened).
    public static var settingsDefaults: UserDefaults {
        UserDefaults(suiteName: branding.settingsSuite) ?? .standard
    }
}

/// NotchKit's own lightweight stderr logger.
func notchLog(_ msg: String) {
    try? FileHandle.standardError.write(contentsOf: Data(("[NotchKit] " + msg + "\n").utf8))
}
