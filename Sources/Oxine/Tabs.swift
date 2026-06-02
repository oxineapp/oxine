import SwiftUI

/// Identity for a content tab. The tab bar is user-customizable (add / remove /
/// reorder), so tabs are addressed by identity, never by position — a removed
/// tab must not shift the meaning of the others. Settings is deliberately *not*
/// a `TabID`: it's a separate route opened from the footer gear (see `Route`).
enum TabID: String, CaseIterable, Codable, Identifiable {
    case notes, history, auth, plugins, sous

    var id: String { rawValue }

    /// Canonical order + the default bar layout (used on first launch and as the
    /// stable order for the "available" tray when editing).
    static var canonical: [TabID] { allCases }

    var icon: String {
        switch self {
        case .notes:   return "square.and.pencil"
        case .history: return "clock.arrow.circlepath"
        case .auth:    return "lock.shield"
        case .plugins: return "puzzlepiece.extension"
        case .sous:    return "bolt.heart.fill"
        }
    }

    var title: String {
        switch self {
        case .notes:   return "Notes"
        case .history: return "History"
        case .auth:    return "Auth"
        case .plugins: return "Plugins"
        case .sous:    return "Sous"
        }
    }
}

/// The current route the panel is showing: one of the bar tabs, or Settings.
enum Route: Equatable {
    case tab(TabID)
    case settings
}

/// The user's chosen tab bar: which tabs are on it and in what order. Persisted
/// to the shared settings suite so it survives relaunch, and published so the
/// bar, the Settings editor, and the tour composer all stay in sync. Sous/Fan
/// are ordinary tabs here — no special-casing; a tab being present says nothing
/// about whether its helper is installed (the tab's own view handles that).
@MainActor
final class TabBarConfig: ObservableObject {
    static let shared = TabBarConfig()

    private static let key = "enabledTabs"
    private let store = UserDefaults(suiteName: "com.oxine.settings")

    /// Ordered, deduplicated, always at least one tab.
    @Published private(set) var enabled: [TabID]

    private init() {
        if let raw = UserDefaults(suiteName: "com.oxine.settings")?.string(forKey: Self.key) {
            let parsed = raw.split(separator: ",").compactMap { TabID(rawValue: String($0)) }
            self.enabled = TabBarConfig.normalize(parsed)
        } else {
            self.enabled = TabID.canonical
        }
    }

    /// Tabs not currently on the bar, in canonical order (the "add" tray).
    var available: [TabID] { TabID.canonical.filter { !enabled.contains($0) } }

    func isEnabled(_ tab: TabID) -> Bool { enabled.contains(tab) }

    func add(_ tab: TabID) {
        guard !enabled.contains(tab) else { return }
        enabled.append(tab)
        persist()
    }

    /// Remove a tab from the bar. No-op if it would empty the bar (floor of 1).
    func remove(_ tab: TabID) {
        guard enabled.count > 1, let i = enabled.firstIndex(of: tab) else { return }
        enabled.remove(at: i)
        persist()
    }

    func toggle(_ tab: TabID) { isEnabled(tab) ? remove(tab) : add(tab) }

    /// Replace the whole bar in one shot (used by the drag composer on drop).
    /// Normalized, so it can never persist an empty or duplicated bar.
    func setEnabled(_ tabs: [TabID]) {
        let n = TabBarConfig.normalize(tabs)
        guard n != enabled else { return }
        enabled = n
        persist()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        enabled.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persist()
    }

    func moveUp(_ tab: TabID) {
        guard let i = enabled.firstIndex(of: tab), i > 0 else { return }
        enabled.swapAt(i, i - 1); persist()
    }

    func moveDown(_ tab: TabID) {
        guard let i = enabled.firstIndex(of: tab), i < enabled.count - 1 else { return }
        enabled.swapAt(i, i + 1); persist()
    }

    func reset() { enabled = TabID.canonical; persist() }

    private func persist() {
        store?.set(enabled.map(\.rawValue).joined(separator: ","), forKey: Self.key)
    }

    /// Drop unknowns/dupes and guarantee a non-empty bar.
    private static func normalize(_ tabs: [TabID]) -> [TabID] {
        var seen = Set<TabID>(), out: [TabID] = []
        for t in tabs where !seen.contains(t) { seen.insert(t); out.append(t) }
        return out.isEmpty ? TabID.canonical : out
    }
}

// MARK: - Editing UI (shared by Settings and the tour composer)

/// A glanceable, non-interactive render of the bar exactly as it will look, so
/// edits below it read as "this is your bar."
struct TabBarPreview: View {
    let tabs: [TabID]
    var active: TabID?
    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs) { t in
                let isActive = (active ?? tabs.first) == t
                HStack(spacing: 4) {
                    Image(systemName: t.icon).font(.system(size: 11))
                    Text(t.title).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
                }
                .foregroundColor(.white.opacity(isActive ? 0.9 : 0.32))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background { if isActive { Capsule().fill(Color.oxineAccent.opacity(0.14)) } }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.06), lineWidth: 0.5))
        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: tabs)
    }
}

/// Records each chip's frame (and the two zone frames) in the composer's
/// coordinate space, so a drag can hit-test against live positions.
private struct ChipFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Drag-to-arrange tab composer. The bar row sits on top; tabs you drag down
/// stack into the tray below (and drag back up to re-add). The lifted chip
/// follows your finger while the rest reflow live. Used in Settings (behind the
/// Edit toggle) and as the tour's final step.
struct TabEditor: View {
    @ObservedObject var config = TabBarConfig.shared

    // Working order, committed to `config` on drop.
    @State private var bar: [TabID] = []
    @State private var tray: [TabID] = []

    @State private var dragging: TabID?
    @State private var dragPoint: CGPoint = .zero
    @State private var dragSize: CGSize = .zero      // captured once at lift, stable
    @State private var ignoreDrag = false            // this press began off any chip
    @State private var frames: [String: CGRect] = [:]

    private let space = "tabcomposer"
    private var barZone: CGRect { frames["zone.bar"] ?? .zero }
    private var trayZone: CGRect { frames["zone.tray"] ?? .zero }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            zone(.bar, tabs: bar)
            VStack(alignment: .leading, spacing: 6) {
                Text(tray.isEmpty ? "Drag a tab down here to remove it" : "Off the bar — drag back up to add")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.leading, 2)
                    .animation(nil, value: tray)
                zone(.tray, tabs: tray)
            }
        }
        .coordinateSpace(name: space)
        .onPreferenceChange(ChipFrames.self) { frames = $0 }
        .contentShape(Rectangle())                 // whole area is grabbable
        .gesture(containerDrag)
        .overlay { if let d = dragging { floatingChip(d) } }
        .onAppear(perform: sync)
        .onChange(of: config.enabled) { _, _ in if dragging == nil { sync() } }
        // No body-level .animation: it would also animate the floating chip's
        // .position, making it lag the finger. Reorder animates itself (see reflow).
    }

    private enum Zone { case bar, tray }

    /// One row (bar or tray). Records its own frame so an empty zone is still a
    /// valid drop target, and lays its chips out evenly.
    private func zone(_ zone: Zone, tabs: [TabID]) -> some View {
        HStack(spacing: zone == .bar ? 6 : 8) {
            // Bar chips stretch to share the width (like the real tab bar); tray
            // chips stay natural and pack to the left.
            ForEach(tabs) { chip($0, fill: zone == .bar) }
            if zone == .tray { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, minHeight: 46)
        .padding(.horizontal, 8)
        .background(
            GeometryReader { g in
                let key = zone == .bar ? "zone.bar" : "zone.tray"
                let r = RoundedRectangle(cornerRadius: 12, style: .continuous)
                ZStack {
                    r.fill(.white.opacity(zone == .bar ? 0.05 : 0.02))
                    if zone == .bar { r.stroke(.white.opacity(0.08), lineWidth: 0.5) }
                    else { r.stroke(.white.opacity(0.08), style: StrokeStyle(lineWidth: 0.5, dash: [4, 3])) }
                }
                .preference(key: ChipFrames.self, value: [key: g.frame(in: .named(space))])
            }
        )
    }

    private func chip(_ tab: TabID, fill: Bool) -> some View {
        // No per-chip gesture: the single container gesture (see body) hit-tests
        // these recorded frames. Attaching it here would let `reflow()` reorder
        // the chip out from under its own recognizer mid-drag — SwiftUI then
        // cancels the gesture WITHOUT calling onEnded, freezing `dragging`.
        ComposerChip(tab: tab, fill: fill)
            .opacity(dragging == tab ? 0.0 : 1.0)        // hidden placeholder keeps the slot
            .overlay {
                GeometryReader { g in
                    Color.clear.preference(key: ChipFrames.self, value: [tab.rawValue: g.frame(in: .named(space))])
                }
            }
    }

    /// The lifted chip drawn at the finger. Size is snapshotted at lift so it
    /// never re-reads reflowing frames mid-drag.
    private func floatingChip(_ tab: TabID) -> some View {
        ComposerChip(tab: tab, fill: true, lifted: true)
            .frame(width: max(dragSize.width, 56), height: max(dragSize.height, 32))
            .position(dragPoint)
            .allowsHitTesting(false)
            .transaction { $0.animation = nil }          // follow the finger 1:1, no lag
    }

    // MARK: drag

    /// ONE gesture on the stable container — never on a chip, so reordering the
    /// chips can't tear down the live recognizer. A brief long-press gates it so
    /// it doesn't fight a host ScrollView; the grabbed chip is found by
    /// hit-testing the press point against the recorded frames.
    private var containerDrag: some Gesture {
        LongPressGesture(minimumDuration: 0.16)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(space)))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                if dragging == nil {
                    guard !ignoreDrag else { return }
                    if let tab = chip(at: drag.startLocation) {
                        beginDrag(tab)
                    } else {
                        ignoreDrag = true       // pressed empty space; do nothing this gesture
                        return
                    }
                }
                dragPoint = drag.location
                reflow()
            }
            .onEnded { _ in endDrag() }
    }

    /// Which chip (if any) sits under a point — bar or tray.
    private func chip(at p: CGPoint) -> TabID? {
        for (key, rect) in frames where rect.contains(p) {
            if let t = TabID(rawValue: key) { return t }
        }
        return nil
    }

    private func beginDrag(_ tab: TabID) {
        let f = frames[tab.rawValue] ?? .zero
        dragSize = f.size
        dragPoint = CGPoint(x: f.midX, y: f.midY)
        withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) { dragging = tab }
    }

    /// Re-place the dragged tab into whichever zone/slot the finger is over. The
    /// target index is pure arithmetic against the *stable* zone rect (width /
    /// slot count), never a comparison against the reflowing neighbours — that
    /// feedback loop was the source of the jitter. Bar can't be emptied (floor 1).
    private func reflow() {
        guard let d = dragging else { return }
        var b = bar.filter { $0 != d }
        var t = tray.filter { $0 != d }

        let splitY = trayZone == .zero ? barZone.maxY : (barZone.maxY + trayZone.minY) / 2
        let wantsTray = dragPoint.y > splitY && !b.isEmpty   // keep ≥1 on the bar

        if wantsTray { t.insert(d, at: slotIndex(in: trayZone, count: t.count)) }
        else { b.insert(d, at: slotIndex(in: barZone, count: b.count)) }

        guard b != bar || t != tray else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { bar = b; tray = t }
    }

    /// Insertion slot for the finger's x within a zone: `count + 1` evenly-sized
    /// slots across the zone's inner width. A clean step function of x, so it
    /// can't oscillate between two neighbouring positions.
    private func slotIndex(in zone: CGRect, count: Int) -> Int {
        let inner = zone.insetBy(dx: 8, dy: 0)
        guard inner.width > 0 else { return count }
        let slotW = inner.width / CGFloat(count + 1)
        let idx = Int(((dragPoint.x - inner.minX) / slotW).rounded(.down))
        return min(max(idx, 0), count)
    }

    /// Always resets both flags, so the composer can never get stuck even if the
    /// gesture ends in an unexpected state.
    private func endDrag() {
        let wasDragging = dragging != nil
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { dragging = nil }
        ignoreDrag = false
        if wasDragging { config.setEnabled(bar) }   // tray is local; only the bar persists
    }

    /// Seed the working rows from the saved config (canonical order for the tray).
    private func sync() {
        bar = config.enabled
        tray = TabID.canonical.filter { !config.enabled.contains($0) }
    }
}

/// A single composer chip — the same icon+label pill in the bar, the tray, and
/// lifted under the finger. `fill` stretches it to share the row width (bar);
/// natural width otherwise (tray).
private struct ComposerChip: View {
    let tab: TabID
    var fill: Bool = false
    var lifted: Bool = false
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: tab.icon).font(.system(size: 12))
            Text(tab.title).font(.system(size: 12, weight: .medium))
                .lineLimit(1).minimumScaleFactor(0.8).fixedSize(horizontal: !fill, vertical: false)
        }
        .foregroundColor(.white.opacity(lifted ? 0.95 : 0.8))
        .padding(.horizontal, 8)
        .frame(maxWidth: fill ? .infinity : nil)
        .frame(height: 32)
        .background(Capsule().fill(Color.oxineAccent.opacity(lifted ? 0.28 : 0.14)))
        .overlay(Capsule().stroke(.white.opacity(lifted ? 0.28 : 0.10), lineWidth: 0.5))
        .scaleEffect(lifted ? 1.06 : 1.0)
        .shadow(color: .black.opacity(lifted ? 0.4 : 0), radius: lifted ? 10 : 0, y: lifted ? 5 : 0)
        .contentShape(Capsule())
    }
}
