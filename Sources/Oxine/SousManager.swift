import Foundation
import Combine
import SousShared

/// Single source of truth for Sous in the app. Persists the user's `SousConfig`,
/// pushes it to the daemon, and polls battery metrics + daemon status so the UI
/// and the menu-bar icon stay live. Shared so both `MainView` and the
/// `AppDelegate` (live icon) observe the same state.
@MainActor
final class SousManager: ObservableObject {
    static let shared = SousManager()

    /// Coarse menu-bar signal: green = held at the limit, orange = actively
    /// working (charging toward / discharging / heat-paused), none = idle.
    enum MenuTint { case none, holding, working }

    @Published var config: SousConfig { didSet { if config != oldValue { commit() } } }
    @Published private(set) var status = SousStatus()
    @Published private(set) var metrics = BatteryMetrics()
    @Published private(set) var menuTint: MenuTint = .none

    let helper = SousHelperClient()

    private let defaults = UserDefaults(suiteName: "com.oxine.settings") ?? .standard
    private let configKey = "sousConfig"
    private var pollTask: Task<Void, Never>?
    /// Faster polling while the panel is on screen.
    private var activeViewers = 0

    private init() {
        if let data = defaults.data(forKey: configKey),
           let saved = try? JSONDecoder().decode(SousConfig.self, from: data) {
            config = SafetyFloors.clamp(saved)
        } else {
            config = SousConfig()
        }
        // The poll loop pings the daemon, re-asserts config, and refreshes status.
        startPolling()
    }

    // MARK: Display

    /// Sous is actually able to control charging right now.
    var capable: Bool { helper.installState == .installed && status.capable }

    /// The state to show. Prefer the daemon's authoritative state; fall back to
    /// an honest metrics-derived value when the daemon isn't controlling.
    var displayState: SousState {
        if capable && config.enabled { return status.state }
        if !metrics.externalConnected { return .unplugged }
        if metrics.isCharging { return .charging }
        return .off          // plugged, not charging, Sous not controlling
    }

    /// Battery % to show — the daemon's hardware reading when available, else the
    /// macOS-reported value.
    var displayPercent: Int {
        if capable, status.hardwareCharge >= 0 { return status.hardwareCharge }
        return metrics.macOSPercent
    }

    var tempC: Double { capable ? status.tempC : metrics.tempC }

    // MARK: Intents

    func setEnabled(_ on: Bool) { config.enabled = on }
    func setLimit(_ pct: Int) { config.chargeLimit = min(max(pct, SafetyFloors.minChargeLimit), 100) }
    func setSailing(_ pct: Int) { config.sailingRange = min(max(pct, 0), SafetyFloors.maxSailingRange) }
    func setHeatProtect(_ on: Bool) { config.heatProtectEnabled = on }
    func setMaxTemp(_ c: Double) { config.maxTempC = c }
    func setControlLED(_ on: Bool) { config.controlLED = on }

    /// This Mac exposes the MagSafe/adapter LED (daemon confirmed the SMC key).
    var canControlLED: Bool { capable && status.canControlLED }

    /// One-shot charge to 100 %, reverting to the limit once unplugged.
    /// Returns a user-facing reason if it isn't possible, else nil.
    @discardableResult
    func topUp() -> String? {
        guard capable else { return "Set up Sous before topping up." }
        guard metrics.externalConnected else { return "Top up is only possible when the charger is connected." }
        config.enabled = true
        config.dischargeActive = false
        config.topUpActive = true
        return nil
    }

    /// Actively drain to the current limit while plugged in. Returns a reason if
    /// it isn't possible, else nil.
    @discardableResult
    func discharge() -> String? {
        guard capable else { return "Set up Sous before discharging." }
        guard metrics.externalConnected else { return "Discharge is only possible when the charger is connected." }
        guard displayPercent > config.chargeLimit else {
            return "Battery is already at or below your \(config.chargeLimit)% limit — there's nothing to discharge."
        }
        config.enabled = true
        config.topUpActive = false
        config.dischargeActive = true
        return nil
    }

    func cancelTransient() {
        config.topUpActive = false
        config.dischargeActive = false
    }

    // MARK: Plumbing

    private func commit() {
        if let data = try? JSONEncoder().encode(config) { defaults.set(data, forKey: configKey) }
        if helper.installState == .installed { helper.apply(config) }
        updateMenuTint()
    }

    private func updateMenuTint() {
        guard capable && config.enabled else { menuTint = .none; return }
        switch displayState {
        case .holding, .sailing:                       menuTint = .holding
        case .charging, .toppingUp, .discharging, .heatProtect: menuTint = .working
        case .off, .unplugged:                         menuTint = .none
        }
    }

    func setViewActive(_ active: Bool) {
        activeViewers = max(0, activeViewers + (active ? 1 : -1))
        if activeViewers > 0 { startFastMetrics() } else { stopFastMetrics() }
    }

    /// Power Flow refreshes at ~3 Hz while the Sous tab is on screen (cheap
    /// IORegistry reads), independent of the slower status poll.
    private var metricsTask: Task<Void, Never>?
    private func startFastMetrics() {
        guard metricsTask == nil else { return }
        metricsTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.metrics = BatteryReader.read()
                try? await Task.sleep(for: .milliseconds(333))
            }
        }
    }
    private func stopFastMetrics() {
        metricsTask?.cancel(); metricsTask = nil
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                let fast = (self?.activeViewers ?? 0) > 0
                try? await Task.sleep(for: .seconds(fast ? 3 : 12))
            }
        }
    }

    private func poll() async {
        await helper.refresh()
        metrics = BatteryReader.read()
        if helper.installState == .installed {
            helper.apply(config)                 // keep the daemon in sync (idempotent)
            if let s = await helper.fetchStatus() { status = s }
        }
        updateMenuTint()
    }

    /// Force an immediate refresh (e.g. right after install/approval).
    func refreshNow() { Task { await poll() } }
}
