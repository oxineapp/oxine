import AppKit
import Combine
import LyricsCore

/// One click-through lyric surface, attached to the same playback feed as the notch.
@MainActor
final class NotchLyrics {
    private let player: NowPlayingManager
    private let panel: NSPanel
    private let canvas = LyricCanvas(frame: .zero)
    private var timer: Timer?
    private var request: Task<Void, Never>?
    private var key: TrackKey?
    private var lines: [LyricLine] = []
    private var cache: [TrackKey: [LyricLine]] = [:]
    private var retryAt: Date?
    private var expanded = false
    private var lastTimingAdjustment: Double?
    private let defaults = NotchKit.settingsDefaults

    private struct TrackKey: Hashable {
        let title: String
        let artist: String
        let album: String
        let duration: Int
    }
    private struct Response: Decodable { let syncedLyrics: String? }

    init(player: NowPlayingManager) {
        self.player = player
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Oxine Lyrics"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .mainMenu + 2
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.contentView = canvas
    }

    func start() {
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
        tick()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        request?.cancel(); request = nil
        canvas.cancelAnimation()
        panel.orderOut(nil)
    }

    func setExpanded(_ value: Bool) { expanded = value; tick() }

    private func number(_ name: String, fallback: Double, range: ClosedRange<Double>) -> Double {
        let value = (defaults.object(forKey: name) as? NSNumber)?.doubleValue ?? fallback
        return value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }

    private func tick() {
        let enabled = defaults.object(forKey: "notchLyricsEnabled") as? Bool ?? false
        guard enabled else {
            request?.cancel(); request = nil; key = nil; lines = []
            hide()
            return
        }
        let preview = defaults.bool(forKey: "notchLyricsPreview")
        if let track = player.track, !track.title.isEmpty, !track.artist.isEmpty {
            let newKey = TrackKey(title: track.title, artist: track.artist, album: track.album,
                                  duration: track.duration.isFinite ? Int(max(0, track.duration).rounded()) : 0)
            if newKey != key {
                request?.cancel(); request = nil
                key = newKey; lines = []; retryAt = nil
                fetch(newKey)
            } else if request == nil, let retryAt, Date() >= retryAt {
                fetch(newKey)
            }
        } else {
            request?.cancel(); request = nil; key = nil; lines = []
        }
        guard !expanded, let screen = NotchGeometry.preferredScreen() else { hide(); return }
        let guide = defaults.bool(forKey: "notchLyricsShowBounds")
        let samples = ["Your lyrics, just below the notch", "Choose a font. Let the words move.",
                       "A little more room for the lines you want to sing along to."]
        // Adjusting settings while listening must never substitute demo lyrics for the song.
        let showingSample = preview && !player.isPlaying
        let timing = number("notchLyricsOffset", fallback: 0.3, range: -10...10)
        let timingChanged = lastTimingAdjustment.map { $0 != timing } ?? false
        lastTimingAdjustment = timing
        let text = showingSample ? samples[Int(Date().timeIntervalSinceReferenceDate / 3) % samples.count] :
            (player.isPlaying && player.track?.hasPlaybackPosition == true ? LRC.line(in: lines, position: player.position(at: Date()),
                                        adjustment: timing) : nil)
        guard text != nil || guide else { hide(); return }
        let width = number("notchLyricsWidth", fallback: 520, range: 240...1000)
        let height = number("notchLyricsHeight", fallback: 160, range: 100...500)
        let frame = LyricsLayout.frame(screen: screen.frame, visible: screen.visibleFrame,
                                       notchBottom: NotchGeometry.notchFrame(for: screen).minY,
                                       width: width, height: height,
                                       xOffset: number("notchLyricsX", fallback: 0, range: -1500...1500),
                                       yOffset: number("notchLyricsY", fallback: 8, range: 0...1500))
        let frameChanged = panel.frame != frame
        if frameChanged { panel.setFrame(frame, display: true) }
        let style = LyricCanvas.Style(
            fontFamily: defaults.string(forKey: "notchLyricsFontFamily") ?? "system",
            fontSize: number("notchLyricsFont", fallback: 22, range: 12...48),
            backgroundEnabled: defaults.object(forKey: "notchLyricsBackground") as? Bool ?? true,
            backgroundOpacity: number("notchLyricsBackgroundOpacity", fallback: 0.82, range: 0...1),
            showBounds: guide,
            showTrack: defaults.object(forKey: "notchLyricsTrackInfo") as? Bool ?? true,
            animation: defaults.string(forKey: "notchLyricsAnimation") ?? "fade",
            animationDuration: number("notchLyricsAnimationDuration", fallback: 0.25, range: 0.1...2))
        let track = showingSample ? "ScreenLyrics · preview" : [key?.artist, key?.title].compactMap { $0 }.joined(separator: " — ")
        canvas.render(text: text, track: track, style: style, appearing: !panel.isVisible,
                      animateChanges: !timingChanged && (!panel.isVisible || !frameChanged))
        if !panel.isVisible {
            panel.orderFrontRegardless()
            notchLog("lyrics overlay visible (preview: \(showingSample), timed line: \(text != nil))")
        }
    }

    private func hide() {
        if panel.isVisible { canvas.cancelAnimation(); panel.orderOut(nil) }
    }

    private func fetch(_ track: TrackKey) {
        retryAt = nil
        if let cached = cache[track] { lines = cached; return }
        var url = URLComponents(string: "https://lrclib.net/api/get")!
        url.queryItems = [URLQueryItem(name: "artist_name", value: track.artist),
                          URLQueryItem(name: "track_name", value: track.title)]
        if !track.album.isEmpty { url.queryItems?.append(URLQueryItem(name: "album_name", value: track.album)) }
        if track.duration > 0 { url.queryItems?.append(URLQueryItem(name: "duration", value: String(track.duration))) }
        var query = URLRequest(url: url.url!)
        query.timeoutInterval = 15
        query.setValue("OxineBeta/2.1.1 (https://github.com/oxineapp/oxine)", forHTTPHeaderField: "User-Agent")
        request = Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(for: query)
                guard !Task.isCancelled, let self, self.key == track else { return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                notchLog("lyrics lookup HTTP \(status)")
                if status == 404 { self.finish([], for: track); return }
                guard status == 200 else { throw URLError(.badServerResponse) }
                let payload = try JSONDecoder().decode(Response.self, from: data)
                self.finish(payload.syncedLyrics.map(LRC.parse) ?? [], for: track)
            } catch {
                guard !Task.isCancelled, let self, self.key == track else { return }
                self.request = nil
                self.retryAt = Date().addingTimeInterval(30)
            }
        }
    }

    private func finish(_ result: [LyricLine], for track: TrackKey) {
        notchLog("lyrics loaded: \(result.count) timed lines")
        if cache.count >= 100 { cache.removeAll() }
        cache[track] = result
        lines = result
        request = nil
    }
}
