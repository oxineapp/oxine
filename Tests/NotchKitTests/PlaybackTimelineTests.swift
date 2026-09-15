import Testing
import Foundation
import LyricsCore
@testable import NotchKit

@MainActor
private func update(_ source: MediaRemoteAdapterSource, _ payload: [String: Any], at: Double, diff: Bool = true) throws {
    let data = try JSONSerialization.data(withJSONObject: ["payload": payload, "diff": diff])
    source.parse(data, receivedAt: Date(timeIntervalSince1970: at))
}

@MainActor
private func playing(_ source: MediaRemoteAdapterSource, elapsed: Double = 30, at: Double = 1_000) throws {
    try update(source, ["title": "Song", "artist": "Artist", "album": "Album", "bundleIdentifier": "test.player",
                        "playing": true, "elapsedTimeMicros": elapsed * 1_000_000,
                        "timestampEpochMicros": at * 1_000_000, "durationMicros": 300_000_000], at: at + 8, diff: false)
}

@MainActor @Test
func playbackUsesSourceTimestampAndMetadataDoesNotRewindLyrics() throws {
    let source = MediaRemoteAdapterSource()
    let manager = NowPlayingManager(source: source)
    try playing(source)
    #expect(manager.position(at: Date(timeIntervalSince1970: 1_008)) == 38)
    try update(source, ["artworkData": "", "genre": "Pop"], at: 1_020)
    #expect(manager.position(at: Date(timeIntervalSince1970: 1_020)) == 50)
    let lyrics = LRC.parse("[00:00]intro\n[00:30]verse\n[00:45]chorus")
    #expect(LRC.line(in: lyrics, position: manager.position(at: Date(timeIntervalSince1970: 1_020)), adjustment: 0) == "chorus")
}

@MainActor @Test
func seekToBeginningAndRepeatAreNotIgnored() throws {
    let source = MediaRemoteAdapterSource()
    let manager = NowPlayingManager(source: source)
    try playing(source, elapsed: 160)
    try update(source, ["elapsedTimeMicros": 0, "timestampEpochMicros": 1_040_000_000], at: 1_040)
    #expect(manager.position(at: Date(timeIntervalSince1970: 1_041)) == 1)
    try update(source, ["elapsedTimeMicros": 90_000_000, "timestampEpochMicros": 1_050_000_000], at: 1_050)
    #expect(manager.position(at: Date(timeIntervalSince1970: 1_050)) == 90)
}

@MainActor @Test
func pauseResumeWithoutPositionDoesNotRewindOrCountPauseTime() throws {
    let source = MediaRemoteAdapterSource()
    let manager = NowPlayingManager(source: source)
    try playing(source)
    try update(source, ["playing": false], at: 1_010)
    #expect(manager.position(at: Date(timeIntervalSince1970: 1_070)) == 40)
    try update(source, ["playing": true], at: 1_080)
    #expect(manager.position(at: Date(timeIntervalSince1970: 1_085)) == 45)
}

@MainActor @Test
func sameTitleDifferentArtistCannotInheritPreviousSongPosition() throws {
    let source = MediaRemoteAdapterSource()
    let manager = NowPlayingManager(source: source)
    try playing(source, elapsed: 200)
    try update(source, ["artist": "Different Artist"], at: 1_030)
    #expect(manager.track?.hasPlaybackPosition == false)
    try update(source, ["elapsedTimeMicros": 0, "timestampEpochMicros": 1_031_000_000], at: 1_031)
    #expect(manager.position(at: Date(timeIntervalSince1970: 1_032)) == 1)
}

@MainActor @Test
func lateStartupSnapshotCannotReplaceNewerStreamAndNullClearsTrack() throws {
    let source = MediaRemoteAdapterSource()
    let manager = NowPlayingManager(source: source)
    try playing(source, elapsed: 100)
    source.applySeed(Data(#"{"title":"Old Song","artist":"Old Artist","elapsedTime":0,"playing":true}"#.utf8))
    #expect(manager.track?.title == "Song")
    source.parse(Data("null".utf8))
    #expect(manager.track == nil)
}

@MainActor @Test
func fractionalRateAndTimestampOnlyDiffUseOriginalElapsedSample() throws {
    let source = MediaRemoteAdapterSource()
    let manager = NowPlayingManager(source: source)
    try playing(source)
    try update(source, ["playbackRate": 1.5], at: 1_010)
    #expect(manager.position(at: Date(timeIntervalSince1970: 1_020)) == 55)
    try update(source, ["timestampEpochMicros": 1_025_000_000], at: 1_025)
    #expect(manager.position(at: Date(timeIntervalSince1970: 1_025)) == 30)
}

@MainActor @Test
func newTrackWithoutPositionWaitsAndExplicitNullDoesNotKeepStaleLyrics() throws {
    let source = MediaRemoteAdapterSource()
    let manager = NowPlayingManager(source: source)
    try playing(source)
    try update(source, ["title": "Next Song"], at: 1_025)
    #expect(manager.track?.hasPlaybackPosition == false)
    #expect(manager.track?.duration == 300) // omitted duration is unchanged in the diff protocol
    try update(source, ["title": NSNull()], at: 1_026)
    #expect(manager.track?.artist != "Artist")
}

@MainActor @Test
func artworkOnAppFallbackKeepsOriginalSampleDate() {
    let source = FakePlaybackSource()
    let manager = NowPlayingManager(source: source)
    var track = NowPlayingTrack(title: "Song", artist: "Artist", isPlaying: true,
                                elapsed: 40, duration: 200, elapsedAt: Date(timeIntervalSince1970: 1_000))
    source.onChange?(track)
    track.album = "Artwork metadata"
    source.onChange?(track)
    #expect(manager.position(at: Date(timeIntervalSince1970: 1_020)) == 60)
}

@MainActor
private final class FakePlaybackSource: NowPlayingSource {
    static var isAvailable: Bool { true }
    var onChange: ((NowPlayingTrack?) -> Void)?
    func start() {}
    func stop() {}
    func playPause() {}
    func next() {}
    func previous() {}
}

@MainActor @Test
func legacyTimestampAndDelayedAlbumMetadataKeepThePlaybackAnchor() throws {
    let source = MediaRemoteAdapterSource()
    let manager = NowPlayingManager(source: source)
    try update(source, ["title": "Song", "artist": "Artist", "playing": true,
                        "elapsedTime": 25, "duration": 300,
                        "timestamp": "1970-01-01T00:16:40.250Z"], at: 1_010, diff: false)
    #expect(abs(manager.position(at: Date(timeIntervalSince1970: 1_010)) - 34.75) < 0.001)
    try update(source, ["album": "Album", "contentItemIdentifier": "first-id"], at: 1_012)
    #expect(abs(manager.position(at: Date(timeIntervalSince1970: 1_012)) - 36.75) < 0.001)
}
