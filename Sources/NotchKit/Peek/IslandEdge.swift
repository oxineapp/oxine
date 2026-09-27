import Combine
import DynamicNotchKit
import SwiftUI

/// What the closed island draws along its edge (`DynamicNotch.compactEdge`):
/// the glow in the colors of whoever's waiting on an app while there's
/// anyone, else the metric bar when it's on. Both are lines along the
/// island's own outline, outside it, so they wrap whatever the island holds
/// (music ears, a notice's ears, the notice below) and move with it exactly.
struct IslandEdge: View {
    @ObservedObject var controller: NotchController
    /// nil: the metric bar is off.
    let feed: BarFeed?
    let edge: NotchEdge

    var body: some View {
        ZStack {
            if !controller.attention.isEmpty {
                AttentionGlow(colors: controller.attention, edge: edge)
                    .transition(.opacity)
            } else if let feed {
                MetricBar(feed: feed, edge: edge)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: controller.attention.isEmpty)
    }
}

/// Someone's waiting: the edge glows in their color, crossfading to the next
/// person's every few seconds, and flares once when someone new starts
/// waiting. Steady otherwise: no clock runs while it's up with one person.
private struct AttentionGlow: View {
    let colors: [Color]
    let edge: NotchEdge
    @State private var turn = 0
    @State private var flare = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let color = colors[turn % colors.count]
        edge.line(color, width: 2.5)
            .shadow(color: color.opacity(flare ? 1 : 0.75), radius: flare ? 9 : 4)
            .shadow(color: color.opacity(flare ? 0.7 : 0.35), radius: flare ? 22 : 10)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: turn)
            .task(id: colors) {
                turn = 0
                guard colors.count > 1 else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    turn += 1
                }
            }
            .onChange(of: colors, initial: true) { old, new in
                // Someone new (not someone read): one flare, then settle.
                guard !reduceMotion, new.count >= old.count else { return }
                flare = true
                withAnimation(.easeOut(duration: 1.4)) { flare = false }
            }
    }
}

/// The metric bar: a dim line along the whole edge with the chosen metric
/// filling it left to right (split: each half from its outer end in toward
/// the middle).
private struct MetricBar: View {
    @ObservedObject var feed: BarFeed
    let edge: NotchEdge

    /// Geometry-check mode: bold bright-red full outline, ignoring the metric.
    /// Enable with `defaults write com.oxine.settings notchBarDebug -bool true`.
    private var debug: Bool { NotchKit.settingsDefaults.bool(forKey: "notchBarDebug") }
    private var width: CGFloat { debug ? 4 : 2 }

    var body: some View {
        ZStack {
            edge.line(Color.white.opacity(debug ? 0.4 : 0.14), width: width)
            if debug {
                edge.line(Color.red, width: width)
            } else if BarMetric.splitEnabled {
                fill(BarMetricChoice.selected.color, 0.5 * feed.primary, from: .leading)
                fill(BarMetricChoice.secondary.color, 0.5 * feed.secondary, from: .trailing)
            } else {
                fill(BarMetricChoice.selected.color, feed.primary, from: .leading)
            }
        }
    }

    private func fill(_ tint: Color, _ fraction: Double, from anchor: UnitPoint) -> some View {
        edge.line(LinearGradient(colors: [tint, tint.opacity(0.8)], startPoint: .leading, endPoint: .trailing),
                  width: width)
            // Revealed by a mask scaled from one end, so it needs no pixel width.
            .mask {
                Rectangle()
                    .padding(-width * 2)
                    .scaleEffect(x: max(0, fraction), y: 1, anchor: anchor)
            }
            .animation(.easeInOut(duration: 0.55), value: fraction)
    }
}

/// The metric bar's values, read from the live monitors twice a second (not
/// off `PeekHub`'s firehose), and not at all while the notch is open, since
/// the bar only shows on the closed island.
@MainActor
final class BarFeed: ObservableObject {
    @Published private(set) var primary: Double = 0
    @Published private(set) var secondary: Double = 0
    /// The notch is open: nothing to show, nothing to read.
    var paused = false

    private let hub: PeekHub
    private var timer: Timer?

    init(hub: PeekHub) {
        self.hub = hub
        read()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func read() {
        guard !paused else { return }
        let first = value(BarMetricChoice.selected)
        if abs(first - primary) > 0.001 { primary = first }
        if BarMetric.splitEnabled {
            let second = value(BarMetricChoice.secondary)
            if abs(second - secondary) > 0.001 { secondary = second }
        }
    }

    private func value(_ choice: BarMetricChoice) -> Double {
        switch choice {
        case .builtin(let metric):
            switch metric {
            case .cpu:    return hub.usage.cpu
            case .gpu:    return hub.usage.gpu
            case .fan:    return NotchKit.fanReadout?()?.fraction ?? 0
            case .claude: return hub.claude.readout?.fraction ?? 0
            }
        case .external(let id):
            return NotchKit.externalBarMetric(id: id)?.readout()?.fraction ?? 0
        }
    }
}
