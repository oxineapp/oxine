import TemperShared

/// TemperKit's host configuration. The host app sets which daemon branding the
/// helper client talks to (Oxine's vs a future standalone Temper app), once at
/// launch before `TemperManager.shared` is first touched. Mirrors `SousKit`.
public enum TemperKit {
    public private(set) nonisolated(unsafe) static var helperBranding: TemperHelperBranding = .oxine

    /// Set the host's Temper daemon branding. Call once, early in launch.
    public static func configure(helperBranding: TemperHelperBranding) {
        self.helperBranding = helperBranding
    }
}
