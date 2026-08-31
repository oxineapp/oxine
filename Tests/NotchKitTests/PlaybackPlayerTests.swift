import AppKit
import Testing
import LyricsCore
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
        return playbackDescriptor(state: "paused", elapsed: 20, duration: 180000)
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

private func playbackDescriptor(state: String = "playing", elapsed: Double, duration: Double,
                                title: String = "Song") -> NSAppleEventDescriptor {
    let list = NSAppleEventDescriptor.list()
    let fields: [NSAppleEventDescriptor] = [.init(string: state), .init(string: title),
        .init(string: "Artist"), .init(string: "Album"), .init(double: elapsed),
        .init(double: duration), .init(string: "")]
    for (index, field) in fields.enumerated() { list.insert(field, at: index + 1) }
    return list
}

@MainActor @Test
func numericSpotifyPositionDrivesLyricsWithoutLocaleOrNewlineCoercion() throws {
    let source = ScriptingBridgeSource(player: .spotify) { _ in
        playbackDescriptor(elapsed: 45.75, duration: 217573, title: "Song\nLive")
    }
    let manager = NowPlayingManager(source: source, selectedPlayer: .spotify)
    manager.start()
    let track = try #require(manager.track)
    #expect(track.title == "Song\nLive")
    #expect(track.hasPlaybackPosition && track.elapsed == 45.75)
    #expect(abs(track.duration - 217.573) < 0.001)
    let position = manager.position(at: try #require(track.elapsedAt))
    let lyrics = LRC.parse("[00:00]intro\n[00:30]verse\n[00:45]chorus")
    #expect(LRC.line(in: lyrics, position: position, adjustment: 0) == "chorus")
    manager.stop()
}

@MainActor @Test
func unavailableNumericPositionDoesNotInventLyricsAtZero() {
    let result = playbackDescriptor(elapsed: 30, duration: 200)
    result.remove(at: 5)
    result.insert(NSAppleEventDescriptor.null(), at: 5)
    let source = ScriptingBridgeSource(player: .music) { _ in result }
    let manager = NowPlayingManager(source: source, selectedPlayer: .music)
    manager.start()
    #expect(manager.track?.hasPlaybackPosition == false)
    manager.stop()
}

@MainActor @Test
func nativePlayerButtonCyclesAndContextMenuOnlyChangesSourceOnSelection() throws {
    let source = SelectablePlaybackSource()
    let manager = NowPlayingManager(source: source, makeSource: { _ in SelectablePlaybackSource() })
    let button = NotchClickButton()
    button.onPress = { manager.cyclePlayer() }
    button.contextMenu = { manager.playbackMenu() }
    #expect(button.acceptsFirstMouse(for: nil))
    button.performClick(nil)
    #expect(manager.selectedPlayer == .spotify)
    let menu = try #require(button.contextMenu?())
    #expect(manager.selectedPlayer == .spotify) // Opening the menu must not cycle.
    #expect(menu.items[1].state == .on)
    let musicItem = try #require(menu.items[2] as? PlaybackMenuItem)
    musicItem.choose()
    #expect(manager.selectedPlayer == .music)
    button.performClick(nil)
    #expect(manager.selectedPlayer == .automatic)
    #expect(source.commands.isEmpty)
}
