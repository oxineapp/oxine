import Foundation
import Combine
import TemperShared
import PanelKit

/// Single source of truth for Temper in the app. Polls unprivileged thermal /
/// fan / load metrics (works on every Mac, no daemon), and - when the fan helper
/// is installed - pushes the user's `TemperConfig` and reads back daemon status.
/// Shared so the panel and the menu-bar bead observe the same state.
@MainActor
public final class TemperManager: ObservableObject {
    public static let shared = TemperManager()

    /// Coarse menu-bar signal from macOS thermal pressure: hot = critical (red),
    /// warm = serious (orange), none otherwise. Surfaces throttling at a glance.
    public enum MenuTint { case none, warm, hot }

    /// Temperature display unit. Stored values stay Celsius everywhere (SMC,
    /// config, daemon); this only affects what's shown.
    public enum TempUnit: String, Codable, CaseIterable, Identifiable {
        case celsius, fahrenheit
        public var id: String { rawValue }
        public var label: String { self == .celsius ? "Celsius" : "Fahrenheit" }
        public var symbol: String { self == .celsius ? "°C" : "°F" }
        /// Convert a Celsius value to this unit.
        public func value(_ c: Double) -> Double { self == .celsius ? c : c * 9 / 5 + 32 }
        /// Format a Celsius value as a whole number in this unit (no symbol).
        public func string(_ c: Double) -> String { "\(Int(value(c).rounded()))" }
    }

    /// The rearrangeable cards on the Temper tab (the header is fixed, not here).
    /// Declaration order is the default layout; raw values persist a user's own
    /// arrangement - same pattern as Sous.
    public enum TemperWidget: String, Codable, CaseIterable, Identifiable {
        case control, fans, sensors
        public var id: String { rawValue }
    }

    @Published public var config: TemperConfig { didSet { if config != oldValue { commit() } } }
    @Published public private(set) var metrics = TemperMetrics()
    @Published public private(set) var status = TemperStatus()
    @Published public private(set) var menuTint: MenuTint = .none
    /// User-arranged order of the Temper cards; persisted on change.
    @Published public var widgetOrder: [TemperWidget] { didSet { persistWidgetOrder() } }
    /// Which sensor key drives the big header temperature, or nil for "auto"
    /// (the hottest sensor). Persisted; chosen from the header temp's picker.
    @Published public var displaySensorKey: String? { didSet { persistDisplaySensor() } }
    /// Celsius or Fahrenheit for all displayed temperatures. Persisted.
    @Published public var tempUnit: TempUnit { didSet { persistUnit() } }
    /// When on, dragging one fan's manual slider moves every fan together.
    @Published public var fansLinked: Bool { didSet { persistLinked() } }

    public let helper = TemperHelperClient()
    private let reader = ThermalReader()

    private let defaults = PanelKit.settingsDefaults
    private let configKey = "temperConfig"
    private var pollTask: Task<Void, Never>?
    private var metricsTask: Task<Void, Never>?
    private var activeViewers = 0
    private var thermalObserver: NSObjectProtocol?

    private let widgetOrderKey = "temperWidgetOrder"
    private let displaySensorKey_ = "temperDisplaySensor"
    private let tempUnitKey = "temperUnit"
    private let fansLinkedKey = "temperFansLinked"

    private init() {
        if let data = defaults.data(forKey: configKey),
           let saved = try? JSONDecoder().decode(TemperConfig.self, from: data) {
            config = TemperSafety.clamp(saved)
        } else {
            config = TemperConfig()
        }
        if let data = defaults.data(forKey: widgetOrderKey),
           let order = try? JSONDecoder().decode([TemperWidget].self, from: data) {
            // Tolerate added/removed widgets across versions (same as Sous).
            let known = Set(TemperWidget.allCases)
            widgetOrder = order.filter(known.contains) + TemperWidget.allCases.filter { !order.contains($0) }
        } else {
            widgetOrder = TemperWidget.allCases
        }
        displaySensorKey = defaults.string(forKey: displaySensorKey_)
        tempUnit = defaults.string(forKey: tempUnitKey).flatMap(TempUnit.init) ?? .celsius
        fansLinked = defaults.bool(forKey: fansLinkedKey)
        startPolling()
        // Snappy tint updates the instant macOS changes thermal pressure.
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshMetricsOnly() }
        }
    }

    // MARK: Display

    /// Temper can actually drive fans right now (helper installed + machine has
    /// writable fan keys).
    public var capable: Bool { helper.installState == .installed && status.controllable }

    /// This Mac has fans at all (known from unprivileged reads, before any
    /// install) - gates whether the control UI is even offered.
    public var fansPresent: Bool { !metrics.fans.isEmpty || status.fanCount > 0 }

    /// Fans to display. Always the unprivileged read (`metrics.fans`), which the
    /// view refreshes at ~5 Hz - the daemon's `status.fans` only arrives on the
    /// slow status poll (every few seconds), so using it here was what made the
    /// RPM readout look stuck. Fall back to the daemon list only if the app's own
    /// read somehow finds no fans but the daemon does.
    public var displayFans: [FanInfo] { !metrics.fans.isEmpty ? metrics.fans : status.fans }

    public var thermalState: ProcessInfo.ThermalState { metrics.thermalState }
    public var hottestC: Double { max(metrics.hottestC, capable ? status.hottestC : 0) }

    // MARK: Control intents
    //
    // Automatic modes (Default / Smart / Curve) are GLOBAL - picking one drives
    // every fan. Manual is PER-FAN - dragging a single fan's speed slider puts
    // just that fan into manual at that speed (so the automatic picker shows no
    // selection while any fan is on manual).

    /// A representative setting (first fan), e.g. for the shared curve. Safe
    /// default before any fan is known.
    public var control: FanSetting { config.fans.first ?? FanSetting(index: 0) }

    /// The stored setting for a specific fan.
    public func setting(for index: Int) -> FanSetting? { config.setting(for: index) }

    /// The automatic mode every fan currently shares, or nil when fans differ
    /// (e.g. one was dragged to Manual). Drives the global picker's selection.
    public var commonMode: FanControlMode? {
        let modes = Set(config.fans.map(\.mode))
        return modes.count == 1 ? modes.first : nil
    }

    public func setMode(_ mode: FanControlMode) { mutateAll { $0.mode = mode } }
    public func setCurve(_ points: [FanCurvePoint]) { mutateAll { $0.curve = points } }

    /// Set every fan to Manual at the same speed (the selector's Manual bar).
    public func setManualAll(_ pct: Double) {
        mutateAll { $0.mode = .manual; $0.manualPercent = min(max(pct, 0), 100) }
    }

    /// Drag a single fan's speed slider → just that fan goes Manual at `pct`.
    public func setManual(fan i: Int, percent pct: Double) {
        mutateFan(i) { $0.mode = .manual; $0.manualPercent = min(max(pct, 0), 100) }
    }

    /// The speed (0–100 %) Temper is commanding `fan` right now, or nil when that
    /// fan is hands-off (Default, or Smart while it's idle) and macOS owns it.
    public func commandedPercent(for fan: FanInfo) -> Double? {
        config.setting(for: fan.index)?.resolvedPercent(hottest: hottestC, pressureBias: pressureBias)
    }

    private func mutateAll(_ body: (inout FanSetting) -> Void) {
        config.fans = config.fans.map { var f = $0; body(&f); return f }
    }

    private func mutateFan(_ i: Int, _ body: (inout FanSetting) -> Void) {
        config.fans = config.fans.map { var f = $0; if f.index == i { body(&f) }; return f }
    }

    public func setDisplaySensor(_ key: String?) { displaySensorKey = key }

    private func persistWidgetOrder() {
        if let data = try? JSONEncoder().encode(widgetOrder) { defaults.set(data, forKey: widgetOrderKey) }
    }

    private func persistDisplaySensor() {
        if let displaySensorKey { defaults.set(displaySensorKey, forKey: displaySensorKey_) }
        else { defaults.removeObject(forKey: displaySensorKey_) }
    }

    private func persistUnit() { defaults.set(tempUnit.rawValue, forKey: tempUnitKey) }
    private func persistLinked() { defaults.set(fansLinked, forKey: fansLinkedKey) }

    /// Drag handler for a fan slider: respects the link toggle (move all together
    /// when linked, else just that fan).
    public func scrubManual(fan i: Int, percent pct: Double) {
        if fansLinked { setManualAll(pct) } else { setManual(fan: i, percent: pct) }
    }

    /// Format a Celsius value in the user's chosen unit, e.g. "54°C" / "129°F".
    public func temp(_ celsius: Double) -> String { "\(tempUnit.string(celsius))\(tempUnit.symbol)" }

    /// 0–1 thermal-pressure bias from macOS, for the live Smart preview (matches
    /// the daemon's own mapping in `TemperService.pressureBias`).
    public var pressureBias: Double {
        switch metrics.thermalState {
        case .nominal:  return 0
        case .fair:     return 0.4
        case .serious:  return 0.75
        case .critical: return 1
        @unknown default: return 0
        }
    }

    /// What Smart would command right now (nil = staying hands-off), for the
    /// adaptive readout in the UI.
    public var smartTargetNow: Double? {
        TemperSmart.percent(hottest: hottestC, pressureBias: pressureBias)
    }

    /// Ensure there's exactly one `FanSetting` per fan the machine reports, adding
    /// defaults for new indices and dropping stale ones. Called from the poll loop
    /// once the fan count is known; only mutates (and thus persists) on a change.
    private func reconcileFans(count: Int) {
        guard count > 0 else { return }
        let have = Set(config.fans.map(\.index))
        let want = Set(0..<count)
        guard have != want else { return }
        var fans = config.fans.filter { want.contains($0.index) }
        // New fans inherit the shared control setting so every fan stays in sync.
        let template = config.fans.first
        for i in 0..<count where !have.contains(i) {
            fans.append(FanSetting(index: i,
                                   mode: template?.mode ?? .default,
                                   manualPercent: template?.manualPercent ?? 50,
                                   curve: template?.curve ?? FanSetting.defaultCurve))
        }
        config.fans = fans.sorted { $0.index < $1.index }
    }

    // MARK: Plumbing

    private func commit() {
        if let data = try? JSONEncoder().encode(config) { defaults.set(data, forKey: configKey) }
        if helper.installState == .installed { helper.apply(config) }
    }

    private func updateMenuTint() {
        switch metrics.thermalState {
        case .critical: menuTint = .hot
        case .serious:  menuTint = .warm
        default:        menuTint = .none
        }
    }

    public func setViewActive(_ active: Bool) {
        activeViewers = max(0, activeViewers + (active ? 1 : -1))
        if activeViewers > 0 { startFastMetrics() } else { stopFastMetrics() }
    }

    private func refreshMetricsOnly(updateCPU: Bool = true) {
        metrics = reader.read(updateCPU: updateCPU)
        reconcileFans(count: metrics.fans.count)
        updateMenuTint()
    }

    /// While the Temper tab is on screen, refresh on a 2 Hz tick: fan speeds and
    /// temperatures update every tick (2 Hz), CPU load only every other tick
    /// (1 Hz). SMC reads are cheap and unprivileged.
    private func startFastMetrics() {
        guard metricsTask == nil else { return }
        metricsTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                self?.refreshMetricsOnly(updateCPU: tick % 2 == 0)
                tick += 1
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
    private func stopFastMetrics() { metricsTask?.cancel(); metricsTask = nil }

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
        metrics = reader.read()
        if helper.installState == .installed {
            helper.apply(config)                 // keep the daemon in sync (idempotent)
            if let s = await helper.fetchStatus() { status = s }
        }
        reconcileFans(count: max(metrics.fans.count, status.fanCount))
        updateMenuTint()
    }

    /// Force an immediate refresh (e.g. right after install/approval).
    public func refreshNow() { Task { await poll() } }
}
