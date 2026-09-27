import PanelKit
import SwiftUI
import TapKit

/// The Decant tab. A master strip for the output itself, then the mixer: what's
/// playing on top in the order it started, the apps you keep underneath. Every
/// fader is also a meter — the bright run inside it is the sound right now, read
/// from the hub once per frame, so it keeps moving while you drag.
struct DecantView: View {
    @ObservedObject var decant: DecantManager
    private var accent: Color { .panelAccent }
    /// The open-apps picker inside Your apps.
    @State private var adding = false
    /// What's being dragged — a row or a picker tile — so rows can make room.
    @State private var dragging: DraggedApp?

    var body: some View {
        ScrollView {
            GlassEffectContainer(spacing: 14) {
                VStack(spacing: 14) {
                    master
                    if decant.permission == .denied || decant.permission == .undetermined { permissionCard }
                    let playing = decant.playingRows, kept = decant.keptRows
                    if playing.isEmpty { quietCard } else { playingGroup(playing) }
                    yourApps(kept)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 20)
                .animation(.spring(response: 0.38, dampingFraction: 0.86), value: decant.playingRows.map(\.id) + ["|"] + decant.keptRows.map(\.id))
                .animation(.easeOut(duration: 0.2), value: adding)
            }
        }
        .onAppear { decant.setViewActive(true) }
        .onDisappear { decant.setViewActive(false) }
    }

    // MARK: Master

    private var output: OutputDevice? { decant.hub.devices.first { $0.uid == decant.hub.defaultOutputUID } }

    private var master: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(decant.hub.devices) { device in
                        Button { decant.hub.setDefaultOutput(device.uid) } label: {
                            Label(device.name, systemImage: device.uid == decant.hub.defaultOutputUID ? "checkmark" : device.symbol)
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: output?.symbol ?? "hifispeaker")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(accent)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(accent.opacity(0.14)))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Output").font(.system(size: 10.5, weight: .medium)).foregroundColor(.white.opacity(0.5))
                            HStack(spacing: 4) {
                                Text(output?.name ?? "No output").font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.92)).lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.white.opacity(0.35))
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Change where the Mac plays")
                Spacer(minLength: 6)
                Text(decant.hub.systemMuted ? "Muted" : "\(Int((decant.hub.systemVolume * 100).rounded()))%")
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundColor(decant.hub.systemMuted ? .orange : .white.opacity(0.85))
                    .contentTransition(.numericText())
            }
            HStack(spacing: 10) {
                Button { decant.hub.setSystemMuted(!decant.hub.systemMuted) } label: {
                    Image(systemName: speaker(decant.hub.systemVolume, muted: decant.hub.systemMuted))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(decant.hub.systemMuted ? .orange : .white.opacity(0.75))
                        .frame(width: 24)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                GlassFader(fraction: Double(decant.hub.systemVolume), unity: nil,
                           tint: decant.hub.systemMuted ? .orange : accent,
                           level: { decant.hub.systemMuted ? 0 : decant.hub.takeSystemLevel() },
                           onScrub: { decant.hub.setSystemVolume(Float($0)) })
            }
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: Groups

    private func groupTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold)).tracking(0.6)
            .foregroundColor(.white.opacity(0.4))
    }

    private var hairline: some View {
        Rectangle().fill(.white.opacity(0.06)).frame(height: 0.5).padding(.leading, 56)
    }

    private func playingGroup(_ rows: [DecantManager.Row]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            groupTitle("Playing").padding(.horizontal, 16).padding(.top, 13).padding(.bottom, 4)
                .allowsHitTesting(false)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { hairline }
                // The first strip's hover area reaches up under the title, the
                // last one's down to the card's edge: the whole box is the app.
                AppStrip(row: row, decant: decant, accent: accent, dragging: $dragging,
                         reachUp: index == 0 ? 33 : 0, reachDown: index == rows.count - 1 ? 4 : 0)
                    .fadeIn()
            }
        }
        .padding(.bottom, 4)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// A rule with a + in the middle, between what's playing and what you keep.
    /// The picker opens out of it. Also a drop target: letting go of a dragged
    /// app on the rule keeps it.
    private var addRule: some View {
        HStack(spacing: 10) {
            Rectangle().fill(.white.opacity(0.09)).frame(height: 0.5)
            Button { adding.toggle() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.85))
                    .rotationEffect(.degrees(adding ? 45 : 0))
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .help(adding ? "Done" : "Add apps")
            Rectangle().fill(.white.opacity(0.09)).frame(height: 0.5)
        }
        .padding(.horizontal, 6)
        .onDrop(of: [.text], delegate: KeepDrop(target: nil, decant: decant, dragging: $dragging))
    }

    /// The apps you keep, in your order. Drag a row by its icon or name to move
    /// it; drag anything from Playing or from the picker in to keep it.
    @ViewBuilder private func yourApps(_ rows: [DecantManager.Row]) -> some View {
        addRule
        if adding {
            picker
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .fadeIn()
        }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { hairline }
                    AppStrip(row: row, decant: decant, accent: accent, dragging: $dragging,
                             reachUp: index == 0 ? 4 : 0, reachDown: index == rows.count - 1 ? 4 : 0)
                        .opacity(dragging?.id == row.id ? 0.35 : 1)
                        .fadeIn()
                        .onDrop(of: [.text], delegate: KeepDrop(target: row.id, decant: decant, dragging: $dragging))
                }
            }
            .padding(.vertical, 4)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            // Past the last row still counts: keep it at the end.
            .onDrop(of: [.text], delegate: KeepDrop(target: nil, decant: decant, dragging: $dragging))
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 8) {
            groupTitle("Open apps").padding(.horizontal, 16).padding(.top, 13)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 62, maximum: 80), spacing: 6)], spacing: 8) {
                ForEach(decant.openApps, id: \.id) { app in
                    let kept = decant.pinned.contains(app.id)
                    Button {
                        if kept { decant.unpin(app.id) } else { decant.pin(app.id, name: app.name) }
                    } label: {
                        VStack(spacing: 4) {
                            Image(nsImage: app.icon ?? NSImage())
                                .resizable().interpolation(.high).frame(width: 34, height: 34)
                                .overlay(alignment: .bottomTrailing) {
                                    if kept {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 7.5, weight: .heavy)).foregroundColor(.white)
                                            .padding(3).background(Circle().fill(accent))
                                            .offset(x: 3, y: 3)
                                            .transition(.opacity)
                                    }
                                }
                            Text(app.name).font(.system(size: 9.5, weight: .medium))
                                .foregroundColor(.white.opacity(kept ? 0.9 : 0.6)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(kept ? accent.opacity(0.16) : .white.opacity(0.04)))
                        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .animation(.spring(response: 0.3, dampingFraction: 0.75), value: kept)
                    .onDrag {
                        dragging = DraggedApp(id: app.id, name: app.name)
                        return NSItemProvider(object: app.id as NSString)
                    }
                    .help(kept ? "Remove \(app.name)" : "Keep \(app.name) on the mixer")
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 6)
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Decant needs System Audio Recording", systemImage: "waveform.badge.exclamationmark")
                .font(.system(size: 13, weight: .semibold)).foregroundColor(.white.opacity(0.92))
            Text("To change an app's volume, Oxine reads the sound that app plays and plays it back quieter or louder. macOS calls that recording. Nothing is saved, and nothing leaves this Mac.")
                .font(.system(size: 11.5)).foregroundColor(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            Button(decant.permission == .denied ? "Open System Settings" : "Allow") { decant.requestPermission() }
                .buttonStyle(.glassProminent).tint(accent).controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassEffect(.regular.tint(Color.orange.opacity(0.10)), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var quietCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.zzz").font(.system(size: 18, weight: .light)).foregroundColor(.white.opacity(0.4))
            VStack(alignment: .leading, spacing: 1) {
                Text("Nothing is playing").font(.system(size: 13, weight: .semibold)).foregroundColor(.white.opacity(0.8))
                Text("Apps appear here when they make a sound.").font(.system(size: 11)).foregroundColor(.white.opacity(0.45))
            }
            Spacer()
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private func speaker(_ volume: Float, muted: Bool) -> String {
    if muted || volume < 0.005 { return "speaker.slash.fill" }
    if volume < 0.34 { return "speaker.wave.1.fill" }
    if volume < 0.67 { return "speaker.wave.2.fill" }
    return "speaker.wave.3.fill"
}

// MARK: - One app

/// Fade in on arrival. Transitions inside a glass container (and on AppKit-backed
/// controls like `Menu`) are often dropped and the view just pops in; driving
/// opacity from state on appear always animates.
private struct FadeIn: ViewModifier {
    @State private var shown = false
    func body(content: Content) -> some View {
        content.opacity(shown ? 1 : 0)
            .onAppear { withAnimation(.easeOut(duration: 0.28)) { shown = true } }
    }
}
private extension View { func fadeIn() -> some View { modifier(FadeIn()) } }

struct DraggedApp: Equatable {
    let id: String
    let name: String
}

/// Live reordering: as a drag passes over a row, the dragged app takes that
/// row's place (and is kept, if it came from Playing or the picker).
private struct KeepDrop: DropDelegate {
    let target: String?
    let decant: DecantManager
    @Binding var dragging: DraggedApp?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging.id != target else { return }
        // The card-level drop only matters for something not kept yet; a kept
        // row passing over the card's padding shouldn't be thrown to the end.
        if target == nil, decant.pinned.contains(dragging.id) { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            decant.place(dragging.id, name: dragging.name, before: target)
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

private struct AppStrip: View {
    let row: DecantManager.Row
    @ObservedObject var decant: DecantManager
    let accent: Color
    @Binding var dragging: DraggedApp?
    /// Extra hover area above and below, over the card's own padding and title.
    var reachUp: CGFloat = 0
    var reachDown: CGFloat = 0
    @State private var hovering = false

    private var policy: TapHub.Policy { decant.policy(for: row.id) }
    private var routed: OutputDevice? { decant.hub.devices.first { $0.uid == policy.outputUID } }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // The icon is the mute button: the biggest target on the strip for
            // the thing you do in a hurry.
            Button { decant.toggleMute(row) } label: {
                Image(nsImage: AppIcons.icon(id: row.id, url: row.bundleURL))
                    .resizable().interpolation(.high)
                    .frame(width: 30, height: 30)
                    .saturation(policy.muted ? 0 : 1)
                    .opacity(policy.muted ? 0.45 : (row.isPlaying ? 1 : 0.6))
                    .overlay(alignment: .bottomTrailing) {
                        if policy.muted {
                            Image(systemName: "speaker.slash.fill")
                                .font(.system(size: 8, weight: .bold)).foregroundColor(.white)
                                .padding(3).background(Circle().fill(.orange))
                                .offset(x: 4, y: 3)
                                .transition(.opacity)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help(policy.muted ? "Unmute \(row.name)" : "Mute \(row.name)")
            .onDrag(startDrag)

            VStack(spacing: 5) {
                HStack(spacing: 6) {
                    Text(row.name).font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.white.opacity(row.isPlaying ? 0.92 : 0.6)).lineLimit(1)
                        .onDrag(startDrag)
                    if !row.isRunning {
                        Text("not open").font(.system(size: 10, weight: .medium)).foregroundColor(.white.opacity(0.35))
                    }
                    Spacer(minLength: 4)
                    hoverControls
                    Text(policy.muted ? "Muted" : "\(Int((policy.gain * 100).rounded()))%")
                        .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                        .foregroundColor(policy.muted ? .orange : .white.opacity(0.8))
                        .frame(minWidth: 38, alignment: .trailing)
                        .contentTransition(.numericText())
                }
                GlassFader(fraction: Double(policy.gain / decant.maxGain),
                           unity: decant.boost ? 0.5 : nil,
                           tint: policy.muted ? .orange : accent,
                           level: { policy.muted ? 0 : decant.hub.takeLevel(for: row.id) },
                           onScrub: { decant.setGain(Float($0) * decant.maxGain, for: row) })
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .padding(.top, reachUp).padding(.bottom, reachDown)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .padding(.top, -reachUp).padding(.bottom, -reachDown)
        .contextMenu { options }
        .animation(.easeOut(duration: 0.18), value: policy.muted)
        .animation(.easeOut(duration: 0.2), value: hovering)
    }

    /// Only the icon and the name start a drag; the fader keeps its own.
    private func startDrag() -> NSItemProvider {
        dragging = DraggedApp(id: row.id, name: row.name)
        return NSItemProvider(object: row.id as NSString)
    }

    @ViewBuilder private var options: some View {
        Section("Plays through") {
            Button { decant.setOutput(nil, for: row) } label: {
                Label("System output", systemImage: policy.outputUID == nil ? "checkmark" : "arrow.triangle.branch")
            }
            ForEach(decant.hub.devices) { device in
                Button { decant.setOutput(device.uid, for: row) } label: {
                    Label(device.name, systemImage: policy.outputUID == device.uid ? "checkmark" : device.symbol)
                }
            }
        }
        Section {
            if !policy.isNeutral {
                Button { decant.reset(row.id) } label: { Label("Reset volume and output", systemImage: "arrow.counterclockwise") }
            }
            if row.isPinned {
                Button { decant.unpin(row.id) } label: { Label("Remove from Your apps", systemImage: "minus.circle") }
            } else {
                Button { decant.pin(row.id, name: row.name) } label: { Label("Keep in Your apps", systemImage: "pin") }
            }
        }
    }

    /// Route and revert, shown while the pointer is over the strip. A strip
    /// that's routed somewhere keeps its route chip up, since that's state.
    private var hoverControls: some View {
        HStack(spacing: 4) {
            if !policy.isNeutral {
                Button { decant.reset(row.id) } label: {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 22, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Revert to the app's own volume and the system output")
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
            }
            Group {
                Menu {
                    Button { decant.setOutput(nil, for: row) } label: {
                        Label("System output", systemImage: policy.outputUID == nil ? "checkmark" : "arrow.triangle.branch")
                    }
                    Divider()
                    ForEach(decant.hub.devices) { device in
                        Button { decant.setOutput(device.uid, for: row) } label: {
                            Label(device.name, systemImage: policy.outputUID == device.uid ? "checkmark" : device.symbol)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: routed?.symbol ?? "arrow.triangle.branch").font(.system(size: 10, weight: .bold))
                        if let routed { Text(routed.name).font(.system(size: 10.5, weight: .medium)).lineLimit(1) }
                    }
                    .foregroundColor(routed == nil ? .white.opacity(0.6) : accent)
                    .padding(.horizontal, routed == nil ? 5 : 8).padding(.vertical, 3)
                    .background(Capsule().fill(accent.opacity(routed == nil ? 0 : 0.12)))
                    .frame(maxWidth: 120, alignment: .trailing)
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Where this app plays")
            }
            .opacity(hovering || routed != nil ? 1 : 0)
            .allowsHitTesting(hovering || routed != nil)
        }
    }
}

// MARK: - Fader

/// A Liquid Glass fader that's also a meter. The channel up to the knob is a
/// tinted glass run; inside it, a brighter run shows the sound right now. The
/// knob is interactive glass: it swells and catches light under the pointer,
/// like the system's own sliders. The meter is driven by a `TimelineView`, so
/// it reads 30 times a second and doesn't care that a drag is in progress. It
/// stops while the panel is closed: an ordered-out panel keeps its SwiftUI
/// animations running, one meter per app at the display rate.
private struct GlassFader: View {
    var fraction: Double
    var unity: Double?
    var tint: Color
    var level: () -> Float
    var onScrub: (Double) -> Void

    @State private var meter = MeterState()
    @State private var dragging = false
    @ObservedObject private var visibility = PanelVisibility.shared
    private let channelH: CGFloat = 8
    private let knob = CGSize(width: 26, height: 18)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let cy = geo.size.height / 2
            let f = CGFloat(min(max(fraction, 0), 1))
            // The knob travels inside the channel, so 0% and 100% don't hang
            // half off the ends.
            let travel = max(w - knob.width, 1)
            let knobX = knob.width / 2 + f * travel
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.28)).frame(height: channelH)
                    .overlay(Capsule().stroke(.white.opacity(0.07), lineWidth: 0.5))
                Color.clear.frame(width: max(knobX, channelH), height: channelH)
                    .glassEffect(.regular.tint(tint.opacity(0.32)), in: Capsule())
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !visibility.isOpen)) { timeline in
                    let shown = CGFloat(meter.advance(to: level(), at: timeline.date))
                    Capsule()
                        .fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(shown * knobX, 0), height: channelH - 3)
                        .padding(.leading, 1.5)
                        .opacity(shown > 0.004 ? 1 : 0)
                        .shadow(color: tint.opacity(0.6), radius: 3)
                }
                if let unity {
                    Capsule().fill(.white.opacity(0.4)).frame(width: 1.5, height: channelH + 7)
                        .position(x: knob.width / 2 + CGFloat(unity) * travel, y: cy)
                }
                Color.clear.frame(width: knob.width, height: knob.height)
                    // Frosted like the system's own slider thumb. Glass can't
                    // lens the glass card it sits on, so a clear knob reads as
                    // a hollow ring; the white tint gives it a body.
                    .glassEffect(.regular.tint(.white.opacity(0.72)).interactive(), in: Capsule())
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .scaleEffect(dragging ? 1.18 : 1)
                    .position(x: knobX, y: cy)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: dragging)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    dragging = true
                    var x = Double(min(max((v.location.x - knob.width / 2) / travel, 0), 1))
                    // A little magnetism at 100% so unity is easy to land on.
                    if let unity, abs(x - unity) < 0.025 { x = unity }
                    onScrub(x)
                }
                .onEnded { _ in dragging = false })
        }
        .frame(height: knob.height + 4)
    }
}

/// Ballistics for one meter: instant attack, timed release, so it reads like a
/// meter and not a flicker. A class so the timeline can advance it in place
/// without invalidating the view.
private final class MeterState {
    private var shown: Float = 0
    private var last = Date.distantPast

    func advance(to peak: Float, at now: Date) -> Float {
        let dt = Float(min(max(now.timeIntervalSince(last), 0), 0.1))
        last = now
        // Perceptual scale: a linear peak meter sits near the floor for most music.
        let target = sqrt(min(max(peak, 0), 1))
        shown = target >= shown ? target : max(target, shown - dt * 2.4)
        return shown
    }
}

@MainActor
private enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    static func icon(id: String, url: URL?) -> NSImage {
        if let hit = cache[id] { return hit }
        let image = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        cache[id] = image
        return image
    }
}
