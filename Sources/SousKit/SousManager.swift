import Foundation
import Combine
import SousShared
import PanelKit

/// Single source of truth for Sous in the app. Persists the user's `SousConfig`,
/// pushes it to the daemon, and polls battery metrics + daemon status so the UI
/// and the menu-bar icon stay live. Shared so both the host app's panel and its
/// menu-bar icon observe the same state.
@MainActor
public final class SousManager: ObservableObject {
    public static let shared = SousManager()

    /// Coarse menu-bar signal: green = held at the limit, orange = actively
    /// working (charging toward / discharging / heat-paused), none = idle.
    public enum MenuTint { case none, holding, working }

    /// The rearrangeable cards on the Sous tab (Power Flow is fixed, not in here).
    /// Declaration order is the default layout for fresh installs; raw values
    /// persist a user's own arrangement.
    public enum SousWidget: String, Codable, CaseIterable, Identifiable {
        case battery, calibration, stats
        public var id: String { rawValue }
    }

    /// How often to run an automatic calibration cycle (AlDente-style).
    public enum CalibrationSchedule: String, Codable, CaseIterable, Identifiable {
        case off, biweekly, monthly, bimonthly
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .off:       return "Off"
            case .biweekly:  return "Every 2 weeks"
            case .monthly:   return "Monthly"
            case .bimonthly: return "Every 2 months"
            }
        }
        /// Spacing between automatic runs, in seconds. Nil when off.
        public var interval: TimeInterval? {
            let day = 86_400.0
            switch self {
            case .off:       return nil
            case .biweekly:  return 14 * day
            case .monthly:   return 30 * day
            case .bimonthly: return 60 * day
            }
        }
    }

    @Published public var config: SousConfig { didSet { if config != oldValue { commit() } } }
    @Published public private(set) var status = SousStatus()
    @Published public private(set) var metrics = BatteryMetrics() { didSet { throttleLifeMetrics() } }
    /// A copy of `metrics` refreshed at most once every 6 s, used for the battery
    /// life/health detail so its numbers don't flicker at the Power Flow refresh
    /// rate (~3 Hz). Power Flow itself keeps using the live `metrics`.
    @Published public private(set) var lifeMetrics = BatteryMetrics()
    @Published public private(set) var menuTint: MenuTint = .none
    /// When the last calibration cycle completed, persisted across launches.
    @Published public private(set) var lastCalibration: Date?
    /// User-arranged order of the Sous tab cards; persisted on change.
    @Published public var widgetOrder: [SousWidget] { didSet { persistWidgetOrder() } }
    /// Automatic calibration cadence; persisted on change.
    @Published public var calibrationSchedule: CalibrationSchedule { didSet { persistSchedule() } }

    public let helper = SousHelperClient()

    private let defaults = PanelKit.settingsDefaults
    private let configKey = "sousConfig"
    private let lastCalibrationKey = "sousLastCalibration"
    private let widgetOrderKey = "sousWidgetOrder"
    private let scheduleKey = "sousCalibrationSchedule"
    private let scheduleAnchorKey = "sousScheduleAnchor"
    /// Baseline for the schedule when there's no prior calibration to count from.
    private var scheduleAnchor: Date?
    private var lastLifeUpdate = Date.distantPast
    private static let lifeRefreshInterval: TimeInterval = 6
    /// Tracks whether we've seen the daemon actually running a cycle, so we can
    /// detect the finished edge and clear our own one-shot flag.
    private var sawCalibrationRunning = false
    private var pollTask: Task<Void, Never>?
    /// Faster polling while the panel is on screen.
    private var activeViewers = 0
    /// Whether the panel is on screen. Fast metrics run only while a viewer is
    /// mounted AND the panel is visible - hiding the panel doesn't fire
    /// `.onDisappear`, so this is what stops the 3 Hz power-flow refresh from
    /// churning off-screen. The charge-limit control logic in `poll()` runs
    /// regardless.
    private var panelOpen = false
    private var visibilityObserver: NSObjectProtocol?

    private init() {
        if let data = defaults.data(forKey: configKey),
           let saved = try? JSONDecoder().decode(SousConfig.self, from: data) {
            config = SafetyFloors.clamp(saved)
        } else {
            config = SousConfig()
        }
        lastCalibration = defaults.object(forKey: lastCalibrationKey) as? Date
        scheduleAnchor = defaults.object(forKey: scheduleAnchorKey) as? Date
        if let raw = defaults.string(forKey: scheduleKey), let s = CalibrationSchedule(rawValue: raw) {
            calibrationSchedule = s
        } else {
            calibrationSchedule = .off
        }
        if let data = defaults.data(forKey: widgetOrderKey),
           let order = try? JSONDecoder().decode([SousWidget].self, from: data) {
            // Tolerate added/removed widgets across versions: keep saved order,
            // append any that are new, drop any that no longer exist.
            let known = Set(SousWidget.allCases)
            widgetOrder = order.filter(known.contains) + SousWidget.allCases.filter { !order.contains($0) }
        } else {
            widgetOrder = SousWidget.allCases
        }
        // The poll loop pings the daemon, re-asserts config, and refreshes status.
        startPolling()
        panelOpen = PanelVisibility.shared.isOpen
        visibilityObserver = NotificationCenter.default.addObserver(
            forName: .panelVisibilityChanged, object: nil, queue: .main) { [weak self] note in
            let open = (note.object as? Bool) ?? false
            Task { @MainActor in self?.setPanelOpen(open) }
        }
    }

    /// Panel shown/hidden: stop or resume the fast power-flow refresh (and snap a
    /// fresh reading on reopen, since `.onAppear` won't fire again for an
    /// already-mounted view). The always-on `pollTask` keeps charge control alive.
    private func setPanelOpen(_ open: Bool) {
        guard panelOpen != open else { return }
        panelOpen = open
        reevaluateFastMetrics()
        if open { refreshNow() }
    }

    /// Fast metrics want both a mounted viewer and a visible panel.
    private var fastMetricsWanted: Bool { activeViewers > 0 && panelOpen }
    private func reevaluateFastMetrics() {
        if fastMetricsWanted { startFastMetrics() } else { stopFastMetrics() }
    }

    // MARK: Display

    /// Sous is actually able to control charging right now.
    public var capable: Bool { helper.installState == .installed && status.capable }

    /// The state to show. Prefer the daemon's authoritative state; fall back to
    /// an honest metrics-derived value when the daemon isn't controlling.
    public var displayState: SousState {
        if capable && (config.enabled || config.calibrationActive) { return status.state }
        if !metrics.externalConnected { return .unplugged }
        if metrics.isCharging { return .charging }
        return .off          // plugged, not charging, Sous not controlling
    }

    /// Battery % to show — the daemon's hardware reading when available, else the
    /// macOS-reported value.
    public var displayPercent: Int {
        if capable, status.hardwareCharge >= 0 { return status.hardwareCharge }
        return metrics.macOSPercent
    }

    public var tempC: Double { capable ? status.tempC : metrics.tempC }

    // MARK: Intents

    public func setEnabled(_ on: Bool) { config.enabled = on }
    public func setLimit(_ pct: Int) { config.chargeLimit = min(max(pct, SafetyFloors.minChargeLimit), 100) }
    public func setSailing(_ pct: Int) { config.sailingRange = min(max(pct, 0), SafetyFloors.maxSailingRange) }
    public func setHeatProtect(_ on: Bool) { config.heatProtectEnabled = on }
    public func setMaxTemp(_ c: Double) { config.maxTempC = c }
    public func setControlLED(_ on: Bool) { config.controlLED = on }

    /// This Mac exposes the MagSafe/adapter LED (daemon confirmed the SMC key).
    public var canControlLED: Bool { capable && status.canControlLED }

    /// One-shot charge to 100 %, reverting to the limit once unplugged.
    /// Returns a user-facing reason if it isn't possible, else nil.
    @discardableResult
    public func topUp() -> String? {
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
    public func discharge() -> String? {
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

    public func cancelTransient() {
        config.topUpActive = false
        config.dischargeActive = false
    }

    // MARK: Calibration

    /// True while a calibration cycle is running on the daemon.
    public var isCalibrating: Bool { config.calibrationActive }

    /// The daemon's current calibration phase (`.idle` when not calibrating).
    public var calibrationPhase: CalibrationPhase { status.calibrationPhase }

    /// Begin a one-shot calibration cycle. Returns a user-facing reason if it
    /// can't start, else nil.
    @discardableResult
    public func startCalibration() -> String? {
        guard capable else { return "Set up Sous before calibrating." }
        guard metrics.externalConnected else { return "Calibration needs the charger connected the whole time." }
        // Clear any conflicting one-shots; the daemon ignores the limit while
        // calibrating, so the toggle state doesn't matter.
        config.topUpActive = false
        config.dischargeActive = false
        config.calibrationActive = true
        refreshNow()
        return nil
    }

    /// Abort calibration and hand charging back to the normal limit.
    public func cancelCalibration() {
        config.calibrationActive = false
    }

    /// When the next automatic calibration is due, or nil when scheduling is off.
    /// Counts from the last calibration if there is one, else from when the
    /// schedule was switched on.
    public var nextCalibrationDue: Date? {
        guard let interval = calibrationSchedule.interval else { return nil }
        let base = lastCalibration ?? scheduleAnchor ?? Date()
        return base.addingTimeInterval(interval)
    }

    public func setCalibrationSchedule(_ s: CalibrationSchedule) { calibrationSchedule = s }

    /// Start a scheduled calibration if one is due and conditions allow. Called
    /// from the poll loop. Silently no-ops when not applicable.
    private func maybeAutoCalibrate() {
        guard calibrationSchedule != .off, !isCalibrating, capable, metrics.externalConnected else { return }
        guard let due = nextCalibrationDue, Date() >= due else { return }
        startCalibration()
    }

    /// Mirror `metrics` into `lifeMetrics` no more than once per refresh window,
    /// so the battery detail updates on a calm cadence. The first reading always
    /// lands immediately (distantPast baseline).
    private func throttleLifeMetrics() {
        let now = Date()
        guard now.timeIntervalSince(lastLifeUpdate) >= Self.lifeRefreshInterval else { return }
        lastLifeUpdate = now
        lifeMetrics = metrics
    }

    private func persistWidgetOrder() {
        if let data = try? JSONEncoder().encode(widgetOrder) { defaults.set(data, forKey: widgetOrderKey) }
    }

    private func persistSchedule() {
        defaults.set(calibrationSchedule.rawValue, forKey: scheduleKey)
        // Anchor the countdown when scheduling is first switched on without a
        // prior calibration to measure from; clear it when turned off.
        if calibrationSchedule == .off {
            scheduleAnchor = nil
            defaults.removeObject(forKey: scheduleAnchorKey)
        } else if scheduleAnchor == nil && lastCalibration == nil {
            scheduleAnchor = Date()
            defaults.set(scheduleAnchor, forKey: scheduleAnchorKey)
        }
    }

    // MARK: Plumbing

    private func commit() {
        if let data = try? JSONEncoder().encode(config) { defaults.set(data, forKey: configKey) }
        if helper.installState == .installed { helper.apply(config) }
        updateMenuTint()
    }

    private func updateMenuTint() {
        guard capable && (config.enabled || config.calibrationActive) else { menuTint = .none; return }
        switch displayState {
        case .holding, .sailing:                       menuTint = .holding
        case .charging, .toppingUp, .discharging, .heatProtect, .calibrating: menuTint = .working
        case .off, .unplugged:                         menuTint = .none
        }
    }

    public func setViewActive(_ active: Bool) {
        activeViewers = max(0, activeViewers + (active ? 1 : -1))
        reevaluateFastMetrics()
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
                let fast = self?.fastMetricsWanted ?? false
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
        reconcileCalibration()
        maybeAutoCalibrate()
        updateMenuTint()
    }

    /// The daemon clears `calibrationActive` internally when the cycle ends, but
    /// our persisted config still holds it true — and the idempotent re-apply
    /// would re-arm it. Detect the running→idle edge from the reported phase and
    /// clear our own flag, recording when it finished.
    private func reconcileCalibration() {
        guard config.calibrationActive else { sawCalibrationRunning = false; return }
        if status.calibrationPhase != .idle {
            sawCalibrationRunning = true
        } else if sawCalibrationRunning {
            // Was running, daemon now reports idle → completed.
            sawCalibrationRunning = false
            config.calibrationActive = false
            lastCalibration = Date()
            defaults.set(lastCalibration, forKey: lastCalibrationKey)
        }
    }

    /// Force an immediate refresh (e.g. right after install/approval).
    public func refreshNow() { Task { await poll() } }
}
