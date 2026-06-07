import AppKit

/// Now-playing via AppleScript polling of Music and Spotify. No private API — the
/// dependable baseline that works on every macOS, at the cost of only seeing
/// those two players (and a TCC automation prompt per app on first use).
@MainActor
public final class ScriptingBridgeSource: NowPlayingSource {
    public static var isAvailable: Bool { true }
    public var onChange: ((NowPlayingTrack?) -> Void)?

    private var timer: Timer?
    private var last: NowPlayingTrack?
    /// The app that reported the current track — transport targets it.
    private var activeApp = "Spotify"
    private var artworkURL: String?

    public init() {}

    public func start() {
        poll()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() { timer?.invalidate(); timer = nil }

    // MARK: transport

    public func playPause() { run("tell application \"\(activeApp)\" to playpause"); poll() }
    public func next() { run("tell application \"\(activeApp)\" to next track"); poll() }
    public func previous() { run("tell application \"\(activeApp)\" to previous track"); poll() }
    public func seek(to seconds: Double) {
        run("tell application \"\(activeApp)\" to set player position to \(seconds)")
        poll()
    }

    // MARK: polling

    private func poll() {
        // Prefer whichever is actively playing; Spotify first, then Music.
        if let s = query("Spotify"), s.isPlaying { activeApp = "Spotify"; emit(s); return }
        if let m = query("Music"), m.isPlaying { activeApp = "Music"; emit(m); return }
        // Nothing playing — surface a paused track if one exists, else clear.
        if let s = query("Spotify") { activeApp = "Spotify"; emit(s); return }
        if let m = query("Music") { activeApp = "Music"; emit(m); return }
        emit(nil)
    }

    private func emit(_ track: NowPlayingTrack?) {
        if track == nil && last == nil { return }
        // While playing, always push (the scrubber needs fresh position); when
        // paused, only push on a real metadata change.
        if let track, let last, track.sameMeta(as: last), !track.isPlaying { return }
        let titleChanged = track?.title != last?.title
        last = track
        onChange?(track)
        if let track, track.app == "Spotify", titleChanged, let url = artworkURL {
            fetchArtwork(url, into: track)
        }
    }

    /// Query one player without launching it. Returns nil if not running/stopped.
    /// Fields: state, title, artist, album, position(s), duration, [artwork url].
    private func query(_ app: String) -> NowPlayingTrack? {
        let artworkLine = app == "Spotify" ? "& linefeed & (artwork url of current track)" : ""
        let script = """
        if application "\(app)" is running then
          tell application "\(app)"
            if player state is stopped then
              return "stopped"
            end if
            return (player state as string) & linefeed & (name of current track) & linefeed & (artist of current track) & linefeed & (album of current track) & linefeed & (player position as string) & linefeed & (duration of current track as string) \(artworkLine)
          end tell
        else
          return "stopped"
        end if
        """
        guard let out = run(script), out != "stopped" else { return nil }
        let parts = out.components(separatedBy: "\n")
        guard parts.count >= 6 else { return nil }
        artworkURL = parts.count >= 7 ? parts[6] : nil
        let elapsed = Double(parts[4]) ?? 0
        // Spotify reports duration in milliseconds; Music in seconds.
        var duration = Double(parts[5]) ?? 0
        if app == "Spotify" { duration /= 1000 }
        return NowPlayingTrack(
            title: parts[1], artist: parts[2], album: parts[3],
            artwork: last?.app == app ? last?.artwork : nil,
            isPlaying: parts[0].contains("playing"), app: app,
            elapsed: elapsed, duration: duration
        )
    }

    @discardableResult
    private func run(_ source: String) -> String? {
        var err: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err { notchLog("AppleScript error: \(err)") ; return nil }
        return result?.stringValue
    }

    private func fetchArtwork(_ urlString: String, into track: NowPlayingTrack) {
        guard let url = URL(string: urlString) else { return }
        // Capture only Sendable values; re-match against `last` on the main actor.
        let app = track.app, title = track.title
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = downsampledArtwork(data) else { return }
            Task { @MainActor in
                guard let self, var t = self.last, t.app == app, t.title == title else { return }
                t.artwork = image
                self.last = t
                self.onChange?(t)
            }
        }.resume()
    }
}
