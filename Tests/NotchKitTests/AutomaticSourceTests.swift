import Foundation
import Testing
@testable import NotchKit

@MainActor
private class FakeSource: NowPlayingSource {
    static var isAvailable: Bool { true }
    var onChange: ((NowPlayingTrack?) -> Void)?
    var commands: [String] = []
    func start() {}
    func stop() {}
    func playPause() { commands.append("toggle") }
    func next() { commands.append("next") }
    func previous() { commands.append("previous") }
    func seek(to seconds: Double) { commands.append("seek:\(seconds)") }
    func emit(_ title: String?, playing: Bool = true, app: String, elapsed: Double = 10) {
        onChange?(title.map {
            NowPlayingTrack(title: $0, artist: "Artist", isPlaying: playing, app: app,
                            elapsed: elapsed, duration: 180, elapsedAt: Date())
        })
    }
}

@MainActor
private final class FakeReader: FakeSource, PlayerReader {
    var readableApps: Set<String> = ["Spotify"]
    var refreshes = 0
    func refresh() { refreshes += 1 }
}

@MainActor
private func automatic() -> (NowPlayingManager, FakeSource, FakeReader) {
    let feed = FakeSource(), reader = FakeReader()
    let manager = NowPlayingManager(source: AutomaticSource(feed: feed, reader: reader))
    manager.start()
    return (manager, feed, reader)
}

@MainActor @Test
func spotifyPlayingWinsOverAPausedVideoHoldingTheSystemFeed() {
    let (manager, feed, reader) = automatic()
    feed.emit("A post on X", playing: false, app: "com.google.Chrome")
    reader.emit("Ne Var Ne Yok", app: "Spotify")
    #expect(manager.track?.title == "Ne Var Ne Yok")
    manager.playPause()
    #expect(reader.commands == ["toggle"])
    #expect(feed.commands.isEmpty)
}

@MainActor @Test
func spotifyPlayingShowsWhenTheSystemFeedIsEmpty() {
    let (manager, feed, reader) = automatic()
    reader.emit("Ne Var Ne Yok", app: "Spotify")
    feed.emit(nil, app: "")
    #expect(manager.track?.title == "Ne Var Ne Yok")
}

@MainActor @Test
func aPlayingBrowserVideoStillShowsOverSpotify() {
    let (manager, feed, reader) = automatic()
    reader.emit("Ne Var Ne Yok", app: "Spotify")
    feed.emit("A video", app: "com.google.Chrome")
    #expect(manager.track?.title == "A video")
    manager.next()
    #expect(feed.commands == ["next"])
}

@MainActor @Test
func aStaleSpotifySnapshotInTheFeedDefersToSpotifyItself() {
    let (manager, feed, reader) = automatic()
    // The feed fell back to Spotify's details from minutes ago, still "playing".
    feed.emit("Old song", app: "com.spotify.client", elapsed: 170)
    reader.emit("Old song", playing: false, app: "Spotify", elapsed: 42)
    #expect(manager.track?.isPlaying == false)
    #expect(manager.track?.elapsed == 42)
}

@MainActor @Test
func withoutPermissionForSpotifyTheFeedIsTrusted() {
    let (manager, feed, reader) = automatic()
    reader.readableApps = []
    feed.emit("Ne Var Ne Yok", app: "com.spotify.client")
    #expect(manager.track?.title == "Ne Var Ne Yok")
    #expect(reader.refreshes == 0)
}

@MainActor @Test
func aNewSongInTheFeedAsksSpotifyRightAway() {
    let (manager, feed, reader) = automatic()
    reader.emit("First", app: "Spotify")
    feed.emit("Second", app: "com.spotify.client")
    #expect(reader.refreshes == 1)
    #expect(manager.track?.title == "First")   // until Spotify's own answer comes back
}
