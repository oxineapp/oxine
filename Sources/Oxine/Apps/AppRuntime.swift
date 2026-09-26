import Foundation
import SwiftUI

/// The live state of one running app: its rendered surface trees, quick-toggle
/// state, bar-metric readout — everything the SwiftUI surfaces observe. Owns the
/// backend, routes its messages, runs subscription timers, applies the peek
/// rate limit, and answers capability calls through the broker.
@MainActor
final class AppRuntime: ObservableObject {
    let app: OxApp

    /// Rendered tree per surface ("panelTab", "settings", "notchTab").
    @Published private(set) var trees: [String: [AppNode]] = [:]
    /// Quick-toggle state (footer slot).
    @Published private(set) var toggleActive = false
    @Published private(set) var toggleIcon: String?
    @Published private(set) var toggleText: String?
    @Published private(set) var toggleWarning = false
    @Published private(set) var toggleMenu: [AppMenuItem] = []
    /// Bar-metric readout.
    @Published private(set) var metricValue: Double = 0
    @Published private(set) var metricText: String?
    /// Runtime health, surfaced in the store ("crashed 3× — disabled").
    @Published private(set) var runtimeError: String?
    @Published private(set) var running = false

    private var backend: (any AppBackend)?
    private var subTimers: [String: Timer] = [:]
    /// Crash supervision: restart with backoff, give up after 3 in 5 minutes.
    private var crashTimes: [Date] = []
    private var restartWork: DispatchWorkItem?
    /// Peek token bucket: burst 2, one refill per 30s (APPS_DESIGN.md).
    private var peekTokens = 2.0
    private var peekRefillAt = Date()
    /// Last user interaction with one of this app's surfaces (gates openURL).
    private var lastUserEventAt: Date?

    init(app: OxApp) { self.app = app }

    // MARK: - Lifecycle

    func start() {
        guard backend == nil else { return }
        runtimeError = nil
        let b = app.makeBackend()
        backend = b
        b.onMessage = { [weak self] in self?.handle($0) }
        b.onTermination = { [weak self] code in self?.handleTermination(code) }
        do {
            try b.start()
            NSLog("AppRuntime: started %@", app.id)
            running = true
            b.send(.hello(granted: Array(app.grants), dataDir: AppsManager.dataDir(for: app.id).path))
        } catch {
            backend = nil
            running = false
            runtimeError = "failed to launch: \(error.localizedDescription)"
            NSLog("AppRuntime: launch failed %@: %@", app.id, error.localizedDescription)
        }
    }

    func stop() {
        restartWork?.cancel(); restartWork = nil
        subTimers.values.forEach { $0.invalidate() }
        subTimers = [:]
        backend?.stop()
        backend = nil
        running = false
        trees = [:]
        toggleActive = false; toggleText = nil; toggleMenu = []; toggleWarning = false
    }

    private func handleTermination(_ code: Int32) {
        backend = nil
        running = false
        subTimers.values.forEach { $0.invalidate() }
        subTimers = [:]
        let now = Date()
        crashTimes = crashTimes.filter { now.timeIntervalSince($0) < 300 } + [now]
        if crashTimes.count >= 3 {
            runtimeError = "crashed \(crashTimes.count)× in 5 minutes — stopped (exit \(code))"
            return
        }
        let delay: TimeInterval = [1.0, 5.0, 30.0][min(crashTimes.count - 1, 2)]
        runtimeError = "exited (\(code)) — restarting in \(Int(delay))s"
        let work = DispatchWorkItem { [weak self] in self?.start() }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Host → app

    /// A user interaction on one of this app's surfaces.
    func sendEvent(surface: String, ref: String?, kind: String, value: JSONValue? = nil) {
        lastUserEventAt = Date()
        backend?.send(.event(surface: surface, ref: ref, kind: kind, value: value))
    }

    func sendLifecycle(phase: String, surface: String?) {
        backend?.send(.lifecycle(phase: phase, surface: surface))
    }

    // MARK: - App → host

    private func handle(_ msg: AppMessage) {
        switch msg {
        case .ready:
            break
        case .view(let surface, let body):
            trees[surface] = body
        case .toggle(let active, let icon, let text, let menu, let warning):
            toggleActive = active
            toggleIcon = icon
            toggleText = text
            toggleWarning = warning ?? false
            if let menu { toggleMenu = menu }
        case .metric(let value, let text):
            metricValue = min(max(value, 0), 1)
            metricText = text
        case .peek(let text, _):
            guard app.manifest.surfaces.peek == true, admitPeek() else { return }
            NotchCoordinator.shared.peek(text)
        case .call(let id, let fn, let args):
            let (data, error) = AppCapabilityBroker.shared.call(
                fn: fn, args: args, appID: app.id, grants: app.grants,
                userEventAt: lastUserEventAt)
            backend?.send(.ret(id: id, ok: error == nil, data: data, error: error))
        case .sub(let cap, let hz):
            subscribe(cap: cap, hz: hz)
        case .unsub(let cap):
            subTimers.removeValue(forKey: cap)?.invalidate()
        case .log(let line):
            AppsManager.appendLog(appID: app.id, line: line)
        }
    }

    private func subscribe(cap: String, hz: Double?) {
        guard app.grants.contains(cap),
              let ceiling = AppCapabilityBroker.streamCeilings[cap] else { return }
        subTimers.removeValue(forKey: cap)?.invalidate()
        let rate = min(max(hz ?? ceiling, 0.05), ceiling)
        let timer = Timer(timeInterval: 1.0 / rate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let data = AppCapabilityBroker.shared.snapshot(cap: cap) else { return }
                self.backend?.send(.cap(cap: cap, data: data))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        subTimers[cap] = timer
        // Immediate first tick so the app doesn't start blind.
        if let data = AppCapabilityBroker.shared.snapshot(cap: cap) {
            backend?.send(.cap(cap: cap, data: data))
        }
    }

    /// Token bucket: burst 2, refill 1 per 30s. Excess requests are dropped
    /// (the newest state will simply ride the next token).
    private func admitPeek() -> Bool {
        let now = Date()
        peekTokens = min(2, peekTokens + now.timeIntervalSince(peekRefillAt) / 30)
        peekRefillAt = now
        guard peekTokens >= 1 else { return false }
        peekTokens -= 1
        return true
    }
}
