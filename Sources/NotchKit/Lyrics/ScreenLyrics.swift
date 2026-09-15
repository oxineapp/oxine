import AppKit
import Combine
import LyricsCore
import SwiftUI

/// The ScreenLyrics overlay: a click-through panel just below the notch showing
/// the current synced lyric line (from LRCLIB) for whatever the notch is playing.
///
/// Lifecycle has two halves that must both be true for anything to show:
///   • `installed` — the ScreenLyrics app is installed (Settings → Apps) and
///     running; the app backend flips this in its hello/bye.
///   • attached — the notch is up and has handed us its `NowPlayingManager`
///     (the presenter attaches on show and detaches on hide).
/// The `notchLyricsEnabled` toggle (song-page button / settings) then decides
/// whether lines actually appear. The overlay is UI-only: it never controls
/// playback, and it steps aside whenever the notch is expanded.
@MainActor
public final class ScreenLyrics: ObservableObject {
    public static let shared = ScreenLyrics()

    /// True while the ScreenLyrics app is installed and running. Drives the
    /// lyrics button on the notch's song page.
    @Published public private(set) var installed = false

    private let model = LyricsOverlayModel()
    private var panel: NSPanel?
    private var player: NowPlayingManager?
    private var timer: Timer?
    private var request: Task<Void, Never>?
    private var key: TrackKey?
    private var lines: [LyricLine] = []
    private var cache: [TrackKey: [LyricLine]] = [:]
    private var retryAt: Date?
    private var notchExpanded = false
    private var lastTiming: Double?
    private var lastStyle: Int?

    private struct TrackKey: Hashable {
        let title: String
        let artist: String
        let album: String
        let duration: Int
    }

    private init() {}

    // MARK: - App lifecycle

    /// The ScreenLyrics app came up.
    public func install() {
        guard !installed else { return }
        installed = true
        startIfReady()
    }

    /// The app was stopped or uninstalled: tear the overlay down, keep the
    /// notch untouched.
    public func uninstall() {
        guard installed else { return }
        installed = false
        stopTicking()
    }

    // MARK: - Notch lifecycle

    /// The notch is up; follow this player's feed.
    func attach(_ player: NowPlayingManager) {
        self.player = player
        startIfReady()
    }

    func detach() {
        stopTicking()
        player = nil
    }

    /// The notch opened/closed. The overlay hides while it's open (the expanded
    /// panel covers the same spot) and eases back once it's collapsed.
    func setNotchExpanded(_ expanded: Bool) {
        notchExpanded = expanded
        tick()
    }

    // MARK: - Ticking

    private func startIfReady() {
        guard installed, player != nil, timer == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
        tick()
    }

    private func stopTicking() {
        timer?.invalidate(); timer = nil
        request?.cancel(); request = nil
        key = nil; lines = []
        hide()
    }

    private func tick() {
        guard let player, installed else { hide(); return }
        let settings = LyricsSettings.load()
        guard settings.enabled else {
            request?.cancel(); request = nil; key = nil; lines = []
            hide()
            return
        }
        // Track the song: fetch on change, retry on transient failure.
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

        guard let screen = NotchGeometry.preferredScreen() else { hide(); return }

        // Adjusting settings while listening must never swap demo lines in for
        // the song, so the sample only runs while nothing is playing.
        let showingSample = settings.preview && !player.isPlaying
        let timed: String? = player.isPlaying && player.track?.hasPlaybackPosition == true
            ? LRC.line(in: lines, position: player.position(at: Date()), adjustment: settings.timing)
            : nil
        let line = showingSample ? Self.samples[Int(Date().timeIntervalSinceReferenceDate / 3) % Self.samples.count] : timed

        // A timing nudge re-selects the current line; don't replay its entrance.
        let timingChanged = lastTiming.map { $0 != settings.timing } ?? false
        lastTiming = settings.timing
        // Switching style or size re-frames the panel; snap rather than animate across it.
        let styleChanged = lastStyle.map { $0 != settings.size } ?? false
        lastStyle = settings.size

        // Nothing to show: let the pill animate away, then hide the panel.
        guard line != nil else {
            model.update(line: nil, caption: "", settings: settings, hidden: true, animate: true)
            scheduleOrderOut()
            return
        }

        let frame = Self.panelFrame(for: settings, screen: screen)
        let panel = ensurePanel()
        if panel.frame != frame { panel.setFrame(frame, display: true) }

        let caption = showingSample ? "ScreenLyrics · preview"
            : [key?.artist, key?.title].compactMap { $0 }.joined(separator: " — ")
        _ = timed
        model.update(line: line, caption: caption, settings: settings,
                     hidden: notchExpanded, animate: !timingChanged && !styleChanged)
        orderOutWork?.cancel(); orderOutWork = nil
        if !panel.isVisible {
            panel.orderFrontRegardless()
            notchLog("lyrics overlay visible (sample: \(showingSample), timed: \(timed != nil))")
        }
    }

    private static let samples = ["Your lyrics, right under the notch",
                                  "Pick a font. Let the words move.",
                                  "A little room for the lines you sing along to"]

    // MARK: - Panel

    private var orderOutWork: DispatchWorkItem?

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.title = "Oxine Lyrics"
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        // Under the notch panel (`.mainMenu + 3`), over everything else.
        p.level = .mainMenu + 2
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isReleasedWhenClosed = false
        // Liquid Glass only renders its lively state in a key-looking window; an
        // accessory app's click-through panel never is, so patch it like the notch.
        p.forceActiveGlassAppearance()
        // The hosting view sits *inside* a plain container, never as the
        // window's own contentView: as contentView it feeds its ideal size back
        // into the window's constraints, and a size change mid-layout throws
        // (`_postWindowNeedsUpdateConstraints`), which crashed the app the
        // first time a line changed the pill's width.
        let container = NSView(frame: .zero)
        container.autoresizesSubviews = true
        let host = NSHostingView(rootView: LyricsOverlayView(model: model))
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        host.frame = container.bounds
        container.addSubview(host)
        p.contentView = container
        panel = p
        return p
    }

    /// Let the exit transition play before the panel disappears.
    private func scheduleOrderOut() {
        guard let panel, panel.isVisible, orderOutWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.orderOutWork = nil
            self?.panel?.orderOut(nil)
        }
        orderOutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func hide() {
        orderOutWork?.cancel(); orderOutWork = nil
        model.update(line: nil, caption: "", settings: model.settings, hidden: true, animate: false)
        panel?.orderOut(nil)
    }

    /// Where the panel sits: a fixed band centred under the notch, sized for
    /// the size step. The pill positions itself inside it, so the
    /// panel never has to resize per line.
    private static func panelFrame(for s: LyricsSettings, screen: NSScreen) -> CGRect {
        let notchBottom = NotchGeometry.notchFrame(for: screen).minY
        let width = min(s.metrics.maxWidth + 48, screen.frame.width - 24)
        let height = LyricsOverlayView.bandHeight(for: s) + s.gap
        return CGRect(x: screen.frame.midX - width / 2,
                      y: max(screen.frame.minY, notchBottom - height),
                      width: width, height: height)
    }

    // MARK: - LRCLIB

    private struct SearchHit: Decodable {
        let id: Int?
        let duration: Double?
        let syncedLyrics: String?
    }

    private static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "Oxine/\(version) (https://github.com/oxineapp/oxine)"
    }()

    private static func request(_ path: String, _ items: [URLQueryItem]) -> URLRequest {
        var url = URLComponents(string: "https://lrclib.net/api/\(path)")!
        url.queryItems = items
        var query = URLRequest(url: url.url!)
        query.timeoutInterval = 15
        query.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return query
    }

    /// Exact match first (`/get` with album + duration); if that record has no
    /// synced lyrics — LRCLIB often holds several uploads of one song and the
    /// signature match may land on a plain-text one — fall back to `/search`
    /// and take the synced hit whose length is closest to the track.
    private func fetch(_ track: TrackKey) {
        retryAt = nil
        if let cached = cache[track] { lines = cached; return }
        notchLog("lyrics lookup: \(track.artist) — \(track.title) [\(track.album)] \(track.duration)s")
        var exact = [URLQueryItem(name: "artist_name", value: track.artist),
                     URLQueryItem(name: "track_name", value: track.title)]
        if !track.album.isEmpty { exact.append(URLQueryItem(name: "album_name", value: track.album)) }
        if track.duration > 0 { exact.append(URLQueryItem(name: "duration", value: String(track.duration))) }
        let getRequest = Self.request("get", exact)
        let searchRequest = Self.request("search", [URLQueryItem(name: "artist_name", value: track.artist),
                                                    URLQueryItem(name: "track_name", value: track.title)])
        let wanted = Double(track.duration)
        request = Task { [weak self] in
            do {
                var synced: String?
                let (data, response) = try await URLSession.shared.data(for: getRequest)
                guard !Task.isCancelled, let self, self.key == track else { return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                notchLog("lyrics get HTTP \(status)")
                if status == 200 {
                    synced = (try? JSONDecoder().decode(SearchHit.self, from: data))?.syncedLyrics
                } else if status != 404 {
                    throw URLError(.badServerResponse)
                }
                if synced == nil {
                    let (sData, sResponse) = try await URLSession.shared.data(for: searchRequest)
                    guard !Task.isCancelled, self.key == track else { return }
                    let sStatus = (sResponse as? HTTPURLResponse)?.statusCode ?? 0
                    let hits = sStatus == 200 ? ((try? JSONDecoder().decode([SearchHit].self, from: sData)) ?? []) : []
                    let best = hits
                        .filter { $0.syncedLyrics?.isEmpty == false }
                        .min { a, b in
                            abs((a.duration ?? 0) - wanted) < abs((b.duration ?? 0) - wanted)
                        }
                    // A synced upload of a different edit is fine within a few seconds.
                    if let best, wanted <= 0 || abs((best.duration ?? 0) - wanted) <= 5 {
                        synced = best.syncedLyrics
                    }
                    notchLog("lyrics search HTTP \(sStatus): \(hits.count) hits, synced pick \(best?.id.map(String.init) ?? "none")")
                }
                self.finish(synced.map(LRC.parse) ?? [], for: track)
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
