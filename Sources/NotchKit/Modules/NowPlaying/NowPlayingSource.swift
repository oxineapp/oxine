import AppKit
import ImageIO

/// Decode and downsample artwork data to a small thumbnail in one ImageIO pass.
/// Players (especially video) hand us full-res frames; `NSImage(data:)` defers the
/// decode to first *draw*, so the full image was being decoded + resampled on the
/// main thread the moment the notch opened — the open-stutter. A ~320px thumbnail
/// is ample for the player (~100pt) and ears (22pt) and draws instantly.
func downsampledArtwork(_ data: Data, maxPixel: CGFloat = 320) -> NSImage? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
        return NSImage(data: data)
    }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
        return NSImage(data: data)
    }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

/// A snapshot of what's playing system-wide. Artwork is optional — not every
/// source can supply it cheaply.
public struct NowPlayingTrack {
    public var title: String
    public var artist: String
    public var album: String
    public var artwork: NSImage?
    public var isPlaying: Bool
    /// Bundle id or app name of the player, so transport commands target it.
    public var app: String?
    /// Playback position + length in seconds (0 if the source can't report them).
    public var elapsed: Double
    public var duration: Double

    public init(title: String, artist: String, album: String = "",
                artwork: NSImage? = nil, isPlaying: Bool, app: String? = nil,
                elapsed: Double = 0, duration: Double = 0) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artwork = artwork
        self.isPlaying = isPlaying
        self.app = app
        self.elapsed = elapsed
        self.duration = duration
    }

    /// Change detection ignores artwork identity (compared separately when set).
    public func sameMeta(as other: NowPlayingTrack) -> Bool {
        title == other.title && artist == other.artist &&
        album == other.album && isPlaying == other.isPlaying && app == other.app
    }
}

/// A provider of system now-playing info + transport. Two ship today: a
/// ScriptingBridge poller (Music/Spotify, no private API) and the vendored
/// mediaremote-adapter (system-wide). The manager picks one at runtime; new
/// providers (a future MPRIS-style bridge, etc.) just conform here.
@MainActor
public protocol NowPlayingSource: AnyObject {
    /// True if this source can actually run on this machine right now.
    static var isAvailable: Bool { get }
    /// Pushed whenever the track or play-state changes (nil = nothing playing).
    var onChange: ((NowPlayingTrack?) -> Void)? { get set }

    func start()
    func stop()

    func playPause()
    func next()
    func previous()
    /// Seek to a position in seconds (no-op for sources that can't seek).
    func seek(to seconds: Double)
}

public extension NowPlayingSource {
    func seek(to seconds: Double) {}
}
