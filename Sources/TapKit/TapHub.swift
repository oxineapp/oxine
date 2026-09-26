import AppKit
import Combine
import CoreAudio

/// The one owner of audio taps in Oxine. Apps don't create taps; they tell the
/// hub what they want — Decant sets a per-app policy (volume, mute, output),
/// Sommelier asks to listen to the system mix — and the hub works out the
/// smallest set of taps that satisfies everyone. That's what keeps two apps
/// from muting the same process twice, and it's why installing one audio app
/// never requires another: the engine ships with Oxine, not with either app.
///
/// Idle cost is nothing: no clients, no listeners, no taps. An app is only
/// tapped while it's actually playing (plus a short linger so pause/resume
/// doesn't blip at full volume), because a running tap keeps the audio
/// hardware awake.
@MainActor
public final class TapHub: ObservableObject {
    public static let shared = TapHub()

    /// What Decant wants for one app. Neutral policies cost nothing: the app
    /// stays on its own untouched path.
    public struct Policy: Codable, Equatable, Sendable {
        public var gain: Float = 1
        public var muted = false
        /// Output device UID; nil follows the system default.
        public var outputUID: String?
        public init(gain: Float = 1, muted: Bool = false, outputUID: String? = nil) {
            self.gain = gain; self.muted = muted; self.outputUID = outputUID
        }
        public var isNeutral: Bool { !muted && abs(gain - 1) < 0.005 && outputUID == nil }
        var effectiveGain: Float { muted ? 0 : gain }
    }

    /// Apps Core Audio knows about, playing ones included. Empty with no clients.
    @Published public private(set) var apps: [AudioApp] = []
    @Published public private(set) var devices: [OutputDevice] = []
    @Published public private(set) var defaultOutputUID: String?
    /// The system output's own volume, 0…1, kept live while there are clients.
    @Published public private(set) var systemVolume: Float = 0
    @Published public private(set) var systemMuted = false
    /// The last tap that couldn't be built, for the owning app's status line.
    @Published public private(set) var lastError: String?

    private var clients: Set<String> = []
    private var meterClients: Set<String> = []
    private var policies: [String: Policy] = [:]
    private var taps: [String: Held] = [:]
    private var systemListener: (tap: ProcessTap, users: Set<String>)?
    private var observation: AudioSystem.ChangeObservation?
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var lingerTimer: Timer?
    private var volumeWatch: (device: AudioDeviceID, block: AudioObjectPropertyListenerBlock)?

    private struct Held {
        let tap: ProcessTap
        var objectIDs: [AudioObjectID]
        var idleSince: Date?
    }
    /// How long a tap outlives the last sound, so a paused song resumes at the
    /// volume you set rather than blipping at full.
    private let linger: TimeInterval = 20

    private init() {}

    // MARK: Clients

    /// An app that uses the hub calls this when it starts and `leave` when it
    /// stops. The first client turns the hub on; the last turns it all off.
    public func join(_ client: String) {
        let first = clients.isEmpty
        clients.insert(client)
        guard first else { return }
        observation = AudioSystem.observeChanges { Task { @MainActor in TapHub.shared.refresh() } }
        refresh()
    }

    public func leave(_ client: String) {
        clients.remove(client)
        meterClients.remove(client)
        if systemListener?.users.contains(client) == true { closeSystemListener(for: client) }
        guard clients.isEmpty else { reconcile(); return }
        observation?.cancel(); observation = nil
        for (obj, block) in processListeners { removeListener(obj, block) }
        processListeners = [:]
        lingerTimer?.invalidate(); lingerTimer = nil
        watchVolume(of: nil)
        policies = [:]
        taps.values.forEach { $0.tap.stop() }
        taps = [:]
        apps = []; devices = []
    }

    // MARK: Per-app control

    public func policy(for appID: String) -> Policy { policies[appID] ?? Policy() }

    public func setPolicy(_ policy: Policy, for appID: String) {
        if policy.isNeutral { policies[appID] = nil } else { policies[appID] = policy }
        if let held = taps[appID], !held.tap.listenOnly {
            // The cheap path, taken on every slider tick. A fader passing
            // through 100% stays on this tap: handing the app back and taking
            // it again a moment later is two audible seams for nothing. The
            // tap is let go once the app falls silent (see `reconcile`).
            held.tap.gain = policy.effectiveGain
            let uid = route(for: policy)
            if held.tap.outputUID != uid { try? held.tap.reroute(to: uid) }
            return
        }
        reconcile()
    }

    /// Replace every policy at once (an app loading its saved state).
    public func setPolicies(_ all: [String: Policy]) {
        policies = all.filter { !$0.value.isNeutral }
        reconcile()
    }

    /// Meters for apps nobody is controlling need listen-only taps; only pay
    /// for them while something is on screen to show them.
    public func setMetering(_ on: Bool, for client: String) {
        if on { meterClients.insert(client) } else { meterClients.remove(client) }
        reconcile()
    }

    /// Peak level of one app since the last call, 0…1 after that app's gain.
    /// Cheap enough to call every frame: one atomic exchange.
    public func takeLevel(for appID: String) -> Float {
        guard let held = taps[appID] else { return 0 }
        let peak = held.tap.takePeak()
        return held.tap.listenOnly ? peak : min(peak * held.tap.gain, 1)
    }

    // MARK: System output

    public func setSystemVolume(_ volume: Float) {
        guard let device = AudioSystem.defaultOutputDevice() else { return }
        AudioSystem.setVolume(min(max(volume, 0), 1), of: device)
        if volume > 0.001, systemMuted { AudioSystem.setMuted(false, of: device) }
        systemVolume = min(max(volume, 0), 1)
    }

    public func setSystemMuted(_ muted: Bool) {
        guard let device = AudioSystem.defaultOutputDevice() else { return }
        AudioSystem.setMuted(muted, of: device)
    }

    public func setDefaultOutput(_ uid: String) {
        guard let device = devices.first(where: { $0.uid == uid }) else { return }
        AudioSystem.setDefaultOutput(device.id)
    }

    private func watchVolume(of device: AudioDeviceID?) {
        if let watch = volumeWatch, watch.device == device { readVolume(); return }
        if let watch = volumeWatch {
            for selector in AudioSystem.volumeSelectors {
                var addr = CA.address(selector, scope: kAudioObjectPropertyScopeOutput)
                AudioObjectRemovePropertyListenerBlock(watch.device, &addr, .main, watch.block)
            }
            volumeWatch = nil
        }
        guard let device else { return }
        let block: AudioObjectPropertyListenerBlock = { _, _ in Task { @MainActor in TapHub.shared.readVolume() } }
        for selector in AudioSystem.volumeSelectors {
            var addr = CA.address(selector, scope: kAudioObjectPropertyScopeOutput)
            AudioObjectAddPropertyListenerBlock(device, &addr, .main, block)
        }
        volumeWatch = (device, block)
        readVolume()
    }

    private func readVolume() {
        guard let device = volumeWatch?.device else { return }
        let v = AudioSystem.volume(of: device) ?? 0
        let m = AudioSystem.isMuted(device)
        if abs(v - systemVolume) > 0.001 { systemVolume = v }
        if m != systemMuted { systemMuted = m }
    }

    // MARK: Listening

    /// A shared, unmuted tap on everything the Mac plays — what you hear, so an
    /// app Decant turned down is heard turned down. Read it from `samples`.
    public func openSystemListener(for client: String) throws -> ProcessTap {
        if var s = systemListener { s.users.insert(client); systemListener = s; return s.tap }
        let tap = ProcessTap(source: .systemExcluding([]), outputUID: "", listenOnly: true)
        try tap.start()
        tap.samples.isEnabled = true
        systemListener = (tap, [client])
        return tap
    }

    /// Peak of the whole mix since the last call; 0 when nobody has the system
    /// listener open.
    public func takeSystemLevel() -> Float { systemListener?.tap.takePeak() ?? 0 }

    public func closeSystemListener(for client: String) {
        guard var s = systemListener else { return }
        s.users.remove(client)
        if s.users.isEmpty { s.tap.stop(); systemListener = nil } else { systemListener = s }
    }

    // MARK: Reconcile

    private func refresh() {
        guard !clients.isEmpty else { return }
        let processes = AudioSystem.processes()
        apps = AudioApps.group(processes, excluding: ProcessInfo.processInfo.processIdentifier)
        devices = AudioSystem.outputDevices()
        defaultOutputUID = AudioSystem.defaultOutputUID()
        watchVolume(of: AudioSystem.defaultOutputDevice())

        // isRunningOutput isn't covered by the process-list listener: watch
        // each process object for it.
        let live = Set(processes.map(\.objectID))
        for (obj, block) in processListeners where !live.contains(obj) {
            removeListener(obj, block); processListeners[obj] = nil
        }
        for obj in live where processListeners[obj] == nil {
            let block: AudioObjectPropertyListenerBlock = { _, _ in Task { @MainActor in TapHub.shared.refresh() } }
            var addr = CA.address(kAudioProcessPropertyIsRunningOutput)
            if AudioObjectAddPropertyListenerBlock(obj, &addr, .main, block) == noErr { processListeners[obj] = block }
        }
        reconcile()
    }

    private func removeListener(_ obj: AudioObjectID, _ block: @escaping AudioObjectPropertyListenerBlock) {
        var addr = CA.address(kAudioProcessPropertyIsRunningOutput)
        AudioObjectRemovePropertyListenerBlock(obj, &addr, .main, block)
    }

    private func route(for policy: Policy) -> String {
        if let uid = policy.outputUID, devices.contains(where: { $0.uid == uid }) { return uid }
        return defaultOutputUID ?? ""
    }

    /// Make the set of running taps match what's wanted right now.
    private func reconcile() {
        let now = Date()
        let byID = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })

        for (id, held) in taps {
            let policy = policies[id]
            guard let app = byID[id] else { held.tap.stop(); taps[id] = nil; continue }
            if held.tap.listenOnly {
                // A meter tap: only while someone's looking, and only until the
                // app needs controlling (the new tap is built first, below).
                if policy != nil || meterClients.isEmpty || !app.isPlaying { held.tap.stop(); taps[id] = nil; continue }
            } else if policy == nil {
                // Controlled but back at neutral: keep carrying the app while
                // it plays, hand it back in the next silence.
                if !app.isPlaying { held.tap.stop(); taps[id] = nil; continue }
                held.tap.gain = 1
                let uid = defaultOutputUID ?? ""
                if held.tap.outputUID != uid { try? held.tap.reroute(to: uid) }
            } else {
                if app.isPlaying { taps[id]!.idleSince = nil }
                else if held.idleSince == nil { taps[id]!.idleSince = now }
                else if now.timeIntervalSince(held.idleSince!) > linger { held.tap.stop(); taps[id] = nil; continue }
            }
            if app.objectIDs != held.objectIDs { held.tap.update(processes: app.objectIDs); taps[id]!.objectIDs = app.objectIDs }
            if let policy, !held.tap.listenOnly {
                held.tap.gain = policy.effectiveGain
                let uid = route(for: policy)
                if held.tap.outputUID != uid { try? held.tap.reroute(to: uid) }
            }
        }

        for app in apps where app.isPlaying && taps[app.id] == nil {
            let policy = policies[app.id]
            guard policy != nil || !meterClients.isEmpty else { continue }
            let tap = ProcessTap(source: .processes(app.objectIDs),
                                 outputUID: policy.map(route(for:)) ?? "",
                                 gain: policy?.effectiveGain ?? 1,
                                 listenOnly: policy == nil)
            do {
                try tap.start()
                taps[app.id] = Held(tap: tap, objectIDs: app.objectIDs, idleSince: nil)
                lastError = nil
            } catch {
                lastError = "\(app.name): \(error)"
            }
        }

        // Only tick while something is waiting out its linger.
        if taps.values.contains(where: { $0.idleSince != nil }) {
            if lingerTimer == nil {
                lingerTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                    Task { @MainActor in TapHub.shared.reconcile() }
                }
            }
        } else {
            lingerTimer?.invalidate(); lingerTimer = nil
        }
    }
}

// MARK: - Permission

/// macOS gates taps behind "System Audio Recording". There's no public API to
/// ask where we stand — a tap without the grant just delivers silence — so
/// this reads TCC directly, and degrades to "unknown" if that ever goes away.
public enum AudioCapturePermission {
    public enum Status: Sendable { case granted, denied, undetermined, unknown }

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    private static var handle: UnsafeMutableRawPointer? {
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    }
    private static var service: CFString { "kTCCServiceAudioCapture" as CFString }

    public static var status: Status {
        guard let handle, let sym = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(sym, to: PreflightFn.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .undetermined
        }
    }

    /// Shows the system prompt the first time; after a denial it does nothing,
    /// and the person has to flip it in System Settings.
    public static func request(_ done: @escaping @Sendable (Bool) -> Void) {
        guard let handle, let sym = dlsym(handle, "TCCAccessRequest") else { return done(false) }
        unsafeBitCast(sym, to: RequestFn.self)(service, nil) { ok in DispatchQueue.main.async { done(ok) } }
    }

    public static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
