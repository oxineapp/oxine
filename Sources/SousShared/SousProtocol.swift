import Foundation

/// Types and identifiers shared verbatim between the Oxine app and the
/// privileged `Sous` daemon. Kept dependency-free so both sides can link it.
public enum SousXPC {
    /// launchd label + Mach service the daemon advertises and the app looks up.
    public static let machServiceName = "com.oxine.soushelper"
    public static let helperLabel = "com.oxine.soushelper"
    /// LaunchDaemon plist bundled at Contents/Library/LaunchDaemons/<plistName>.
    public static let plistName = "com.oxine.soushelper.plist"
    /// Bumped whenever the daemon binary changes so the app can detect a stale
    /// installed helper and re-register.
    public static let helperVersion = "4"
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

    public init(enabled: Bool = false,
                chargeLimit: Int = 80,
                sailingRange: Int = 5,
                topUpActive: Bool = false,
                dischargeActive: Bool = false,
                heatProtectEnabled: Bool = false,
                maxTempC: Double = 35,
                controlLED: Bool = false) {
        self.enabled = enabled
        self.chargeLimit = chargeLimit
        self.sailingRange = sailingRange
        self.topUpActive = topUpActive
        self.dischargeActive = dischargeActive
        self.heatProtectEnabled = heatProtectEnabled
        self.maxTempC = maxTempC
        self.controlLED = controlLED
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

    public init(capable: Bool = false,
                chargeInhibited: Bool = false,
                adapterInhibited: Bool = false,
                hardwareCharge: Int = 0,
                pluggedIn: Bool = false,
                tempC: Double = 0,
                heatThrottled: Bool = false,
                state: SousState = .off,
                lastError: String? = nil,
                canControlLED: Bool = false) {
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
