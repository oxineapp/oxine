import Foundation

/// What Automatic reads Spotify and Music through: the AppleScript reader in the
/// app, a fake in tests.
@MainActor
protocol PlayerReader: NowPlayingSource {
    /// Players the last read reached, by scripting name ("Spotify", "Music").
    var readableApps: Set<String> { get }
    func refresh()
}

extension ScriptingBridgeSource: PlayerReader {}

/// Automatic: the system's now-playing feed, checked against Spotify and Music
/// themselves. macOS hands the feed to whichever app last started playing and
/// leaves it there: a video on X that played for a moment keeps it (paused, or
/// empty once the tab lets go) while Spotify plays on, until Spotify's next song.
/// It can also fall back to Spotify's details from when Spotify lost the feed,
/// a clock that runs on past the end of the song. So:
///   • the feed playing an app Oxine can't ask (a browser video) → the feed;
///   • Spotify or Music playing → that player, read directly;
///   • otherwise whatever is paused: the feed, unless it names a player that
///     can answer for itself.
/// The reader only asks players Oxine is already allowed to automate, so this
/// never raises a prompt; without that permission it's the feed alone.
@MainActor
final class AutomaticSource: NowPlayingSource {
    static var isAvailable: Bool { MediaRemoteAdapterSource.isAvailable }
    var onChange: ((NowPlayingTrack?) -> Void)?

    private let feed: NowPlayingSource
    private let reader: PlayerReader
    private var feedTrack: NowPlayingTrack?
    private var readerTrack: NowPlayingTrack?
    /// Where the shown track came from; transport goes there too.
    private var showingReader = false
    private var running = false

    init(feed: NowPlayingSource, reader: PlayerReader) {
        self.feed = feed
        self.reader = reader
    }

    convenience init() {
        self.init(feed: MediaRemoteAdapterSource(),
                  reader: ScriptingBridgeSource(player: .automatic, onlyIfAllowed: true))
    }

    func start() {
        guard !running else { return }
        running = true
        feed.onChange = { [weak self] in self?.feedChanged($0) }
        reader.onChange = { [weak self] in
            self?.readerTrack = $0
            self?.publish(changedReader: true)
        }
        feed.start()
        reader.start()
    }

    func stop() {
        running = false
        feed.onChange = nil
        reader.onChange = nil
        feed.stop()
        reader.stop()
        feedTrack = nil; readerTrack = nil; showingReader = false
    }

    private var active: NowPlayingSource { showingReader ? reader : feed }
    func playPause() { active.playPause() }
    func next() { active.next() }
    func previous() { active.previous() }
    func seek(to seconds: Double) { active.seek(to: seconds) }

    private func feedChanged(_ track: NowPlayingTrack?) {
        let newSong = track?.title != feedTrack?.title || track?.app != feedTrack?.app
        feedTrack = track
        // The feed hears about a new song first: read the player now, so the
        // two agree without waiting for the reader's next tick.
        if newSong, readableName(track?.app) != nil { reader.refresh() }
        publish(changedReader: false)
    }

    /// The feed's app by its scripting name, when the reader can read it right now.
    private func readableName(_ app: String?) -> String? {
        guard let app,
              let name = PlaybackPlayer.allCases.first(where: { $0.bundleIdentifier == app })?.scriptingApp,
              reader.readableApps.contains(name) else { return nil }
        return name
    }

    private func publish(changedReader: Bool) {
        let useReader: Bool
        if let feed = feedTrack, feed.isPlaying, readableName(feed.app) == nil {
            useReader = false
        } else if readerTrack?.isPlaying == true {
            useReader = true
        } else if let feed = feedTrack, readableName(feed.app) == nil {
            useReader = false
        } else {
            useReader = true
        }
        // Only the side on screen (or a switch between sides) is news.
        guard useReader != showingReader || useReader == changedReader else { return }
        showingReader = useReader
        onChange?(useReader ? readerTrack : feedTrack)
    }
}
