import AppKit
import Testing
@testable import NotchKit

@MainActor
private final class SelectablePlaybackSource: NowPlayingSource {
    static var isAvailable: Bool { true }
    var onChange: ((NowPlayingTrack?) -> Void)?
    var starts = 0, stops = 0
    var commands: [String] = []
    func start() { starts += 1 }
    func stop() { stops += 1 }
    func playPause() { commands.append("toggle") }
    func next() { commands.append("next") }
    func previous() { commands.append("previous") }
    func seek(to seconds: Double) { commands.append("seek:\(seconds)") }
    func emit(_ title: String, position: Double) {
        onChange?(NowPlayingTrack(title: title, artist: "Artist", isPlaying: true,
                                  elapsed: position, duration: 300,
                                  elapsedAt: Date(timeIntervalSince1970: 1_000)))
    }
}

@MainActor @Test
func playerSwitchClearsOldSongAndRejectsLateUpdatesWhileRoutingAllControls() {
    let automatic = SelectablePlaybackSource(), spotify = SelectablePlaybackSource()
    var saved: [PlaybackPlayer] = []
    let manager = NowPlayingManager(source: automatic,
        makeSource: { $0 == .spotify ? spotify : automatic }, saveSelection: { saved.append($0) })
    manager.start()
    automatic.emit("Browser video", position: 150)
    let lateCallback = automatic.onChange
    manager.selectPlayer(.spotify)
    #expect(manager.track == nil)
    #expect(manager.position(at: Date(timeIntervalSince1970: 1_005)) == 0)
    #expect(automatic.stops == 1 && spotify.starts == 1)
    #expect(saved == [.spotify])
    lateCallback?(NowPlayingTrack(title: "Stale browser video", artist: "", isPlaying: true))
    #expect(manager.track == nil)
    manager.playPause() // No selected track: do not launch or control another app.
    #expect(spotify.commands.isEmpty)
    spotify.emit("Selected song", position: 20)
    #expect(manager.position(at: Date(timeIntervalSince1970: 1_005)) == 25)
    manager.playPause(); manager.next(); manager.previous(); manager.seek(to: 42)
    #expect(automatic.commands.isEmpty)
    #expect(spotify.commands == ["toggle", "next", "previous", "seek:42.0"])
    manager.selectPlayer(.automatic)
    #expect(manager.track == nil)
    automatic.emit("Current browser video", position: 180)
    #expect(manager.track?.title == "Current browser video")
    #expect(spotify.stops == 1 && automatic.starts == 2)
    manager.stop()
}

@MainActor @Test
func samePlayerSelectionDoesNotRestartPlaybackObservationAndStopRejectsOldCallbacks() {
    let source = SelectablePlaybackSource()
    let manager = NowPlayingManager(source: source, makeSource: { _ in source })
    manager.start(); manager.start()
    source.emit("Song", position: 90)
    manager.selectPlayer(.automatic)
    #expect(source.starts == 1 && source.stops == 0)
    #expect(manager.track?.elapsed == 90)
    let late = source.onChange
    manager.stop()
    late?(NowPlayingTrack(title: "Old", artist: "", isPlaying: true))
    #expect(manager.track == nil)
    manager.start()
    source.emit("New", position: 0)
    #expect(source.starts == 2 && manager.track?.title == "New")
    manager.stop()
}

@MainActor @Test
func selectionBeforeStartIsRememberedWithoutStartingAnObserver() {
    let original = SelectablePlaybackSource(), chosen = SelectablePlaybackSource()
    let manager = NowPlayingManager(source: original, makeSource: { _ in chosen })
    manager.selectPlayer(.music)
    #expect(manager.selectedPlayer == .music)
    #expect(chosen.starts == 0)
    manager.start()
    #expect(chosen.starts == 1 && original.starts == 0)
    manager.stop()
}

@MainActor @Test
func pinnedSpotifyNeverQueriesMusicAndControlsSpotifyEvenWhenPaused() {
    var scripts: [String] = []
    let source = ScriptingBridgeSource(player: .spotify) { script in
        scripts.append(script)
        return NSAppleEventDescriptor(string: "paused\nSong\nArtist\nAlbum\n20\n180000\n")
    }
    var track: NowPlayingTrack?
    source.onChange = { track = $0 }
    source.start()
    #expect(track?.app == "Spotify" && track?.isPlaying == false)
    #expect(track?.duration == 180 && track?.elapsed == 20)
    source.playPause(); source.next(); source.previous(); source.seek(to: 45)
    #expect(scripts.allSatisfy { $0.contains("application \"Spotify\"") && !$0.contains("application \"Music\"") })
    #expect(scripts.contains { $0.contains("set player position to 45.0") })
    source.stop()
}

@MainActor @Test
func missingPinnedMusicDoesNotFallBackToSpotify() {
    var scripts: [String] = []
    let source = ScriptingBridgeSource(player: .music) { script in
        scripts.append(script)
        return NSAppleEventDescriptor(string: "stopped")
    }
    let manager = NowPlayingManager(source: source, selectedPlayer: .music)
    manager.start()
    #expect(manager.track == nil)
    #expect(scripts.count == 1 && scripts[0].contains("application \"Music\""))
    manager.playPause()
    #expect(scripts.count == 1)
    manager.stop()
}
