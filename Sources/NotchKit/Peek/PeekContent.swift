import Foundation

/// What a collapsed-notch ear (or the bar) shows. `smart` blends live sources by
/// context; the others pin a single source. Persisted per side.
public enum PeekContent: String, CaseIterable, Identifiable {
    case smart, albumArt, bouncyBars, agentGrid, cpuUsage, off

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .smart: return "Smart"
        case .albumArt: return "Album art"
        case .bouncyBars: return "Bouncy bars"
        case .agentGrid: return "Agent status"
        case .cpuUsage: return "CPU usage"
        case .off: return "Off"
        }
    }

    static var left: PeekContent { read("notchLeftEar", default: .smart) }
    static var right: PeekContent { read("notchRightEar", default: .smart) }
    /// The bar outline that hugs the notch silhouette (non-fullscreen only).
    static var barEnabled: Bool { NotchKit.settingsDefaults.object(forKey: "notchBar") as? Bool ?? false }

    private static func read(_ key: String, default d: PeekContent) -> PeekContent {
        PeekContent(rawValue: NotchKit.settingsDefaults.string(forKey: key) ?? "") ?? d
    }
}
