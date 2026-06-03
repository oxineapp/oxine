import Foundation

/// Types and identifiers shared verbatim between a host app and the privileged
/// `Temper` fan-control daemon. Kept dependency-free so both sides can link it.
/// Deliberately parallel to `SousShared` - Temper is a sibling extension with its
/// own daemon, touching disjoint SMC registers (the `F*`/`Ftst` fan keys vs
/// Sous's `CH0*` charge keys), so the two daemons coexist on one machine.
public enum TemperXPC {
    /// Bumped whenever the daemon binary or config contract changes so the app can
    /// detect a stale installed helper and re-register (one admin prompt). v2: the
    /// config moved from a single global mode to per-fan `FanSetting`s.
    public static let helperVersion = "2"
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
            + "(certificate leaf[subject.CN] = \"Oxine\" or certificate leaf[subject.CN] = \"Oxine Dev\")"
    )

    /// The standalone (future) sous-vide-style Temper app's daemon, kept here so
    /// the contract is defined in one place.
    public static let temperApp = TemperHelperBranding(
        machServiceName: "com.temper.temperhelper",
        logSubsystem: "com.temper.temperhelper",
        clientRequirement: "identifier \"com.temper.app\" and "
            + "(certificate leaf[subject.CN] = \"Oxine\" or certificate leaf[subject.CN] = \"Oxine Dev\")"
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

/// Temper's adaptive "Smart" controller, shared so the daemon (which applies it)
/// and the app (which previews it live) compute identically. Returns the fan
/// speed 0–100 %, or nil to mean "stay hands-off and let macOS idle the fans".
///
/// The idea: while genuinely cool it returns nil, so fans can sit at 0 rpm just
/// like Default. Once it warms past a floor - or the OS reports thermal pressure
/// - it takes over and ramps, and it gets *more* aggressive (lower floor, earlier
/// ceiling) the higher the pressure. `pressureBias` is 0 (nominal) … 1 (critical).
public enum TemperSmart {
    public static func percent(hottest: Double, pressureBias bias: Double) -> Double? {
        let b = min(max(bias, 0), 1)
        // Stay fully hands-off only when both cool AND the OS is calm.
        if hottest < 55 && b < 0.25 { return nil }
        // Adaptive ramp window: shifts down/steeper as pressure rises.
        let floor = 55 - b * 15        // 55 → 40 °C
        let ceil  = 88 - b * 13        // 88 → 75 °C
        guard ceil > floor else { return 100 }
        let f = min(max((hottest - floor) / (ceil - floor), 0), 1)
        // A gentle ease so it eases in rather than snapping off the floor.
        let eased = f * f * (3 - 2 * f)
        return eased * 100
    }
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
    public func resolvedPercent(hottest: Double, pressureBias bias: Double) -> Double? {
        switch mode {
        case .default: return nil
        case .manual:  return min(max(manualPercent, 0), 100)
        case .smart:   return TemperSmart.percent(hottest: hottest, pressureBias: bias)
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

    public init(fans: [FanSetting] = []) { self.fans = fans }

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
    /// Above this temperature the daemon abandons manual control and hands the
    /// fans straight back to macOS's thermal management - no user setting can
    /// override this. The whole point of forcing fans is moot if it overheats.
    public static let thermalCutoutC = 95.0

    public static func clamp(_ c: TemperConfig) -> TemperConfig {
        var c = c
        c.fans = c.fans.map(clampFan)
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

    public init(controllable: Bool = false,
                fanCount: Int = 0,
                fans: [FanInfo] = [],
                controlling: Bool = false,
                hottestC: Double = 0,
                thermalCutout: Bool = false,
                lastError: String? = nil) {
        self.controllable = controllable
        self.fanCount = fanCount
        self.fans = fans
        self.controlling = controlling
        self.hottestC = hottestC
        self.thermalCutout = thermalCutout
        self.lastError = lastError
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
