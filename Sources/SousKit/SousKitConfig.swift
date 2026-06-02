import SousShared

/// SousKit's host configuration. The host app sets which daemon branding the
/// helper client talks to (Oxine's daemon vs the standalone sous-vide's), once
/// at launch before `SousManager.shared` is first touched. Mirrors
/// `PanelKit.configure`.
public enum SousKit {
    /// Active helper branding. Defaults to Oxine so existing call sites keep
    /// working even before `configure` runs.
    public private(set) nonisolated(unsafe) static var helperBranding: HelperBranding = .oxine

    /// Set the host's Sous daemon branding. Call once, early in launch.
    public static func configure(helperBranding: HelperBranding) {
        self.helperBranding = helperBranding
    }
}
