import SwiftUI
import CoreImage

/// Owns the chosen now-playing source and republishes its track for the views.
/// Automatic prefers the system-wide adapter; explicit choices use app-directed
/// observation and transport. The same selected feed drives artwork and lyrics.
@MainActor
public final class NowPlayingManager: ObservableObject {
    @Published public private(set) var track: NowPlayingTrack?
    /// Dominant colour of the current artwork — used to tint the player's glass
    /// (colour only, no artwork behind it).
    @Published public private(set) var tint: Color = .clear
    /// When `track.elapsed` was last measured, so the scrubber can interpolate
    /// smoothly between the (coarse) source updates.
    @Published public private(set) var elapsedAt: Date = .init()

    @Published public private(set) var selectedPlayer: PlaybackPlayer
    private var source: NowPlayingSource
    private let makeSource: ((PlaybackPlayer) -> NowPlayingSource)?
    private let saveSelection: ((PlaybackPlayer) -> Void)?
    private var sourceGeneration = UUID()
    private var started = false

    public convenience init() {
        let defaults = NotchKit.settingsDefaults
        let selection = PlaybackPlayer(rawValue: defaults.string(forKey: "notchPlaybackPlayer") ?? "") ?? .automatic
        let preferSystem = (defaults.string(forKey: "notchNowPlayingSource") ?? "system") == "system"
        let factory: (PlaybackPlayer) -> NowPlayingSource = { player in
            if player == .automatic, preferSystem, MediaRemoteAdapterSource.isAvailable {
                return MediaRemoteAdapterSource()
            }
            return ScriptingBridgeSource(player: player)
        }
        self.init(source: factory(selection), selectedPlayer: selection, makeSource: factory,
                  saveSelection: { defaults.set($0.rawValue, forKey: "notchPlaybackPlayer") })
    }

    init(source: NowPlayingSource, selectedPlayer: PlaybackPlayer = .automatic,
         makeSource: ((PlaybackPlayer) -> NowPlayingSource)? = nil,
         saveSelection: ((PlaybackPlayer) -> Void)? = nil) {
        self.source = source
        self.selectedPlayer = selectedPlayer
        self.makeSource = makeSource
        self.saveSelection = saveSelection
        observeSource()
    }

    private func observeSource() {
        let generation = sourceGeneration
        source.onChange = { [weak self] incoming in
            guard let self, self.sourceGeneration == generation else { return }
            self.receive(incoming)
        }
    }

    private func receive(_ track: NowPlayingTrack?) {
        let titleChanged = track?.title != self.track?.title || track?.artist != self.track?.artist
        let artworkChanged = track?.artwork !== self.track?.artwork
        self.track = track
        elapsedAt = track?.elapsedAt ?? Date()
        // Artwork may arrive independently; retained identity avoids work on clock updates.
        if titleChanged || artworkChanged {
            let newTint = track?.artwork?.dominantColor().map { Color(nsColor: $0) } ?? .clear
            withAnimation(.easeInOut(duration: 0.5)) { tint = newTint }
        }
    }

    /// Change observation and transport together, without starting/stopping playback.
    public func cyclePlayer() {
        let players = PlaybackPlayer.allCases
        guard let index = players.firstIndex(of: selectedPlayer) else { return }
        selectPlayer(players[(index + 1) % players.count])
    }

    public func selectPlayer(_ player: PlaybackPlayer) {
        guard player != selectedPlayer, let makeSource else { return }
        sourceGeneration = UUID()
        source.onChange = nil
        source.stop()
        receive(nil) // Cancel old lyric requests and discard the old clock/artwork.
        selectedPlayer = player
        saveSelection?(player)
        source = makeSource(player)
        observeSource()
        if started { source.start() }
    }

    public func start() {
        guard !started else { return }
        started = true
        observeSource()
        source.start()
    }
    public func stop() {
        started = false
        sourceGeneration = UUID()
        source.onChange = nil
        source.stop()
        receive(nil)
    }

    public func playPause() { if track != nil { source.playPause() } }
    public func next() { if track != nil { source.next() } }
    public func previous() { if track != nil { source.previous() } }
    public func seek(to seconds: Double) {
        guard track != nil, seconds.isFinite else { return }
        source.seek(to: max(0, seconds))
    }

    /// Current position, interpolated from the last measurement so the scrubber
    /// advances smoothly between source updates.
    public func position(at date: Date) -> Double {
        guard let track, track.hasPlaybackPosition, track.elapsed.isFinite else { return 0 }
        let rate = track.playbackRate.isFinite ? max(0, track.playbackRate) : 1
        let advanced = track.elapsed + (track.isPlaying ? max(0, date.timeIntervalSince(elapsedAt)) * rate : 0)
        return min(max(advanced, 0), track.duration.isFinite && track.duration > 0 ? track.duration : max(advanced, 0))
    }

    public var isPlaying: Bool { track?.isPlaying ?? false }
}

/// One shared CIContext — creating one per call (as `dominantColor` did) is costly
/// and was a needless hitch each time the tint recomputed.
private let sharedTintContext = CIContext(options: [.workingColorSpace: NSNull()])

extension NSImage {
    /// Average colour of the image (one CIAreaAverage pass), nudged to stay
    /// vivid-but-not-blinding so it reads well as a glass tint.
    func dominantColor() -> NSColor? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage else { return nil }
        let ci = CIImage(cgImage: cg)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ci,
            kCIInputExtentKey: CIVector(cgRect: ci.extent)
        ]), let out = filter.outputImage else { return nil }

        var px = [UInt8](repeating: 0, count: 4)
        sharedTintContext.render(
            out, toBitmap: &px, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())

        let base = NSColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255,
                           blue: CGFloat(px[2]) / 255, alpha: 1)
        // Pull toward a mid brightness / decent saturation so dull or near-black
        // covers still give a usable tint.
        guard let c = base.usingColorSpace(.deviceRGB) else { return base }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
        return NSColor(hue: h, saturation: min(max(s, 0.4), 0.85),
                       brightness: min(max(b, 0.45), 0.8), alpha: 1)
    }
}
