import SwiftUI
import Combine
import PanelKit

/// The live data the collapsed-notch ears draw from: now-playing (album art /
/// bars), the agent monitor (status grid), and CPU usage. Re-publishes its
/// children's changes so an `EarView` observing the hub re-renders whenever any
/// source moves.
@MainActor
public final class PeekHub: ObservableObject {
    let nowPlaying: NowPlayingManager?
    let agents = AgentMonitor()
    let usage = SystemUsageMonitor()
    let claude = ClaudeUsageMonitor()

    /// Live on-screen frames of the collapsed ears, in the notch window's coordinate
    /// space (SwiftUI `.global`), reported by the compact views. The bar flips these
    /// through the kit window to trace the *real* island — no guessed chrome.
    @Published var leftEarFrame: CGRect = .zero
    @Published var rightEarFrame: CGRect = .zero

    private var bag = Set<AnyCancellable>()

    init(nowPlaying: NowPlayingManager?) {
        self.nowPlaying = nowPlaying
        for pub in [agents.objectWillChange, usage.objectWillChange, claude.objectWillChange, nowPlaying?.objectWillChange].compactMap({ $0 }) {
            pub.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        }
    }

    func start() {
        agents.start(); usage.start()
        // Only spawn ccusage when the bar is actually showing the Claude metric
        // (in either half when split).
        if PeekContent.barEnabled && BarMetric.active.contains(.claude) { claude.start() }
    }
    func stop() { agents.stop(); usage.stop(); claude.stop() }
}

/// One collapsed-notch ear, resolving its configured `PeekContent` (or `smart`)
/// against the hub's live state.
struct EarView: View {
    enum Side { case left, right }
    let side: Side
    @ObservedObject var hub: PeekHub

    private var playing: Bool { hub.nowPlaying?.isPlaying ?? false }
    /// A track is loaded (playing *or* paused). Visibility keys off this so the
    /// ears persist through a pause and only clear when playback truly stops.
    private var hasTrack: Bool { hub.nowPlaying?.track != nil }

    var body: some View {
        let content = side == .left ? PeekContent.left : PeekContent.right
        resolve(content)
            // Report this idle ear's real frame for the bar. Measuring *here* (not
            // the compact wrapper) means a HUD / sneak-peek takeover — which
            // replaces EarView entirely — can never poison the reading: EarView
            // simply isn't in the tree then, so the last idle frame holds.
            .background(GeometryReader { g in
                Color.clear.onChange(of: g.frame(in: .global), initial: true) { _, f in
                    if side == .left { hub.leftEarFrame = f } else { hub.rightEarFrame = f }
                }
            })
    }

    @ViewBuilder private func resolve(_ c: PeekContent) -> some View {
        switch c {
        case .smart:      smart
        case .albumArt:   art
        case .bouncyBars: bars
        case .agentGrid:  grid(hub.agents.primary)
        case .cpuUsage:   cpu
        case .off:        empty
        }
    }

    /// A measurable 0×0 stand-in for "no content". Returning `EmptyView` here drops
    /// the frame-reporting `.background` entirely, so the bar would never learn the
    /// ear emptied and would stay stretched at the last non-empty width. A real
    /// zero-size view keeps the measurement firing.
    private var empty: some View { Color.clear.frame(width: 0, height: 0) }

    // Smart blend (the agent grid lives on the RIGHT only — never both ears):
    //   left  = album art whenever a track is loaded (stays through a pause).
    //   right = agent grid whenever an agent is active, else bouncy bars when
    //           a track is loaded (flat while paused), else nothing.
    // Volume/brightness HUD overrides happen a level up, in the compact views.
    @ViewBuilder private var smart: some View {
        if side == .left {
            if hasTrack { art }
            else { empty }
        } else {
            if let a = hub.agents.primary { grid(a) }
            else if hasTrack { bars }
            else { empty }
        }
    }

    // Ear content is sized to its *intrinsic* width (no `maxWidth: .infinity`): the
    // bar measures these frames, and a greedy frame would inflate the slot and
    // strand the outline far past the real content.
    private var art: some View {
        Artwork(image: hub.nowPlaying?.track?.artwork, size: 22, radius: 5,
                appID: hub.nowPlaying?.track?.app)
    }

    private var bars: some View {
        MusicVisualizer(isPlaying: playing, color: .panelAccent)
    }

    @ViewBuilder private func grid(_ state: AgentState?) -> some View {
        if let state {
            HStack(spacing: 5) {
                if side == .right { gridCount }
                AgentGrid(state: state)
                if side == .left { gridCount }
            }
        } else {
            empty
        }
    }

    /// A small "+N" when more than one agent is live.
    @ViewBuilder private var gridCount: some View {
        if hub.agents.agents.count > 1 {
            Text("+\(hub.agents.agents.count - 1)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var cpu: some View {
        HStack(spacing: 3) {
            Image(systemName: "cpu").font(.system(size: 9, weight: .semibold))
            Text("\(Int((hub.usage.cpu * 100).rounded()))%")
                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
        }
        .foregroundStyle(.white.opacity(0.8))
    }
}
