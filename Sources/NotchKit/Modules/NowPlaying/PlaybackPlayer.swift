import Foundation

/// Explicit app choices use app-directed observation and transport. Automatic
/// follows the active macOS media session, including browser media.
public enum PlaybackPlayer: String, CaseIterable, Identifiable {
    case automatic, spotify, music

    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .automatic: "Automatic"
        case .spotify: "Spotify"
        case .music: "Apple Music"
        }
    }

    var scriptingApp: String? {
        switch self {
        case .automatic: nil
        case .spotify: "Spotify"
        case .music: "Music"
        }
    }
}
