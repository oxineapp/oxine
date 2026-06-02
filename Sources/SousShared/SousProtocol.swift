import Foundation

/// Types and identifiers shared verbatim between a host app and the privileged
/// `Sous` daemon. Kept dependency-free so both sides can link it.
public enum SousXPC {
    /// Bumped whenever the daemon binary changes so the app can detect a stale
    /// installed helper and re-register. Part of the protocol contract, so it's
    /// shared across brands (an Oxine and a sous-vide helper of the same version
    /// speak the same XPC).
    public static let helperVersion = "5"
}

/// Per-brand identity for a Sous daemon: its launchd label / Mach service, the
/// log subsystem, and the codesign requirement it enforces on clients. Two
/// signed apps can't share a launchd label, so each brand builds its own helper
/// from `SousHelperCore` with one of these, and the matching app talks to it.
public struct HelperBranding: Sendable {
    /// launchd label == Mach service name == helper binary file name.
    public let machServiceName: String
    /// os.Logger subsystem for the daemon's logging.
    public let logSubsystem: String
    /// The codesign requirement a connecting client must satisfy. The daemon
    /// rejects any XPC peer that fails it. Pins the host app's identity.
    public let clientRequirement: String

    public init(machServiceName: String, logSubsystem: String, clientRequirement: String) {
        self.machServiceName = machServiceName
        self.logSubsystem = logSubsystem
        self.clientRequirement = clientRequirement
    }

    /// launchd label (same string as the Mach service, by convention).
    public var label: String { machServiceName }
    /// LaunchDaemon plist file name (`/Library/LaunchDaemons/<plistName>`).
    public var plistName: String { machServiceName + ".plist" }

    /// Oxine's daemon: `com.oxine.soushelper`, accepting the Oxine app signed by
    /// our own "Oxine" / "Oxine Dev" self-signed code-signing certs.
    public static let oxine = HelperBranding(
        machServiceName: "com.oxine.soushelper",
        logSubsystem: "com.oxine.soushelper",
        clientRequirement: "identifier \"com.oxine.app\" and "
            + "(certificate leaf[subject.CN] = \"Oxine\" or certificate leaf[subject.CN] = \"Oxine Dev\")"
    )

    /// The standalone sous-vide app's daemon: its own launchd label so it can
    /// coexist with Oxine's, accepting the sous-vide app signed by our dev certs.
    public static let sousVide = HelperBranding(
        machServiceName: "com.sousvide.soushelper",
        logSubsystem: "com.sousvide.soushelper",
        clientRequirement: "identifier \"com.sousvide.app\" and "
            + "(certificate leaf[subject.CN] = \"Oxine\" or certificate leaf[subject.CN] = \"Oxine Dev\")"
    )
}

/// What the user wants Sous to do. Sent app → daemon; the daemon is the sole
/// authority on how it's *applied* (and clamps every field — see SafetyFloors).
public struct SousConfig: Codable, Sendable, Equatable {
    /// Master switch. When false the daemon releases all control and the Mac
    /// charges normally (adapter on, charging on).
    public var enabled: Bool
    /// Hold-at level, 50–100 %. The battery pauses charging here.
    public var chargeLimit: Int
    /// Sailing band: charging only resumes once charge drops to
    /// `chargeLimit - sailingRange`, killing micro-charge cycles. 0–15.
    public var sailingRange: Int
    /// One-shot charge to 100 %. The daemon clears it the next time the Mac is
    /// unplugged, reverting to `chargeLimit`.
    public var topUpActive: Bool
    /// User-initiated active discharge down to `chargeLimit` (cuts the adapter so
    /// the battery drains while plugged in). Daemon clears it on reaching the
    /// limit or on unplug.
    public var dischargeActive: Bool
    /// Pause charging when battery temperature crosses `maxTempC` (5-min
    /// hysteresis, applied in the daemon loop).
    public var heatProtectEnabled: Bool
    public var maxTempC: Double
    /// Sync the MagSafe LED to the charge state: green when held at the limit,
    /// amber while charging/discharging toward it. Off hands the LED back to the
    /// system. Only effective on MagSafe-equipped Macs (`SousStatus.canControlLED`).
    public var controlLED: Bool
    /// One-shot battery calibration cycle (charge 100 → drain → recharge 100 →
    /// hold → return to limit). The daemon owns the multi-phase state machine and
    /// clears this flag when the cycle finishes or is cancelled; the charge limit
    /// is ignored for the duration. See `CalibrationPhase`.
    public var calibrationActive: Bool

    public init(enabled: Bool = false,
                chargeLimit: Int = 80,
                sailingRange: Int = 5,
                topUpActive: Bool = false,
                dischargeActive: Bool = false,
                heatProtectEnabled: Bool = false,
                maxTempC: Double = 35,
                controlLED: Bool = false,
                calibrationActive: Bool = false) {
        self.enabled = enabled
        self.chargeLimit = chargeLimit
        self.sailingRange = sailingRange
        self.topUpActive = topUpActive
        self.dischargeActive = dischargeActive
        self.heatProtectEnabled = heatProtectEnabled
        self.maxTempC = maxTempC
        self.controlLED = controlLED
        self.calibrationActive = calibrationActive
    }
}

/// The phases of a battery calibration cycle, in order. Recalibrates the cell's
/// fuel-gauge IC by exercising a full discharge/charge cycle. Mirrors AlDente's
/// calibration sequence. The daemon advances through these on its control loop.
public enum CalibrationPhase: String, Codable, Sendable {
    case idle              // not calibrating
    case chargingToFull    // 1: charge to 100 %
    case dischargingToLow  // 2: drain (adapter cut) to the low target
    case recharging        // 3: charge back to 100 %
    case holdingAtFull     // 4: hold at 100 % for the dwell window
    case restoring         // 5: drain back down to the user's charge limit

    /// Short user-facing description of what's happening in this phase.
    public var label: String {
        switch self {
        case .idle:             return "Idle"
        case .chargingToFull:   return "Charging to 100%"
        case .dischargingToLow: return "Draining to \(SafetyFloors.calibrationLowTarget)%"
        case .recharging:       return "Recharging to 100%"
        case .holdingAtFull:    return "Holding at 100%"
        case .restoring:        return "Returning to limit"
        }
    }

    /// Rough 0–1 progress through the whole cycle, for a progress bar.
    public var fraction: Double {
        switch self {
        case .idle:             return 0
        case .chargingToFull:   return 0.15
        case .dischargingToLow: return 0.4
        case .recharging:       return 0.65
        case .holdingAtFull:    return 0.85
        case .restoring:        return 0.95
        }
    }
}

/// Hard limits the daemon enforces regardless of what the app asks — so a buggy
/// or hostile client can never drive the cell into a damaging state.
public enum SafetyFloors {
    /// Lowest the user may set the hold limit. 20 matches AlDente's floor (batt
    /// allows 10); below this you'd cycle a low cell, which is worse than a high
    /// stable SoC.
    public static let minChargeLimit = 20
    public static let maxChargeLimit = 100
    /// Never actively discharge below this.
    public static let minDischargeFloor = 20
    public static let maxSailingRange = 15

    /// Refuse a heat threshold outside a sane band.
    public static let minTempC = 25.0
    public static let maxTempC = 45.0

    /// Calibration drains to this charge before recharging. Matches AlDente's
    /// 10 % target — low enough to exercise the gauge, above the discharge floor.
    public static let calibrationLowTarget = 10
    /// How long calibration holds at 100 % before returning to the limit (1 h).
    public static let calibrationHoldSeconds: TimeInterval = 3600

    public static func clamp(_ c: SousConfig) -> SousConfig {
        var c = c
        c.chargeLimit = min(max(c.chargeLimit, minChargeLimit), maxChargeLimit)
        // Sailing must never pull the resume point below the discharge floor, and
        // keep at least a 1% band when below 100.
        let maxBand = max(0, min(maxSailingRange, c.chargeLimit - minDischargeFloor))
        c.sailingRange = min(max(c.sailingRange, 0), maxBand)
        c.maxTempC = min(max(c.maxTempC, minTempC), maxTempC)
        return c
    }
}

/// One observable line on what the hardware/daemon is doing right now.
public enum SousState: String, Codable, Sendable {
    case off          // Sous not controlling
    case charging     // climbing toward the limit
    case holding      // paused at the limit
    case sailing      // paused inside the sailing band
    case discharging  // actively draining to the limit (adapter cut)
    case toppingUp    // one-shot charge to 100
    case heatProtect  // charging paused because it's too hot
    case unplugged    // on battery
    case calibrating  // running a calibration cycle (see SousStatus.calibrationPhase)
}

/// Daemon → app snapshot. Encoded as JSON across XPC.
public struct SousStatus: Codable, Sendable, Equatable {
    /// SMC charge-control keys are present on this machine.
    public var capable: Bool
    public var chargeInhibited: Bool
    public var adapterInhibited: Bool
    /// Hardware battery percentage (SMC `BUIC`) — the daemon's source of truth.
    public var hardwareCharge: Int
    public var pluggedIn: Bool
    public var tempC: Double
    public var heatThrottled: Bool
    public var state: SousState
    public var lastError: String?
    /// This Mac exposes the MagSafe/adapter LED control key.
    public var canControlLED: Bool
    /// Which calibration phase the daemon is in (`.idle` when not calibrating).
    public var calibrationPhase: CalibrationPhase
    /// Seconds left in the 100 % hold during `.holdingAtFull`, else nil.
    public var calibrationHoldRemaining: Int?

    public init(capable: Bool = false,
                chargeInhibited: Bool = false,
                adapterInhibited: Bool = false,
                hardwareCharge: Int = 0,
                pluggedIn: Bool = false,
                tempC: Double = 0,
                heatThrottled: Bool = false,
                state: SousState = .off,
                lastError: String? = nil,
                canControlLED: Bool = false,
                calibrationPhase: CalibrationPhase = .idle,
                calibrationHoldRemaining: Int? = nil) {
        self.capable = capable
        self.chargeInhibited = chargeInhibited
        self.adapterInhibited = adapterInhibited
        self.hardwareCharge = hardwareCharge
        self.pluggedIn = pluggedIn
        self.tempC = tempC
        self.heatThrottled = heatThrottled
        self.state = state
        self.lastError = lastError
        self.canControlLED = canControlLED
        self.calibrationPhase = calibrationPhase
        self.calibrationHoldRemaining = calibrationHoldRemaining
    }
}

/// The XPC contract. JSON `Data` carries the Codable payloads so we avoid
/// NSSecureCoding boilerplate for our own value types.
@objc public protocol SousXPCProtocol {
    func applyConfig(_ data: Data, reply: @escaping @Sendable (Bool) -> Void)
    func fetchStatus(reply: @escaping @Sendable (Data?) -> Void)
    func helperVersion(reply: @escaping @Sendable (String) -> Void)
    func uninstall(reply: @escaping @Sendable (Bool) -> Void)
}
