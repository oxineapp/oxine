import AppKit
import Combine
import LyricsCore

/// One click-through lyric surface, attached to the same playback feed as the notch.
@MainActor
final class NotchLyrics {
    private let player: NowPlayingManager
    private let panel: NSPanel
    private let label = NSTextField(wrappingLabelWithString: "")
    private let caption = NSTextField(labelWithString: "")
    private var timer: Timer?
    private var request: Task<Void, Never>?
    private var key: TrackKey?
    private var lines: [LyricLine] = []
    private var cache: [TrackKey: [LyricLine]] = [:]
    private var retryAt: Date?
    private var expanded = false
    private var lastText = ""
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
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        content.layer?.cornerRadius = 14
        for text in [label, caption] {
            text.alignment = .center
            text.textColor = .white
            text.isSelectable = false
            content.addSubview(text)
        }
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byWordWrapping
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .white.withAlphaComponent(0.6)
        panel.contentView = content
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
            panel.orderOut(nil)
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
        guard !expanded, let screen = NotchGeometry.preferredScreen() else { panel.orderOut(nil); return }
        let text = preview ? "Your lyrics, just below the notch" :
            (player.isPlaying ? LRC.line(in: lines, position: player.position(at: Date()),
                                        adjustment: number("notchLyricsOffset", fallback: 0.3, range: -10...10)) : nil)
        guard let text else { panel.orderOut(nil); return }
        let font = number("notchLyricsFont", fallback: 22, range: 12...48)
        let width = min(number("notchLyricsWidth", fallback: 520, range: 240...1000), screen.frame.width - 24)
        let showTrack = defaults.object(forKey: "notchLyricsTrackInfo") as? Bool ?? true
        label.font = .systemFont(ofSize: font, weight: .semibold)
        if text != lastText { label.stringValue = text; lastText = text }
        let measured = label.sizeThatFits(NSSize(width: width - 32, height: 1000)).height
        let labelHeight = min(max(measured, font * 1.3), font * 3.9)
        let height = labelHeight + (showTrack ? 38 : 20)
        let xOffset = number("notchLyricsX", fallback: 0, range: -1500...1500)
        let yOffset = number("notchLyricsY", fallback: 8, range: 0...1500)
        let x = min(max(screen.frame.midX - width / 2 + xOffset, screen.frame.minX + 12), screen.frame.maxX - width - 12)
        let y = max(screen.visibleFrame.minY + 12, NotchGeometry.notchFrame(for: screen).minY - yOffset - height)
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        label.frame = NSRect(x: 16, y: showTrack ? 28 : 10, width: width - 32, height: labelHeight)
        caption.frame = NSRect(x: 16, y: 8, width: width - 32, height: 16)
        caption.isHidden = !showTrack
        caption.stringValue = preview ? "ScreenLyrics · preview" : [key?.artist, key?.title].compactMap { $0 }.joined(separator: " — ")
        if !panel.isVisible { panel.orderFrontRegardless() }
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
        if cache.count >= 100 { cache.removeAll() }
        cache[track] = result
        lines = result
        request = nil
    }
}
