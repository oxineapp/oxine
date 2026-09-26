import AppKit
import Combine
import Foundation
import TapKit

/// Decant: a volume (and an output) for every app. The audio work is all in
/// TapKit's shared hub; this is the app's own state — which apps you keep on
/// the mixer, and what you set for each, remembered by bundle id so it's still
/// there next time the app plays.
@MainActor
final class DecantManager: ObservableObject {
    static let shared = DecantManager()
    private static let client = "oxine.decant"
    private static let suite = UserDefaults(suiteName: "com.oxine.settings")
    private enum Key {
        static let policies = "decant.policies"
        static let names = "decant.names"
        static let pinned = "decant.pinned"
        static let boost = "decant.boost"
        static let all = [policies, names, pinned, boost]
    }

    /// One strip on the mixer. Not every row is running: an app you keep on the
    /// mixer is there whether or not it's open.
    struct Row: Identifiable, Equatable {
        let id: String
        let name: String
        let bundleURL: URL?
        let isPlaying: Bool
        let isRunning: Bool
        let processCount: Int
        let isPinned: Bool
    }

    let hub = TapHub.shared
    @Published private(set) var running = false
    @Published private(set) var policies: [String: TapHub.Policy] = [:]
    /// Apps the person put on the mixer themselves, in the order they added them.
    @Published private(set) var pinned: [String] = []
    @Published private(set) var names: [String: String] = [:]
    @Published private(set) var permission = AudioCapturePermission.Status.unknown
    /// Let faders run past 100% (up to 200%) for quiet apps.
    @Published var boost = false { didSet { if boost != oldValue { boostChanged() } } }

    /// When each app was first heard this session, and last heard: playing apps
    /// keep the order they started in (a strip must not jump while you're
    /// holding its fader), and a paused app stays listed for a while.
    private var firstHeard: [String: Date] = [:]
    private var lastHeard: [String: Date] = [:]
    private let recentWindow: TimeInterval = 600
    private var hubSink: AnyCancellable?
    private var viewActive = false
    var maxGain: Float { boost ? 2 : 1 }

    private init() {
        boost = Self.suite?.bool(forKey: Key.boost) ?? false
        if let data = Self.suite?.data(forKey: Key.policies),
           let saved = try? JSONDecoder().decode([String: TapHub.Policy].self, from: data) { policies = saved }
        names = (Self.suite?.dictionary(forKey: Key.names) as? [String: String]) ?? [:]
        pinned = Self.suite?.stringArray(forKey: Key.pinned) ?? []
    }

    // MARK: Lifecycle

    func start() {
        guard !running else { return }
        running = true
        permission = AudioCapturePermission.status
        hub.join(Self.client)
        hub.setPolicies(policies)
        hubSink = hub.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.hubChanged() }
        hubChanged()
    }

    /// Off means off: every tap goes, and every app is back on its own path at
    /// its own volume, so another mixer can take over.
    func stop() {
        guard running else { return }
        running = false
        setViewActive(false)
        hubSink = nil
        hub.leave(Self.client)
        firstHeard = [:]; lastHeard = [:]
    }

    func resetSettings() {
        stop()
        policies = [:]; names = [:]; pinned = []; boost = false
        Key.all.forEach { Self.suite?.removeObject(forKey: $0) }
    }

    private func hubChanged() {
        let now = Date()
        for app in hub.apps where app.isPlaying {
            if firstHeard[app.id] == nil { firstHeard[app.id] = now }
            lastHeard[app.id] = now
        }
        objectWillChange.send()
    }

    // MARK: What the tab shows

    /// Making sound now, or a moment ago — in the order they started, newest last.
    var playingRows: [Row] {
        let now = Date()
        return hub.apps
            .filter { $0.isPlaying || now.timeIntervalSince(lastHeard[$0.id] ?? .distantPast) < recentWindow }
            .sorted { (firstHeard[$0.id] ?? .distantFuture) < (firstHeard[$1.id] ?? .distantFuture) }
            .map(row(for:))
    }

    /// Everything else you've asked to keep: pinned apps and apps with a saved
    /// setting, whether or not they're open. Silent system daemons never show.
    var keptRows: [Row] {
        let shown = Set(playingRows.map(\.id))
        let live = Dictionary(uniqueKeysWithValues: hub.apps.map { ($0.id, $0) })
        let extra = policies.keys.filter { !pinned.contains($0) }
            .sorted { (names[$0] ?? $0).localizedCaseInsensitiveCompare(names[$1] ?? $1) == .orderedAscending }
        return (pinned + extra).filter { !shown.contains($0) }.map { id in
            if let app = live[id] { return row(for: app) }
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            let open = NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty == false
            return Row(id: id, name: names[id] ?? id, bundleURL: url, isPlaying: false, isRunning: open,
                       processCount: 0, isPinned: pinned.contains(id))
        }
    }

    private func row(for app: AudioApp) -> Row {
        Row(id: app.id, name: app.name, bundleURL: app.bundleURL, isPlaying: app.isPlaying, isRunning: true,
            processCount: app.processes.count, isPinned: pinned.contains(app.id))
    }

    /// Every open app, for the picker: the ones already kept are shown selected.
    var openApps: [(id: String, name: String, icon: NSImage?)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, id != "com.oxine.app" else { return nil }
                return (id, app.localizedName ?? id, app.icon)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func policy(for id: String) -> TapHub.Policy { policies[id] ?? TapHub.Policy() }

    // MARK: Changes

    func setGain(_ gain: Float, for row: Row) {
        var p = policy(for: row.id)
        p.gain = min(max(gain, 0), maxGain)
        // Dragging up from silence is "I want to hear this again".
        if p.gain > 0.001 { p.muted = false }
        apply(p, to: row.id, name: row.name)
    }

    func toggleMute(_ row: Row) {
        var p = policy(for: row.id)
        p.muted.toggle()
        apply(p, to: row.id, name: row.name)
    }

    func setOutput(_ uid: String?, for row: Row) {
        var p = policy(for: row.id)
        p.outputUID = uid
        apply(p, to: row.id, name: row.name)
    }

    func reset(_ id: String) { apply(TapHub.Policy(), to: id, name: names[id]) }

    func pin(_ id: String, name: String) {
        guard !pinned.contains(id) else { return }
        pinned.append(id); names[id] = name
        save()
    }

    /// Put an app at a spot in Your apps: before `target`, or at the end. Pins
    /// it if it wasn't; this is what a drag does, live, as it passes over rows.
    func place(_ id: String, name: String, before target: String?) {
        guard id != target else { return }
        pinned.removeAll { $0 == id }
        if let target, let index = pinned.firstIndex(of: target) { pinned.insert(id, at: index) }
        else { pinned.append(id) }
        names[id] = name
        save()
    }

    func unpin(_ id: String) {
        pinned.removeAll { $0 == id }
        if policies[id] == nil { names[id] = nil }
        save()
    }

    func resetAll() {
        policies = [:]; pinned = []; names = [:]
        save()
        if running { hub.setPolicies([:]) }
    }

    private func apply(_ p: TapHub.Policy, to id: String, name: String?) {
        if p.isNeutral {
            policies[id] = nil
            if !pinned.contains(id) { names[id] = nil }
        } else {
            policies[id] = p
            if let name { names[id] = name }
        }
        save()
        if running { hub.setPolicy(p, for: id) }
    }

    private func boostChanged() {
        Self.suite?.set(boost, forKey: Key.boost)
        guard !boost else { return }
        for (id, p) in policies where p.gain > 1 {
            var capped = p; capped.gain = 1
            apply(capped, to: id, name: names[id])
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(policies) { Self.suite?.set(data, forKey: Key.policies) }
        Self.suite?.set(names, forKey: Key.names)
        Self.suite?.set(pinned, forKey: Key.pinned)
    }

    // MARK: Permission

    func refreshPermission() { permission = AudioCapturePermission.status }

    func requestPermission() {
        if permission == .denied { AudioCapturePermission.openSystemSettings(); return }
        AudioCapturePermission.request { _ in
            Task { @MainActor in DecantManager.shared.refreshPermission() }
        }
    }

    // MARK: Meters

    /// The tab coming on screen turns the meters on (and the listen-only taps
    /// they need for apps you haven't touched); leaving turns both off. The
    /// meters themselves are read by the views, once per frame, straight from
    /// the hub — nothing is published per tick.
    func setViewActive(_ active: Bool) {
        guard active != viewActive, running || !active else { return }
        viewActive = active
        hub.setMetering(active, for: Self.client)
        if active {
            refreshPermission()
            _ = try? hub.openSystemListener(for: Self.client)
        } else {
            hub.closeSystemListener(for: Self.client)
        }
    }
}
