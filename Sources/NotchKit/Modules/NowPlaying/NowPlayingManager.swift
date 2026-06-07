import SwiftUI
import CoreImage

/// Owns the chosen now-playing source and republishes its track for the views.
/// Prefers the system-wide adapter when its resources are bundled; otherwise the
/// ScriptingBridge baseline. Both conform to `NowPlayingSource`, so swapping is
/// a one-line decision here.
@MainActor
public final class NowPlayingManager: ObservableObject {
    @Published public private(set) var track: NowPlayingTrack?
    /// Dominant colour of the current artwork — used to tint the player's glass
    /// (colour only, no artwork behind it).
    @Published public private(set) var tint: Color = .clear
    /// When `track.elapsed` was last measured, so the scrubber can interpolate
    /// smoothly between the (coarse) source updates.
    @Published public private(set) var elapsedAt: Date = .init()

    private let source: NowPlayingSource

    public init() {
        // "system" = system-wide via the mediaremote-adapter (any app, incl.
        // browsers); "apps" = Music & Spotify only via ScriptingBridge. Defaults
        // to system-wide when the adapter is bundled, else the app baseline.
        let pref = NotchKit.settingsDefaults.string(forKey: "notchNowPlayingSource") ?? "system"
        if pref == "system", MediaRemoteAdapterSource.isAvailable {
            source = MediaRemoteAdapterSource()
            notchLog("now playing: mediaremote-adapter (system-wide)")
        } else {
            source = ScriptingBridgeSource()
            notchLog("now playing: ScriptingBridge (Music/Spotify)")
        }
        source.onChange = { [weak self] incoming in
            guard let self else { return }
            var track = incoming
            // Resilience: players (notably Spotify over AppleScript, and some
            // MediaRemote apps) occasionally report position 0 mid-track. Don't let
            // that snap the scrubber back to the start — carry the position we'd
            // already interpolated to for the same playing track.
            if var t = track, let old = self.track,
               t.app == old.app, t.title == old.title, t.isPlaying,
               t.duration > 1, t.elapsed < 0.5 {
                let carried = self.position(at: Date())   // from the prior sample
                if carried > 1 { t.elapsed = carried; track = t }
            }
            let titleChanged = track?.title != self.track?.title
            self.track = track
            self.elapsedAt = Date()
            // Only recompute the (relatively costly) tint when the track changes.
            if titleChanged {
                let newTint = track?.artwork?.dominantColor().map { Color(nsColor: $0) } ?? .clear
                withAnimation(.easeInOut(duration: 0.5)) { self.tint = newTint }
            }
        }
    }

    public func start() { source.start() }
    public func stop() { source.stop() }

    public func playPause() { source.playPause() }
    public func next() { source.next() }
    public func previous() { source.previous() }
    public func seek(to seconds: Double) { source.seek(to: seconds) }

    /// Current position, interpolated from the last measurement so the scrubber
    /// advances smoothly between source updates.
    public func position(at date: Date) -> Double {
        guard let track else { return 0 }
        guard track.isPlaying else { return track.elapsed }
        let advanced = track.elapsed + date.timeIntervalSince(elapsedAt)
        return min(max(advanced, 0), track.duration > 0 ? track.duration : advanced)
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
