import AppKit

/// Now-playing via AppleScript polling of Music and Spotify. No private API — the
/// dependable baseline that works on every macOS, at the cost of only seeing
/// those two players (and a TCC automation prompt per app on first use).
///
/// Every Apple event runs on a private serial queue, never the main thread: the
/// first event to a player raises the macOS Automation prompt, and an Apple
/// event blocks its sending thread until the user answers (or the two-minute
/// timeout). Sent from the main thread that froze the whole app — the notch, the
/// panel, everything — the moment someone picked Spotify from the source menu.
/// Off-main, the prompt just sits there while Oxine keeps running.
@MainActor
public final class ScriptingBridgeSource: NowPlayingSource {
    public static var isAvailable: Bool { true }
    public var onChange: ((NowPlayingTrack?) -> Void)?

    /// Runs one AppleScript source and returns its result descriptor. Injected
    /// so tests can feed canned descriptors without touching the players.
    typealias Executor = @Sendable (String) -> NSAppleEventDescriptor?

    private var timer: Timer?
    private var last: NowPlayingTrack?
    /// The app that reported the current track — transport targets it.
    private var activeApp = "Spotify"
    private var artworkURL: String?
    private let player: PlaybackPlayer
    private let runner: ScriptRunner
    private var lastClockAvailability: Bool?
    /// One poll in flight at a time: while an automation prompt blocks the
    /// queue, the 2s timer must not pile up a backlog behind it.
    private var polling = false
    /// Bumped on stop() so late results from a previous life are discarded.
    private var generation = 0

    public convenience init(player: PlaybackPlayer = .automatic) {
        self.init(player: player, executeScript: Self.execute, inline: false)
    }

    /// `inline` runs scripts synchronously on the caller (tests); production
    /// uses the background queue.
    init(player: PlaybackPlayer, executeScript: @escaping Executor, inline: Bool = true) {
        self.player = player
        self.runner = ScriptRunner(executor: executeScript, inline: inline)
        self.activeApp = player.scriptingApp ?? "Spotify"
    }

    public func start() {
        guard timer == nil else { return }
        poll()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stop() {
        timer?.invalidate(); timer = nil
        last = nil; artworkURL = nil
        lastClockAvailability = nil
        polling = false
        generation += 1
    }

    // MARK: transport

    public func playPause() { run("tell application \"\(activeApp)\" to playpause") }
    public func next() { run("tell application \"\(activeApp)\" to next track") }
    public func previous() { run("tell application \"\(activeApp)\" to previous track") }
    public func seek(to seconds: Double) {
        run("tell application \"\(activeApp)\" to set player position to \(seconds)")
    }

    /// Fire-and-forget command, then a fresh poll so the UI reflects it.
    private func run(_ source: String) {
        let gen = generation
        runner.run({ exec in _ = exec(source) }) { [weak self] _ in
            guard let self, self.generation == gen else { return }
            self.poll()
        }
    }

    // MARK: polling

    /// One player's state as read by AppleScript — plain values only, so it can
    /// cross from the script queue back to the main actor.
    private struct Snapshot: Sendable {
        var app: String
        var isPlaying: Bool
        var title: String, artist: String, album: String
        var elapsed: Double?
        var duration: Double
        var artworkURL: String?
    }

    private func poll() {
        guard !polling else { return }
        polling = true
        let gen = generation
        // A pinned player never falls through to a different playing app.
        let apps = player.scriptingApp.map { [$0] } ?? ["Spotify", "Music"]
        runner.run({ exec in apps.compactMap { Self.query($0, exec) } }) { [weak self] snapshots in
            guard let self, self.generation == gen else { return }
            self.polling = false
            self.apply(snapshots)
        }
    }

    private func apply(_ snapshots: [Snapshot]) {
        // Prefer whichever is actively playing (Spotify first, then Music);
        // otherwise surface a paused track if one exists, else clear.
        guard let chosen = snapshots.first(where: \.isPlaying) ?? snapshots.first else {
            emit(nil)
            return
        }
        activeApp = chosen.app
        artworkURL = chosen.artworkURL
        if lastClockAvailability != (chosen.elapsed != nil) {
            lastClockAvailability = chosen.elapsed != nil
            notchLog("\(chosen.app) playback clock available: \(chosen.elapsed != nil)")
        }
        let sameTrack = last?.app == chosen.app && last?.title == chosen.title
            && last?.artist == chosen.artist && last?.album == chosen.album
        emit(NowPlayingTrack(
            title: chosen.title, artist: chosen.artist, album: chosen.album,
            artwork: sameTrack ? last?.artwork : nil,
            isPlaying: chosen.isPlaying, app: chosen.app,
            elapsed: chosen.elapsed ?? 0, duration: chosen.duration, elapsedAt: Date(),
            hasPlaybackPosition: chosen.elapsed != nil))
    }

    private func emit(_ track: NowPlayingTrack?) {
        if track == nil && last == nil { return }
        // While playing, always push (the scrubber needs fresh position); when
        // paused, only push on a real metadata change.
        if let track, let last, track.sameMeta(as: last), !track.isPlaying, track.elapsed == last.elapsed { return }
        let titleChanged = track?.title != last?.title || track?.artist != last?.artist ||
            track?.album != last?.album || track?.app != last?.app
        last = track
        onChange?(track)
        guard let track, titleChanged else { return }
        if track.app == "Spotify", let url = artworkURL {
            fetchArtwork(url, into: track)
        } else if track.app == "Music" {
            fetchMusicArtwork(into: track)
        }
    }

    /// Query one player without launching it. Returns nil if not running/stopped.
    /// Fields: state, title, artist, album, position(s), duration, [artwork url].
    /// Runs on the script queue — touches nothing on the actor.
    private nonisolated static func query(_ app: String, _ exec: Executor) -> Snapshot? {
        let artworkLine = app == "Spotify" ? ", (artwork url of current track)" : ""
        let script = """
        if application "\(app)" is running then
          tell application "\(app)"
            if player state is stopped then
              return "stopped"
            end if
            return {(player state as string), (name of current track), (artist of current track), (album of current track), player position, duration of current track\(artworkLine)}
          end tell
        else
          return "stopped"
        end if
        """
        // Keep numeric Apple events numeric. String coercion is locale-sensitive
        // (e.g. 34,75 in en_TR), and newline-delimited metadata can split titles.
        guard let result = exec(script), result.descriptorType == typeAEList,
              result.numberOfItems >= 6 else { return nil }
        func text(_ index: Int) -> String { result.atIndex(index)?.stringValue ?? "" }
        func number(_ index: Int) -> Double? {
            guard let item = result.atIndex(index), item.descriptorType != typeNull,
                  let value = item.coerce(toDescriptorType: typeIEEE64BitFloatingPoint)?.doubleValue,
                  value.isFinite, value >= 0 else { return nil }
            return value
        }
        var duration = number(6) ?? 0
        if app == "Spotify" { duration /= 1000 }
        return Snapshot(app: app, isPlaying: text(1) == "playing",
                        title: text(2), artist: text(3), album: text(4),
                        elapsed: number(5), duration: duration,
                        artworkURL: result.numberOfItems >= 7 ? text(7) : nil)
    }

    private nonisolated static func execute(_ source: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err { notchLog("AppleScript error: \(err)"); return nil }
        return result
    }

    // MARK: artwork

    /// Apple Music exposes image bytes directly, rather than an artwork URL.
    private func fetchMusicArtwork(into track: NowPlayingTrack) {
        let gen = generation
        let key = (track.app, track.title, track.artist, track.album)
        let script = """
        if application "Music" is running then
          tell application "Music" to get raw data of artwork 1 of current track
        end if
        """
        runner.run({ exec in exec(script)?.data }) { [weak self] data in
            guard let self, self.generation == gen, let data,
                  var t = self.last, (t.app, t.title, t.artist, t.album) == key,
                  let image = downsampledArtwork(data) else { return }
            t.artwork = image
            self.last = t
            self.onChange?(t)
        }
    }

    private func fetchArtwork(_ urlString: String, into track: NowPlayingTrack) {
        guard let url = URL(string: urlString) else { return }
        // Capture only Sendable values; re-match against `last` on the main actor.
        let app = track.app, title = track.title, artist = track.artist, album = track.album
        let gen = generation
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data else { return }
            Task { @MainActor in
                guard let self, self.generation == gen, var t = self.last,
                      t.app == app, t.title == title, t.artist == artist, t.album == album,
                      let image = downsampledArtwork(data) else { return }
                t.artwork = image
                self.last = t
                self.onChange?(t)
            }
        }.resume()
    }
}

/// Serial, off-main AppleScript execution. `@unchecked Sendable`: the executor
/// is only ever invoked on the private queue (or inline, for tests), and only
/// Sendable results cross back to the main actor.
private final class ScriptRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.oxine.notch.applescript", qos: .userInitiated)
    private let executor: ScriptingBridgeSource.Executor
    private let inline: Bool

    init(executor: @escaping ScriptingBridgeSource.Executor, inline: Bool) {
        self.executor = executor
        self.inline = inline
    }

    /// Run `work` with the executor, then hand its (Sendable) result to
    /// `completion` on the main actor.
    @MainActor
    func run<T: Sendable>(_ work: @escaping @Sendable (ScriptingBridgeSource.Executor) -> T,
                          completion: @escaping @MainActor (T) -> Void) {
        if inline {
            completion(work(executor))
            return
        }
        let executor = self.executor
        queue.async {
            let result = work(executor)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(result) }
            }
        }
    }
}
