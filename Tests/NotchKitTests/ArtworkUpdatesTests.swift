import AppKit
import SwiftUI
import Testing
@testable import NotchKit

@MainActor
private func artworkUpdate(_ source: MediaRemoteAdapterSource, _ payload: [String: Any], diff: Bool = true) throws {
    source.parse(try JSONSerialization.data(withJSONObject: ["type": "data", "diff": diff, "payload": payload]),
                 receivedAt: Date(timeIntervalSince1970: 1_020))
}

private func coverData() throws -> String {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                              isPlanar: false, colorSpaceName: .deviceRGB,
                                              bytesPerRow: 0, bitsPerPixel: 0))
    for x in 0..<2 {
        for y in 0..<2 { bitmap.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: x, y: y) }
    }
    return try #require(bitmap.representation(using: .png, properties: [:])).base64EncodedString()
}

@MainActor
private func startTrack(_ source: MediaRemoteAdapterSource, artwork: Bool = true) throws {
    var payload: [String: Any] = ["title": "First song", "artist": "Artist", "album": "Album",
                                 "bundleIdentifier": "test.player", "playing": true,
                                 "elapsedTimeMicros": 30_000_000, "timestampEpochMicros": 1_000_000_000,
                                 "durationMicros": 300_000_000]
    if artwork { payload["artworkData"] = try coverData() }
    try artworkUpdate(source, payload, diff: false)
}

@MainActor @Test
func sharedAlbumCoverSurvivesSongChangeWithoutKeepingOldLyricPosition() throws {
    let source = MediaRemoteAdapterSource()
    let manager = NowPlayingManager(source: source)
    try startTrack(source)
    let cover = try #require(manager.track?.artwork)
    // The adapter omits artwork when the next song uses the same image.
    try artworkUpdate(source, ["title": "Second song", "contentItemIdentifier": "second"])
    #expect(manager.track?.artwork === cover)
    #expect(manager.track?.hasPlaybackPosition == false)
    try artworkUpdate(source, ["elapsedTimeMicros": 0, "timestampEpochMicros": 1_020_000_000])
    #expect(manager.track?.artwork === cover)
    #expect(manager.position(at: Date(timeIntervalSince1970: 1_021)) == 1)
}

@MainActor @Test
func metadataCorrectionsDoNotDiscardUnchangedArtwork() throws {
    let source = MediaRemoteAdapterSource()
    let manager = NowPlayingManager(source: source)
    try startTrack(source)
    let cover = try #require(manager.track?.artwork)
    try artworkUpdate(source, ["album": "Album (Deluxe)", "contentItemIdentifier": "first"])
    #expect(manager.track?.artwork === cover)
    try artworkUpdate(source, ["contentItemIdentifier": "revised-first"])
    #expect(manager.track?.artwork === cover)
}

@MainActor @Test
func lateArtworkUpdatesImageAndTintWithoutRewindingLyrics() throws {
    let source = MediaRemoteAdapterSource()
    let manager = NowPlayingManager(source: source)
    try startTrack(source, artwork: false)
    #expect(manager.tint == .clear)
    try artworkUpdate(source, ["artworkData": try coverData()])
    #expect(manager.track?.artwork != nil)
    #expect(manager.tint != .clear)
    #expect(manager.position(at: Date(timeIntervalSince1970: 1_020)) == 50)
}

@MainActor @Test
func removedArtworkAndFullSnapshotsDoNotKeepAnOldCover() throws {
    let source = MediaRemoteAdapterSource()
    let manager = NowPlayingManager(source: source)
    try startTrack(source)
    try artworkUpdate(source, ["artworkData": NSNull()])
    #expect(manager.track?.artwork == nil)
    #expect(manager.tint == .clear)
    try artworkUpdate(source, ["artworkData": try coverData()])
    #expect(manager.track?.artwork != nil)
    try startTrack(source, artwork: false)
    #expect(manager.track?.artwork == nil)
    #expect(manager.tint == .clear)
    try artworkUpdate(source, [:], diff: false)
    #expect(manager.track == nil)
}
