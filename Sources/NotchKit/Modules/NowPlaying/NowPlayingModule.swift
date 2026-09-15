import SwiftUI
import PanelKit

/// The player surface used inside the Home tab: artwork, metadata, transport, on
/// a fluid backdrop derived from the album art (a blurred, darkened fill of the
/// artwork itself, so the card's colour follows the music).
struct NowPlayingPlayer: View {
    @ObservedObject var manager: NowPlayingManager
    @ObservedObject private var lyrics = ScreenLyrics.shared

    var body: some View {
        if let track = manager.track {
            HStack(spacing: 11) {
                // Artwork is a square that fills the card's height — and *only*
                // that. A wide video thumbnail used to push the card past its
                // slot and under the neighbouring widget (see `Artwork`).
                // Artwork and the title block both open the player app.
                openAppButton {
                    Artwork(image: track.artwork, size: nil, radius: 11, appID: track.app)
                }

                VStack(alignment: .leading, spacing: 2) {
                    openAppButton {
                        VStack(alignment: .leading, spacing: 2) {
                            MarqueeText(
                                text: track.title.isEmpty ? "Not Playing" : track.title,
                                font: .system(size: 14, weight: .semibold),
                                color: .white,
                                height: 18
                            )
                            MarqueeText(
                                text: track.artist,
                                font: .system(size: 11.5, weight: .medium),
                                color: .white.opacity(0.7),
                                height: 14
                            )
                        }
                        .contentShape(Rectangle())
                    }
                    Spacer(minLength: 2)
                    Scrubber(manager: manager)
                    transport
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(.easeInOut(duration: 0.4), value: track.title)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "music.note")
                    .font(.system(size: 20))
                    .foregroundColor(.white.opacity(0.35))
                Text(manager.selectedPlayer == .automatic ? "Nothing playing" : "Nothing playing in \(manager.selectedPlayer.name)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if lyrics.installed { LyricsToggleButton() }
                PlaybackPlayerButton(manager: manager)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A plain, cursor-hinted button that brings the playing app forward.
    private func openAppButton<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Button(action: { manager.openPlayerApp() }) { content() }
            .buttonStyle(.plain)
            .help("Open \(manager.track?.app.flatMap(nowPlayingAppName) ?? manager.selectedPlayer.name)")
            .onHover { inside in inside ? NSCursor.pointingHand.push() : NSCursor.pop() }
    }

    /// Transport centred in the row; the lyrics + source switches sit trailing so
    /// the play button stays put whether or not ScreenLyrics is installed.
    private var transport: some View {
        HStack(spacing: 4) {
            HStack(spacing: 14) {
                transportButton("backward.fill", size: 13) { manager.previous() }
                transportButton(manager.isPlaying ? "pause.fill" : "play.fill", size: 16) { manager.playPause() }
                transportButton("forward.fill", size: 13) { manager.next() }
            }
            .frame(maxWidth: .infinity)
            if lyrics.installed { LyricsToggleButton() }
            PlaybackPlayerButton(manager: manager)
        }
        .frame(maxWidth: .infinity)
    }

    private func transportButton(_ icon: String, size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .foregroundColor(.white.opacity(0.95))
                .frame(width: size + 12, height: size + 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The playback-source switch: two small icons in a pill — the source in use
/// (bright) and the one a click would move to (dim). Clicking slides them; the
/// right-click menu lists every available source. It only exists while there
/// is something to switch to (a second player actually running), so a quit
/// player can never strand the notch on "Nothing playing in …".
struct PlaybackPlayerButton: View {
    @ObservedObject var manager: NowPlayingManager

    var body: some View {
        if manager.availablePlayers.count > 1 {
            Button(action: { withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { manager.cyclePlayer() } }) {
                HStack(spacing: 3) {
                    SourceGlyph(player: manager.selectedPlayer, active: true)
                        .id("cur-\(manager.selectedPlayer.rawValue)")
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                removal: .move(edge: .leading).combined(with: .opacity)))
                    SourceGlyph(player: manager.nextPlayer, active: false)
                        .id("next-\(manager.nextPlayer.rawValue)")
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                removal: .move(edge: .leading).combined(with: .opacity)))
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .background(Capsule().fill(.white.opacity(0.09)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
                .clipShape(Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Playing from \(manager.selectedPlayer.name) · click for \(manager.nextPlayer.name)")
            .accessibilityLabel("Playback source")
            .accessibilityValue(manager.selectedPlayer.name)
            .contextMenu {
                ForEach(manager.availablePlayers) { player in
                    Button(action: { withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { manager.selectPlayer(player) } }) {
                        if player == manager.selectedPlayer {
                            Label(player.name, systemImage: "checkmark")
                        } else {
                            Text(player.name)
                        }
                    }
                }
                Divider()
                Text("Automatic follows whatever is playing, browsers included.")
            }
        }
    }
}

/// One source icon for the switch: the player's app icon, or a waveform for
/// Automatic. Active = full size and bright; the alternative sits small and dim.
private struct SourceGlyph: View {
    let player: PlaybackPlayer
    let active: Bool

    var body: some View {
        Group {
            if let icon = nowPlayingAppIcon(player.bundleIdentifier) {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: active ? 11 : 9, weight: .semibold))
                    .foregroundStyle(active ? Color.panelAccent : .white)
            }
        }
        .frame(width: active ? 16 : 12, height: active ? 16 : 12)
        .opacity(active ? 1 : 0.4)
        .saturation(active ? 1 : 0.3)
    }
}

/// The same saved switch as the ScreenLyrics app's settings; does not rebuild
/// the player or seek. Only shown while the ScreenLyrics app is installed.
struct LyricsToggleButton: View {
    @AppStorage(LyricsSettings.Key.enabled, store: NotchKit.settingsDefaults) private var isEnabled = false

    var body: some View {
        NotchIconButton(
            symbol: isEnabled ? "quote.bubble.fill" : "quote.bubble", selected: isEnabled,
            label: "Lyrics", value: isEnabled ? "On" : "Off",
            help: isEnabled ? "Hide lyrics" : "Show lyrics below the notch when it closes",
            action: { isEnabled.toggle() }
        )
        .frame(width: 26, height: 24)
    }
}

/// Progress scrubber with drag-to-seek. Interpolates position between the
/// source's coarse updates so it advances smoothly, and only appears when the
/// source can actually report a duration.
struct Scrubber: View {
    @ObservedObject var manager: NowPlayingManager
    @State private var dragFrac: Double?

    var body: some View {
        let duration = manager.track?.duration ?? 0
        if duration > 1 {
            TimelineView(.animation(minimumInterval: 0.5, paused: !(manager.track?.isPlaying ?? false))) { tl in
                let pos = dragFrac.map { $0 * duration } ?? manager.position(at: tl.date)
                let frac = min(max(pos / duration, 0), 1)
                VStack(spacing: 3) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.18))
                            Capsule().fill(Color.panelAccent).frame(width: geo.size.width * frac)
                        }
                        .frame(height: 4)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { dragFrac = min(max($0.location.x / geo.size.width, 0), 1) }
                                .onEnded { _ in
                                    if let f = dragFrac { manager.seek(to: f * duration) }
                                    dragFrac = nil
                                }
                        )
                    }
                    .frame(height: 12)
                    HStack {
                        Text(Self.time(pos))
                        Spacer()
                        Text(Self.time(duration))
                    }
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                }
            }
        }
    }

    static func time(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s)
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - Idle peeks

struct NowPlayingPeekLeft: View {
    @ObservedObject var manager: NowPlayingManager
    var body: some View {
        Artwork(image: manager.track?.artwork, size: 22, radius: 5, appID: manager.track?.app)
            .padding(.leading, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NowPlayingPeekRight: View {
    @ObservedObject var manager: NowPlayingManager
    var body: some View {
        MusicVisualizer(isPlaying: manager.isPlaying, color: .panelAccent)
            .padding(.trailing, 6)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

// MARK: - Shared artwork view

/// Album art in a rounded square. With a fixed `size` it's that square; with
/// `nil` it's a square as tall as the space offered — never wider. The image
/// is *overlaid* on a clear square rather than laid out directly: a resizable
/// `.fill` image reports the picture's own aspect as its ideal size, so a 16:9
/// video thumbnail used to stretch the whole player card sideways.
struct Artwork: View {
    var image: NSImage?
    /// Fixed side length, or `nil` to fill the height the parent gives it.
    var size: CGFloat?
    var radius: CGFloat
    /// The player's bundle id / name, so we can stand in its app icon when there's
    /// no album art (e.g. QuickTime, web video).
    var appID: String? = nil

    var body: some View {
        Color.clear
            .frame(width: size, height: size)
            .aspectRatio(1, contentMode: .fit)
            .overlay { picture }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    @ViewBuilder private var picture: some View {
        if let image {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else if let icon = nowPlayingAppIcon(appID) {
            Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
        } else {
            ZStack {
                Color.white.opacity(0.08)
                Image(systemName: "music.note")
                    .font(.system(size: (size ?? 70) * 0.4))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
    }
}

// MARK: - App identity fallbacks (icon / name when a player reports no metadata)

// These resolve through NSWorkspace (app-URL lookup, icon load, running-app scan),
// which is far too costly to run on every Artwork render — so each app's result is
// looked up once and cached. Keyed by bundle id / app name; results don't change.
@MainActor private var appNameCache: [String: String] = [:]
@MainActor private var appIconCache: [String: NSImage?] = [:]

/// The display name for a now-playing app, given a bundle id or a plain app name.
/// Used as the title when a player (QuickTime, web video) reports no track title.
@MainActor func nowPlayingAppName(_ app: String?) -> String {
    guard let app, !app.isEmpty else { return "Now Playing" }
    if let cached = appNameCache[app] { return cached }
    let ws = NSWorkspace.shared
    var name = app
    if app.contains("."), let url = ws.urlForApplication(withBundleIdentifier: app) {
        name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }
    appNameCache[app] = name
    return name
}

/// A display name for a bundle id or app name (the id's app if installed).
@MainActor func nowPlayingAppName(_ app: String) -> String? {
    guard !app.isEmpty else { return nil }
    if app.contains("."), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) {
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
    return app
}

/// The app's icon for a bundle id or app name, to stand in for missing album art.
/// `nil` lets the caller fall back to its generic music-note placeholder.
@MainActor func nowPlayingAppIcon(_ app: String?) -> NSImage? {
    guard let app, !app.isEmpty else { return nil }
    if let cached = appIconCache[app] { return cached }   // includes cached misses
    let ws = NSWorkspace.shared
    var icon: NSImage?
    if app.contains("."), let url = ws.urlForApplication(withBundleIdentifier: app) {
        icon = ws.icon(forFile: url.path)
    } else if let running = ws.runningApplications.first(where: {
        $0.localizedName == app || $0.bundleIdentifier == app
    }) {
        icon = running.icon
    }
    appIconCache[app] = icon
    return icon
}
