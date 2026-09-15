import Foundation

/// `manifest.json` at the root of an app's repo — the static contract: identity,
/// which surfaces it fills, which capabilities and OS permissions it wants. Kept
/// deliberately dumb (pure Codable) so the store can render an app's page from
/// the manifest alone, before anything is downloaded or run. See APPS_DESIGN.md.
struct AppManifest: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var tagline: String?
    var icon: String?            // SF Symbol
    var api: Int
    var minOxine: String?
    /// Release asset name per architecture ("arm64" required for external apps).
    var run: [String: String]?
    var surfaces: Surfaces
    var capabilities: [String]?
    var osPermissions: [String]?
    var network: Bool?
    /// One sentence on what the network is for (shown when a viewer hovers the
    /// app page's Network fact). Optional; ignored when `network` is false.
    var networkPurpose: String?

    struct Surfaces: Codable, Equatable, Sendable {
        var panelTab: PanelTabDecl? = nil
        var settings: SettingsDecl? = nil
        var quickToggle: QuickToggleDecl? = nil
        var notchTab: NotchTabDecl? = nil
        var barMetric: BarMetricDecl? = nil
        var peek: Bool? = nil

        struct PanelTabDecl: Codable, Equatable, Sendable { var icon: String? = nil; var title: String? = nil }
        struct SettingsDecl: Codable, Equatable, Sendable { var subtitle: String? = nil }
        struct QuickToggleDecl: Codable, Equatable, Sendable { var icon: String? = nil; var tooltip: String? = nil; var menu: Bool? = nil }
        struct NotchTabDecl: Codable, Equatable, Sendable { var icon: String? = nil; var title: String? = nil }
        struct BarMetricDecl: Codable, Equatable, Sendable { var label: String? = nil }
    }

    /// Grantable capabilities this build of Oxine understands. Unknown strings in
    /// a manifest are surfaced in the store page as "requires a newer Oxine" and
    /// never granted.
    static let knownCapabilities: Set<String> = [
        "storage", "notify", "openURL",
        "clipboard.write", "clipboard.read",
        "system.usage", "sous.state", "temper.metrics",
    ]

    /// Capabilities that default to OFF in the grant sheet and get the scary
    /// styling. Everything else defaults on (still per-app revocable).
    static let sensitiveCapabilities: Set<String> = ["clipboard.read"]

    var wantedCapabilities: [String] { capabilities ?? [] }

    /// Basic sanity: non-empty id/name, a supported api, and (for external apps)
    /// an arm64 binary to run. Returns a human-readable problem or nil.
    func validationError(external: Bool) -> String? {
        if id.isEmpty || name.isEmpty { return "manifest is missing id or name" }
        if api != AppsProtocolVersion { return "app speaks api \(api); this Oxine speaks \(AppsProtocolVersion)" }
        if external && run?["arm64"] == nil { return "manifest has no arm64 binary" }
        if let minOxine, !Self.versionSatisfied(min: minOxine) {
            return "needs Oxine \(minOxine) or newer"
        }
        return nil
    }

    static func versionSatisfied(min: String) -> Bool {
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return current.compare(min, options: .numeric) != .orderedAscending
    }
}

/// The frozen protocol version this build speaks (the `api` field).
let AppsProtocolVersion = 1
