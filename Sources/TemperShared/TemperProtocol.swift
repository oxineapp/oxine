import Foundation

/// Types and identifiers shared verbatim between a host app and the privileged
/// `Temper` fan-control daemon. Kept dependency-free so both sides can link it.
/// Deliberately parallel to `SousShared` - Temper is a sibling extension with its
/// own daemon, touching disjoint SMC registers (the `F*`/`Ftst` fan keys vs
/// Sous's `CH0*` charge keys), so the two daemons coexist on one machine.
public enum TemperXPC {
    /// Bumped whenever the daemon binary or config contract changes so the app can
    /// detect a stale installed helper and re-register (one admin prompt). v2: the
    /// config moved from a single global mode to per-fan `FanSetting`s. v4: Smart
    /// steers on the CPU die average instead of the hottest core.
    public static let helperVersion = "4"
}

/// Per-brand identity for a Temper daemon: launchd label / Mach service, log
/// subsystem, and the codesign requirement it enforces on clients. Mirrors
/// `HelperBranding` in SousShared but kept separate so Temper stays independent.
public struct TemperHelperBranding: Sendable {
    /// launchd label == Mach service name == helper binary file name.
    public let machServiceName: String
    /// os.Logger subsystem for the daemon's logging.
    public let logSubsystem: String
    /// The codesign requirement a connecting client must satisfy. Pins the host
    /// app's identity; the daemon rejects any XPC peer that fails it.
    public let clientRequirement: String

    public init(machServiceName: String, logSubsystem: String, clientRequirement: String) {
        self.machServiceName = machServiceName
        self.logSubsystem = logSubsystem
        self.clientRequirement = clientRequirement
    }

    public var label: String { machServiceName }
    public var plistName: String { machServiceName + ".plist" }
    public var plistPath: String { "/Library/LaunchDaemons/" + plistName }

    /// Whether this brand's Temper daemon is installed (world-readable plist path;
    /// no privileges, no XPC round-trip needed).
    public var isDaemonInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    /// Oxine's fan daemon: `com.oxine.temperhelper`, accepting the Oxine app
    /// signed by our own "Oxine" / "Oxine Dev" self-signed certs (same trust
    /// anchor Sous uses).
    public static let oxine = TemperHelperBranding(
        machServiceName: "com.oxine.temperhelper",
        logSubsystem: "com.oxine.temperhelper",
        clientRequirement: "identifier \"com.oxine.app\" and "
            + "(certificate leaf[subject.CN] = \"Oxine\" or certificate leaf[subject.CN] = \"Oxine Dev\" or (anchor apple generic and (certificate leaf[subject.OU] = \"TMF25D4TR4\" or certificate leaf[subject.OU] = \"3VSFGRSSZD\")))"
    )

    /// The standalone (future) sous-vide-style Temper app's daemon, kept here so
    /// the contract is defined in one place.
    public static let temperApp = TemperHelperBranding(
        machServiceName: "com.temper.temperhelper",
        logSubsystem: "com.temper.temperhelper",
        clientRequirement: "identifier \"com.temper.app\" and "
            + "(certificate leaf[subject.CN] = \"Oxine\" or certificate leaf[subject.CN] = \"Oxine Dev\" or (anchor apple generic and (certificate leaf[subject.OU] = \"TMF25D4TR4\" or certificate leaf[subject.OU] = \"3VSFGRSSZD\")))"
    )
}

/// How the user wants the fans driven. Ascending "how much Temper takes over
/// from macOS": hands-off, fixed, adaptive, fully custom.
public enum FanControlMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Hand the fans back to macOS (its own thermal curve). Monitoring still
    /// works; the daemon writes nothing.
    case `default`
    /// Hold a fixed speed across the fan's range (one percentage).
    case manual
    /// Daemon-managed *adaptive* control: behaves like Default while cool (fans
    /// can idle / hit 0), then ramps in on its own as heat builds, more
    /// aggressively the higher the system's thermal pressure. No tuning, no curve.
    case smart
    /// Fully user-drawn curve of (temperature, speed) points.
    case curve

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .default: return "Default"
        case .manual:  return "Manual"
        case .smart:   return "Smart"
        case .curve:   return "Curve"
        }
    }
    public var icon: String {
        switch self {
        case .default: return "gearshape"
        case .manual:  return "slider.horizontal.3"
        case .smart:   return "sparkles"
        case .curve:   return "point.topleft.down.to.point.bottomright.curvepath"
        }
    }
    public var blurb: String {
        switch self {
        case .default: return "macOS manages the fans on its own curve."
        case .manual:  return "Hold the fans at a fixed speed."
        case .smart:   return "Ramps in on its own as it heats up, and adapts to load."
        case .curve:   return "Draw your own temperature-to-speed curve."
        }
    }
}

/// Temper's adaptive "Smart" controller - the *instantaneous demand*: the fan
/// fraction (0–100 %) the current thermal situation calls for, or nil to stay
/// hands-off (let macOS idle the fans toward 0 rpm).
///
/// This is a pure *setpoint* controller: it aims to hold a target temperature,
/// ramping the fan as the (smoothed) temperature approaches that setpoint, and it
/// *anticipates* - a fast upward `rising` rate pre-spins the fan before the heat
/// arrives. `temperament` slides the whole behaviour from Silent (hotter setpoint,
/// lazy) to Cool (lower setpoint, eager). `bias` is the 0–1 macOS thermal-pressure
/// feedforward, which pulls the setpoint down so it acts before the SMC catches up.
///
/// It is deliberately stateless and shared so the daemon's stateful controller and
/// the app's live preview agree on the *aim*; the daemon then shapes this demand
/// over time (smoothing, slew, dead-band) in `SmartController`.
public enum TemperSmart {
    /// Default mid temperament when none is set.
    public static let neutralTemperament = 0.5

    /// The temperature the controller aims to *hold* for a given temperament: a
    /// lazy 92 °C at Silent (0) down to a reachable, still-distinct 70 °C at Cool
    /// (1). The range stops well above the old 60 °C so the eager end isn't a temp
    /// the die blows past under any load (which made 0.75…1.0 all peg at max and
    /// feel identical). Shared with the app so the profile selector's caption and
    /// the daemon's aim are always the same number.
    public static func targetTempC(temperament t: Double) -> Double {
        92 - min(max(t, 0), 1) * 22
    }

    /// Pure feedback demand, 0–100 %: the fan fraction the (effective) temperature
    /// calls for, holding an *ambient-adjusted* setpoint. No hands-off concept
    /// here - the stateful `SmartController` owns that once it folds in the power
    /// feedforward, transport gate, and learned plant model. `ambientC` relaxes the
    /// setpoint in a hot room (cooling is expensive and the floor is higher) and
    /// tightens it slightly when cold.
    public static func feedback(tempC T: Double,
                                risingCPerSec rise: Double = 0,
                                pressureBias bias: Double = 0,
                                temperament t: Double = neutralTemperament,
                                ambientC: Double = 25) -> Double {
        let t01 = min(max(t, 0), 1)
        let b = min(max(bias, 0), 1)
        // Temperament shapes EVERYTHING, not just the steady setpoint, so Silent and
        // Cool are genuinely different machines. Ambient slides the target.
        let setpoint = targetTempC(temperament: t01) + min(max(ambientC - 25, -8), 12) * 0.6
        let band = 20 - t01 * 6                           // wide, gradual ramp (Silent) … tighter (Cool)
        let lo = setpoint - band
        let hi = setpoint + 2
        // Proportional distance to setpoint, FLOORED at 0 so anticipation/pressure
        // can lift the fan while still cool.
        var f = max(0, (T - lo) / max(hi - lo, 1))
        f += min(rise * (t01 * 0.22), 0.4)               // temp-rise anticipation (backup for power FF)
        f += b * (0.05 + t01 * 0.15)
        let g = min(max(f, 0), 1)
        // Response shape: Silent convex (low plateau, late steep ramp), Cool ~linear.
        let shape = 1.0 + (1 - t01) * 2.0
        return pow(g, shape) * 100
    }

    /// Preview-grade demand for the app: the feedback term, or nil when it's
    /// effectively hands-off. The daemon uses `feedback` directly and adds the
    /// feedforward layers on top.
    public static func demand(tempC T: Double,
                              risingCPerSec rise: Double = 0,
                              pressureBias bias: Double = 0,
                              temperament t: Double = neutralTemperament,
                              ambientC: Double = 25) -> Double? {
        let f = feedback(tempC: T, risingCPerSec: rise, pressureBias: bias, temperament: t, ambientC: ambientC)
        return f < 1 ? nil : f
    }
}

/// The SMC temperature keys Temper probes, shared by the daemon (fan control +
/// safety) and the app's own reader (the UI sensor list) so the two can never
/// drift out of sync. De-duplicated by label downstream, first match wins - so
/// the Apple Silicon aggregate hotspots are listed first (the per-P-core `Tp0x`
/// keys floor at a useless 40 °C at idle and must not win). The Virtual Memory
/// keys are deliberately omitted: they read ~94 °C and would dominate `hottest`.
public enum TemperSensors {
    /// The sensor Smart steers on: the CPU **die average** (`TCMb`), not the CPU
    /// max (`TCMz`). The max tracks whichever single core spikes, so it's jumpy and
    /// over-cools; the die average is the representative, calmer signal to hold a
    /// setpoint against. Smart falls back to the hottest sensor when this key is
    /// absent (older / Intel Macs). The raw-max thermal cutout is separate and
    /// still watches the true hottest reading.
    public static let smartControlKey = "TCMb"

    public static let tempKeys: [(key: String, label: String)] = [
        ("TCMz", "CPU (max)"), ("TCMb", "CPU die avg"), ("TCHP", "CPU heatpipe"),
        ("TUDX", "SoC"),                                       // Uncore Die Max
        ("Tg0X", "GPU"), ("Tg05", "GPU"), ("TG0H", "GPU"),     // GPU hotspots
        ("Tsx1", "SSD"),                                       // SSD aggregate
        ("TaLP", "Airflow L"), ("TaRF", "Airflow R"),
        ("TB0T", "Battery"), ("TPMP", "Power mgmt"), ("TPSP", "Power supply"),
        // Legacy / Intel / older-AS fallbacks - same labels as the primaries above,
        // so they de-dup away (stay hidden) whenever the aggregates are present.
        // NB: the per-P-core `Tp0x` "CPU perf/eff" keys are intentionally NOT here -
        // they floor at 40 °C and only added a misleading stale-looking row.
        ("TC0P", "CPU (max)"), ("TC0E", "CPU (max)"),
        ("TG0P", "GPU"), ("TA0P", "Ambient"), ("Ts0P", "Enclosure"),
        ("TH0x", "SSD"), ("Tm0P", "Mainboard"),
    ]

    /// A richer, *grouped* sensor map for the optional "Extended temperature view"
    /// (Settings). Curated from the full SMC array: deduped to one representative
    /// per subsystem (using the aggregate / "Max" keys the SMC already provides),
    /// not the raw ~190 near-duplicate probes. Apple-Silicon-oriented; keys absent
    /// on a given Mac simply don't appear. The bogus Virtual Memory keys (`TVMR`,
    /// `TVMr`, ~105 °C) are deliberately excluded - they'd dominate any "hottest".
    /// Display only: Smart's control logic always uses `tempKeys`, never this.
    public static let extendedTempKeys: [(key: String, label: String, group: String)] = [
        ("TCMz", "Die (max)",    "CPU"), ("TCMb", "Die (avg)",  "CPU"),
        ("Tpx1", "P-cluster 1",  "CPU"), ("Tpx3", "P-cluster 2", "CPU"),
        ("Tpx5", "P-cluster 3",  "CPU"), ("Tex1", "E-cluster 1", "CPU"),
        ("Tex3", "E-cluster 2",  "CPU"), ("TCHP", "Heatpipe",    "CPU"),

        ("Tg0k", "GPU 1", "GPU"), ("Tg0z", "GPU 2", "GPU"), ("Tg1V", "GPU 3", "GPU"),
        ("Tg05", "GPU 4", "GPU"), ("TfC2", "Fabric", "GPU"),

        ("TUDX", "Uncore (max)", "SoC"), ("TVD0", "Virtual die", "SoC"),
        ("TSCP", "Cooling probe", "SoC"),

        ("Tsx1", "SSD",       "Memory"), ("Ts1P", "SSD controller", "Memory"),
        ("TH0x", "NAND",      "Memory"), ("TMVR", "Memory VR",      "Memory"),

        ("TPDX", "Delivery (max)", "Power"), ("TPMP", "Management", "Power"),
        ("TPSP", "Supply",         "Power"), ("TRDX", "RF delivery (max)", "Power"),

        ("TDVx", "Virtual", "Board"), ("TDEL", "Left",  "Board"),
        ("TDER", "Right",   "Board"), ("TDTC", "Top",   "Board"),

        ("TB0T", "Battery 1", "Battery"), ("TB1T", "Battery 2", "Battery"),
        ("TB2T", "Battery 3", "Battery"),

        ("TW0P", "Wi-Fi", "Wireless"), ("TaLT", "Thunderbolt L", "Wireless"),
        ("TaRT", "Thunderbolt R", "Wireless"),

        ("TaLP", "Airflow L", "Ambient"), ("TaRF", "Airflow R", "Ambient"),
        ("TAOL", "Lid",       "Ambient"), ("TVA0", "Virtual ambient", "Ambient"),
    ]

    /// Group order for the extended view, so sections render top-down sensibly.
    public static let extendedGroupOrder = ["CPU", "GPU", "SoC", "Memory", "Power", "Board", "Battery", "Wireless", "Ambient"]
}

/// One control point on a fan curve: a fan speed (`percent` of the fan's range)
/// to hold once the hottest sensor reaches `tempC`. The daemon interpolates
/// linearly between points and holds flat past the ends.
public struct FanCurvePoint: Codable, Sendable, Equatable {
    public var tempC: Double
    public var percent: Double
    public init(tempC: Double, percent: Double) {
        self.tempC = tempC
        self.percent = percent
    }
}

/// Per-fan settings - each fan is driven independently (a quiet exhaust fan can
/// sit on Smart while a GPU fan runs a steep custom curve).
public struct FanSetting: Codable, Sendable, Equatable, Identifiable {
    public var index: Int
    public var mode: FanControlMode
    /// Manual mode: 0–100 % of the fan's min→max range (0 = its reported minimum,
    /// a safe floor, not a stall).
    public var manualPercent: Double
    /// Curve mode: the (temperature, speed) points, ascending in temperature.
    public var curve: [FanCurvePoint]

    public var id: Int { index }

    public init(index: Int,
                mode: FanControlMode = .default,
                manualPercent: Double = 50,
                curve: [FanCurvePoint] = FanSetting.defaultCurve) {
        self.index = index
        self.mode = mode
        self.manualPercent = manualPercent
        self.curve = curve
    }

    /// A sensible starting curve for the Curve editor: silent when cool, full by
    /// the time it's hot.
    public static let defaultCurve: [FanCurvePoint] = [
        FanCurvePoint(tempC: 50, percent: 0),
        FanCurvePoint(tempC: 65, percent: 30),
        FanCurvePoint(tempC: 80, percent: 70),
        FanCurvePoint(tempC: 95, percent: 100),
    ]

    /// The speed (0–100 %) this fan should hold at `hottest`, or nil when this fan
    /// is hands-off (Default, or Smart while it's chosen to stay idle). `bias` is
    /// the 0–1 thermal-pressure bias, only used by Smart.
    public func resolvedPercent(hottest: Double, pressureBias bias: Double,
                                temperament: Double = TemperSmart.neutralTemperament) -> Double? {
        switch mode {
        case .default: return nil
        case .manual:  return min(max(manualPercent, 0), 100)
        case .smart:   return TemperSmart.demand(tempC: hottest, pressureBias: bias, temperament: temperament)
        case .curve:   return Self.interpolate(curve, at: hottest)
        }
    }

    /// Smooth, monotone interpolation through the curve, clamped flat beyond the
    /// end points. Uses Fritsch–Carlson monotone cubic tangents so the curve is
    /// rounded between points but never overshoots or wiggles below/above the
    /// points it connects - the right shape for a fan curve. Used both to draw
    /// the editor and to resolve the actual fan speed, so they always match.
    public static func interpolate(_ points: [FanCurvePoint], at temp: Double) -> Double {
        let p = points.sorted { $0.tempC < $1.tempC }
        guard let first = p.first, let last = p.last else { return 0 }
        if temp <= first.tempC { return first.percent }
        if temp >= last.tempC { return last.percent }
        if p.count == 2 {
            let f = (temp - first.tempC) / (last.tempC - first.tempC)
            return first.percent + f * (last.percent - first.percent)
        }
        let n = p.count
        // Secant slopes between successive points.
        var d = [Double](repeating: 0, count: n - 1)
        for i in 0..<n - 1 {
            let h = p[i + 1].tempC - p[i].tempC
            d[i] = h > 0 ? (p[i + 1].percent - p[i].percent) / h : 0
        }
        // Monotone tangents (Fritsch–Carlson): average secants, zeroed at extrema.
        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]; m[n - 1] = d[n - 2]
        for i in 1..<n - 1 {
            m[i] = (d[i - 1] * d[i] <= 0) ? 0 : (d[i - 1] + d[i]) / 2
        }
        for i in 0..<n - 1 where d[i] == 0 { m[i] = 0; m[i + 1] = 0 }
        // Hermite on the segment containing `temp`.
        for i in 1..<n where temp <= p[i].tempC {
            let a = p[i - 1], b = p[i]
            let h = b.tempC - a.tempC
            guard h > 0 else { return b.percent }
            let t = (temp - a.tempC) / h
            let t2 = t * t, t3 = t2 * t
            let h00 = 2 * t3 - 3 * t2 + 1
            let h10 = t3 - 2 * t2 + t
            let h01 = -2 * t3 + 3 * t2
            let h11 = t3 - t2
            let v = h00 * a.percent + h10 * h * m[i - 1] + h01 * b.percent + h11 * h * m[i]
            return min(max(v, 0), 100)
        }
        return last.percent
    }
}

/// What the user wants Temper to do with the fans. Sent app → daemon; the daemon
/// is the sole authority on how it's applied (and clamps every field - see
/// `TemperSafety`). Holds one `FanSetting` per fan the machine reports.
public struct TemperConfig: Codable, Sendable, Equatable {
    public var fans: [FanSetting]
    /// Global Smart temperament: 0 = Silent (hotter setpoint, lazy fans), 1 = Cool
    /// (lower setpoint, eager fans). Only affects fans in Smart mode.
    public var temperament: Double

    public init(fans: [FanSetting] = [], temperament: Double = TemperSmart.neutralTemperament) {
        self.fans = fans
        self.temperament = temperament
    }

    enum CodingKeys: String, CodingKey { case fans, temperament }

    // Tolerate configs persisted before `temperament` existed, so an upgrade
    // doesn't wipe the user's fan settings.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fans = try c.decodeIfPresent([FanSetting].self, forKey: .fans) ?? []
        temperament = try c.decodeIfPresent(Double.self, forKey: .temperament) ?? TemperSmart.neutralTemperament
    }

    /// Temper is driving at least one fan (anything other than all-Default).
    public var anyControlled: Bool { fans.contains { $0.mode != .default } }

    public func setting(for index: Int) -> FanSetting? { fans.first { $0.index == index } }
}

/// Hard limits the daemon enforces regardless of what the app asks - fans are a
/// safety system, so a buggy or hostile client can never cook the machine.
public enum TemperSafety {
    public static let minPercent = 0.0
    public static let maxPercent = 100.0
    /// Temperature bounds for curve points.
    public static let minCurveTempC = 30.0
    public static let maxCurveTempC = 105.0
    /// Once the raw die has been at/above this temperature *continuously* for
    /// `thermalCutoutSustainS`, the daemon forces every fan to maximum - no user
    /// setting can override this. (Max airflow is always safe; the SoC throttles
    /// itself regardless of who drives the fans.) Set high, and sustained, so
    /// Smart's own curve owns the ramp through the hot zone and a brief spike or a
    /// glitchy read can't trip the emergency - it's only a last-resort backstop.
    public static let thermalCutoutC = 100.0
    /// How long the die must stay at/above the cutout before the emergency engages.
    public static let thermalCutoutSustainS = 5.0
    /// How far it must cool back below the cutout before normal control resumes,
    /// so it doesn't flap on/off at the boundary.
    public static let cutoutHysteresisC = 5.0

    public static func clamp(_ c: TemperConfig) -> TemperConfig {
        var c = c
        c.fans = c.fans.map(clampFan)
        c.temperament = min(max(c.temperament, 0), 1)
        return c
    }

    public static func clampFan(_ f: FanSetting) -> FanSetting {
        var f = f
        f.manualPercent = min(max(f.manualPercent, minPercent), maxPercent)
        f.curve = f.curve
            .map { FanCurvePoint(tempC: min(max($0.tempC, minCurveTempC), maxCurveTempC),
                                 percent: min(max($0.percent, minPercent), maxPercent)) }
            .sorted { $0.tempC < $1.tempC }
        if f.curve.isEmpty { f.curve = FanSetting.defaultCurve }
        return f
    }
}

/// One fan's live state. RPM values are whatever the SMC reports (Apple Silicon =
/// IEEE-754 float; legacy = fpe2).
public struct FanInfo: Codable, Sendable, Equatable, Identifiable {
    public var index: Int
    public var actualRPM: Double
    public var minRPM: Double
    public var maxRPM: Double
    public var targetRPM: Double

    public init(index: Int, actualRPM: Double, minRPM: Double, maxRPM: Double, targetRPM: Double) {
        self.index = index
        self.actualRPM = actualRPM
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.targetRPM = targetRPM
    }

    public var id: Int { index }

    /// Where the actual speed sits in the fan's range, 0–1 (for a progress bar).
    public var fraction: Double {
        let span = maxRPM - minRPM
        guard span > 0 else { return 0 }
        return min(max((actualRPM - minRPM) / span, 0), 1)
    }
}

/// A snapshot of one Smart tick's reasoning, for the optional "Verbose Smart
/// output" diagram (Settings). Every term the controller balanced this tick, in
/// the order it applies them: the temperature it's controlling on, the target it
/// aims to hold, the three demand contributions (reactive feedback, power
/// feedforward, learned-plant floor), and the shaped result before/after slew.
/// All percentages are 0–100; `plantFloor < 0` means the plant model didn't apply.
public struct SmartDebug: Codable, Sendable, Equatable {
    public var temperament: Double
    public var controlTempC: Double
    public var setpointC: Double
    public var feedback: Double
    public var feedforward: Double
    public var plantFloor: Double
    public var demand: Double
    public var output: Double          // post-slew command; < 0 = hands-off (released)
    public var accumulation: Double
    public var risePerSec: Double
    public var powerW: Double
    public var powerBaselineW: Double
    public var ambientC: Double
    public var idleFloorC: Double
    public var handsOff: Bool

    public init(temperament: Double = 0, controlTempC: Double = 0, setpointC: Double = 0,
                feedback: Double = 0, feedforward: Double = 0, plantFloor: Double = -1,
                demand: Double = 0, output: Double = -1, accumulation: Double = 0,
                risePerSec: Double = 0, powerW: Double = 0, powerBaselineW: Double = 0,
                ambientC: Double = 0, idleFloorC: Double = 0, handsOff: Bool = true) {
        self.temperament = temperament; self.controlTempC = controlTempC; self.setpointC = setpointC
        self.feedback = feedback; self.feedforward = feedforward; self.plantFloor = plantFloor
        self.demand = demand; self.output = output; self.accumulation = accumulation
        self.risePerSec = risePerSec; self.powerW = powerW; self.powerBaselineW = powerBaselineW
        self.ambientC = ambientC; self.idleFloorC = idleFloorC; self.handsOff = handsOff
    }
}

/// Daemon → app snapshot. Encoded as JSON across XPC.
public struct TemperStatus: Codable, Sendable, Equatable {
    /// This Mac exposes writable fan keys (has fans the daemon can drive).
    public var controllable: Bool
    public var fanCount: Int
    public var fans: [FanInfo]
    /// The daemon is actively asserting manual control right now.
    public var controlling: Bool
    /// The hottest temperature the daemon can read (drives the curve + safety).
    public var hottestC: Double
    /// Safety cutout is engaged (too hot) - control was handed back to macOS.
    public var thermalCutout: Bool
    public var lastError: String?
    /// Last Smart computation, for the verbose diagram. Nil when no fan is on Smart.
    public var smartDebug: SmartDebug?

    public init(controllable: Bool = false,
                fanCount: Int = 0,
                fans: [FanInfo] = [],
                controlling: Bool = false,
                hottestC: Double = 0,
                thermalCutout: Bool = false,
                lastError: String? = nil,
                smartDebug: SmartDebug? = nil) {
        self.controllable = controllable
        self.fanCount = fanCount
        self.fans = fans
        self.controlling = controlling
        self.hottestC = hottestC
        self.thermalCutout = thermalCutout
        self.lastError = lastError
        self.smartDebug = smartDebug
    }
}

/// The XPC contract. JSON `Data` carries the Codable payloads so we avoid
/// NSSecureCoding boilerplate for our own value types. Mirrors `SousXPCProtocol`.
@objc public protocol TemperXPCProtocol {
    func applyConfig(_ data: Data, reply: @escaping @Sendable (Bool) -> Void)
    func fetchStatus(reply: @escaping @Sendable (Data?) -> Void)
    func helperVersion(reply: @escaping @Sendable (String) -> Void)
    func uninstall(reply: @escaping @Sendable (Bool) -> Void)
}
