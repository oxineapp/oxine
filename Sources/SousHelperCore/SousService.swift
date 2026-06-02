import Foundation
import IOKit
import os
import SousShared

/// The daemon's brain. Owns the SMC connection and a serial maintenance loop
/// that decides, every tick, whether to inhibit charging and/or the adapter.
/// All state lives on `queue`; the class is `@unchecked Sendable` because every
/// access is funnelled through that queue.
final class SousService: NSObject, SousXPCProtocol, @unchecked Sendable {
    private let log: Logger
    private let queue: DispatchQueue
    private let smc = SMC()
    private var smcOpen = false

    init(branding: HelperBranding) {
        self.log = Logger(subsystem: branding.logSubsystem, category: "control")
        self.queue = DispatchQueue(label: branding.logSubsystem + ".control")
        super.init()
    }

    private var config = SousConfig()          // last config the app pushed
    private var timer: DispatchSourceTimer?

    // Hysteresis / edge state.
    private var lastChargeInhibited = false
    private var wasPluggedIn = false
    private var heatThrottled = false
    private var heatFlip = Date.distantPast    // last throttle on/off transition
    private var lastTickAt = Date.distantPast  // detect starved loops (sleep/wake)
    private var lastError: String?
    private var currentState: SousState = .off

    // Calibration state machine (advanced on `queue` from `tick`).
    private var calibPhase: CalibrationPhase = .idle
    private var calibHoldUntil: Date?

    // Machine-wide control lock. Only ONE Sous daemon (Oxine's or the standalone
    // sous-vide's) may drive the SMC at a time — otherwise they fight over
    // charging + the MagSafe LED (green/amber flicker). A daemon grabs this
    // exclusive flock only while it actually wants control; everyone else stays
    // fully passive (no SMC writes). Shared, brand-neutral path so both brands
    // contend for the same lock.
    private var lockFD: Int32 = -1
    private var ownsControl = false
    private static let lockPath = "/Library/Application Support/Sous/owner.lock"

    private static let tickInterval: TimeInterval = 15
    private static let heatDwell: TimeInterval = 300   // 5-min min dwell each way

    func start() {
        queue.async { [self] in
            smcOpen = smc.open()
            if !smcOpen { lastError = "Could not open AppleSMC" }
            log.notice("daemon start: smcOpen=\(self.smcOpen) canControlCharging=\(self.smc.canControlCharging) canControlAdapter=\(self.smc.canControlAdapter) BUIC=\(self.smc.hardwareCharge)")
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 1, repeating: Self.tickInterval)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    // MARK: XPC

    func applyConfig(_ data: Data, reply: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            guard let decoded = try? JSONDecoder().decode(SousConfig.self, from: data) else {
                reply(false); return
            }
            config = SafetyFloors.clamp(decoded)
            // Cancelled (or never started) → reset the calibration machine so a
            // later re-arm starts cleanly from phase 1.
            if !config.calibrationActive { calibPhase = .idle; calibHoldUntil = nil }
            log.notice("applyConfig: enabled=\(self.config.enabled) limit=\(self.config.chargeLimit) sailing=\(self.config.sailingRange) topUp=\(self.config.topUpActive) discharge=\(self.config.dischargeActive) calibrate=\(self.config.calibrationActive)")
            tick()                 // apply immediately, don't wait for the timer
            reply(true)
        }
    }

    func fetchStatus(reply: @escaping @Sendable (Data?) -> Void) {
        queue.async { [self] in
            let status = snapshot()
            reply(try? JSONEncoder().encode(status))
        }
    }

    func helperVersion(reply: @escaping @Sendable (String) -> Void) {
        reply(SousXPC.helperVersion)
    }

    func uninstall(reply: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            release()                       // hand charging control back to macOS
            releaseOwnership()              // and let another daemon take over
            ownsControl = false
            reply(true)
            // Don't exit(0): with KeepAlive launchd would just respawn us. The app
            // calls SMAppService.unregister(), which actually unloads the daemon.
        }
    }

    // MARK: Control lock (machine-wide, shared across brands)

    /// True if we hold (or just acquired) the exclusive control lock. Opens the
    /// shared lock file lazily and keeps the fd for the daemon's lifetime; the
    /// flock is released on `releaseOwnership()` or when the process exits.
    private func acquireOwnership() -> Bool {
        if lockFD < 0 {
            try? FileManager.default.createDirectory(
                atPath: (Self.lockPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            lockFD = open(Self.lockPath, O_RDONLY | O_CREAT, 0o644)
            if lockFD < 0 { return true }   // fail-open: never brick control over a lock-file error
        }
        return flock(lockFD, LOCK_EX | LOCK_NB) == 0   // idempotent re-lock if we already hold it
    }

    private func releaseOwnership() {
        guard lockFD >= 0 else { return }
        flock(lockFD, LOCK_UN)
    }

    // MARK: Control loop (always on `queue`)

    private func release() {
        guard smcOpen else { return }
        smc.setChargingEnabled(true)
        smc.setAdapterEnabled(true)
        smc.setLED(.auto)              // hand the LED back to the system
        lastChargeInhibited = false
        currentState = .off
    }

    /// Drive the MagSafe LED from the current state when the user opted in:
    /// green = held at the limit (or topped to 100), amber = working toward it.
    private func applyLED() {
        guard smcOpen, smc.canControlLED else { return }
        guard config.enabled || config.calibrationActive, config.controlLED else { smc.setLED(.auto); return }
        switch currentState {
        case .holding, .sailing:                    smc.setLED(.green)
        case .charging, .toppingUp, .heatProtect:   smc.setLED(.amber)
        case .discharging, .calibrating:            smc.setLED(.blinkAmber)
        case .off, .unplugged:                      smc.setLED(.auto)
        }
    }

    private func tick() {
        guard smcOpen else { return }

        // Contend for the machine-wide control lock. Grab it only while we
        // actually want control; when idle, drop it so the other app's daemon
        // can take over cleanly (the charge-limit handoff).
        let wantsControl = config.enabled || config.calibrationActive
        if !wantsControl {
            if ownsControl { release(); ownsControl = false }   // hand back to macOS, once
            releaseOwnership()
            return                                              // then stop touching the SMC
        }
        guard acquireOwnership() else {
            // Another Sous daemon owns the battery — stay fully passive (no SMC
            // writes at all) so we never fight it over charging or the LED.
            ownsControl = false
            currentState = .off
            return
        }
        ownsControl = true

        defer { applyLED() }           // reflect whatever state this tick settled on
        let now = Date()
        // If the timer was starved (sleep/wake, throttling), we can't trust that
        // charging stayed supervised. batt does the same: don't *resume* charging
        // until a healthy tick, so we never charge unsupervised past the limit.
        let starved = now.timeIntervalSince(lastTickAt) > Self.tickInterval * 2.5
        defer { lastTickAt = now }

        let charge = smc.hardwareCharge          // BUIC, the daemon's own truth
        let plugged = smc.isPluggedIn
        let temp = Self.batteryTempC()
        let wasPlugged = wasPluggedIn
        defer { wasPluggedIn = plugged }

        // A failed BUIC read must NOT be treated as 0% (which would silently
        // enable charging). Hold the last hardware decision and bail. Checked
        // before the enabled gate so calibration is just as protected.
        guard charge >= 0 else { lastError = "BUIC read failed"; return }
        lastError = nil

        // Calibration supersedes every normal mode (and the master switch): it's a
        // deliberate one-shot maintenance cycle that ignores the charge limit.
        if config.calibrationActive { runCalibration(charge: charge, plugged: plugged); return }

        // Master switch off → behave like macOS does by default.
        guard config.enabled else { release(); return }

        // Clear one-shots on the unplug edge.
        if wasPlugged && !plugged {
            config.topUpActive = false
            config.dischargeActive = false
        }

        let limit = config.topUpActive ? 100 : config.chargeLimit

        // ── Active discharge: cut the adapter so the cell drains to the limit ──
        if config.dischargeActive, plugged,
           charge > limit, charge > SafetyFloors.minDischargeFloor {
            smc.setAdapterEnabled(false)
            smc.setChargingEnabled(false)
            lastChargeInhibited = true
            currentState = .discharging
            return
        }
        // Discharge finished (reached limit / floor) → resume normal adapter.
        if config.dischargeActive { config.dischargeActive = false }
        smc.setAdapterEnabled(true)

        guard plugged else {
            // On battery there's nothing to inhibit; keep charging enabled so a
            // re-plug behaves predictably.
            smc.setChargingEnabled(true)
            lastChargeInhibited = false
            currentState = .unplugged
            return
        }

        // Heat protection gates charging regardless of the limit.
        if heatGate(temp) {
            smc.setChargingEnabled(false)
            lastChargeInhibited = true
            currentState = .heatProtect
            return
        }

        // Top Up (limit 100): just charge to full, never hold.
        if limit >= 100 {
            smc.setChargingEnabled(true)
            lastChargeInhibited = false
            currentState = charge >= 100 ? .holding : .toppingUp
            return
        }

        // ── Charge-limit hold with sailing band ───────────────────────────────
        let lower = max(limit - config.sailingRange, SafetyFloors.minDischargeFloor)
        var inhibit = lastChargeInhibited
        if charge >= limit {
            inhibit = true
        } else if charge <= lower {
            // Only resume on a healthy (non-starved) tick — see `starved` above.
            inhibit = starved ? true : false
        }
        // else: inside the band → keep the previous decision (no micro-cycling).

        smc.setChargingEnabled(!inhibit)
        lastChargeInhibited = inhibit
        currentState = inhibit ? (charge >= limit ? .holding : .sailing) : .charging
        log.notice("hold: charge=\(charge) limit=\(limit) lower=\(lower) inhibit=\(inhibit) chargingEnabled=\(self.smc.isChargingEnabled)")
    }

    /// Battery calibration cycle: charge to 100 → drain to the low target →
    /// recharge to 100 → hold at 100 for the dwell → drain back to the user's
    /// limit. Recalibrates the cell's fuel gauge. The limit is ignored throughout;
    /// the loop advances one phase per healthy tick. Always on `queue`.
    private func runCalibration(charge: Int, plugged: Bool) {
        currentState = .calibrating
        if calibPhase == .idle { calibPhase = .chargingToFull; log.notice("calibration start at \(charge)%") }

        switch calibPhase {
        case .idle:
            break

        case .chargingToFull:
            smc.setAdapterEnabled(true)
            smc.setChargingEnabled(true)
            lastChargeInhibited = false
            if charge >= 100 { advanceCalibration(to: .dischargingToLow) }

        case .dischargingToLow:
            if charge <= SafetyFloors.calibrationLowTarget {
                smc.setAdapterEnabled(true)
                advanceCalibration(to: .recharging)
            } else {
                // Cut the adapter so the cell drains even while plugged in.
                smc.setAdapterEnabled(false)
                smc.setChargingEnabled(false)
                lastChargeInhibited = true
            }

        case .recharging:
            smc.setAdapterEnabled(true)
            smc.setChargingEnabled(true)
            lastChargeInhibited = false
            if charge >= 100 {
                calibHoldUntil = Date().addingTimeInterval(SafetyFloors.calibrationHoldSeconds)
                advanceCalibration(to: .holdingAtFull)
            }

        case .holdingAtFull:
            smc.setAdapterEnabled(true)
            smc.setChargingEnabled(true)       // top off / hold at 100
            lastChargeInhibited = false
            if charge < 99 {
                // Lost full (typically the charger was pulled) → recharge first.
                calibHoldUntil = nil
                advanceCalibration(to: .recharging)
            } else if let until = calibHoldUntil, Date() >= until {
                advanceCalibration(to: .restoring)
            }

        case .restoring:
            if charge <= config.chargeLimit {
                finishCalibration()
            } else if plugged {
                // Drain back down to the user's normal limit before handing back.
                smc.setAdapterEnabled(false)
                smc.setChargingEnabled(false)
                lastChargeInhibited = true
            }
            // If unplugged it drains on its own; just wait for the limit.
        }
    }

    private func advanceCalibration(to phase: CalibrationPhase) {
        calibPhase = phase
        log.notice("calibration phase -> \(phase.rawValue)")
    }

    private func finishCalibration() {
        log.notice("calibration finished")
        config.calibrationActive = false
        calibPhase = .idle
        calibHoldUntil = nil
        smc.setAdapterEnabled(true)
        // Normal hold/limit behaviour resumes on the next tick.
    }

    /// Heat-protection state with a 5-minute minimum dwell each way, so charging
    /// doesn't flap around the threshold. Returns true while throttled.
    private func heatGate(_ temp: Double) -> Bool {
        guard config.heatProtectEnabled, temp > 0 else { heatThrottled = false; return false }
        let now = Date()
        if heatThrottled {
            if temp < config.maxTempC, now.timeIntervalSince(heatFlip) >= Self.heatDwell {
                heatThrottled = false; heatFlip = now
            }
        } else if temp >= config.maxTempC, now.timeIntervalSince(heatFlip) >= Self.heatDwell {
            heatThrottled = true; heatFlip = now
        }
        return heatThrottled
    }

    private func snapshot() -> SousStatus {
        guard smcOpen else {
            return SousStatus(capable: false, lastError: lastError ?? "SMC unavailable")
        }
        return SousStatus(
            capable: smc.canControlCharging,
            chargeInhibited: !smc.isChargingEnabled,
            adapterInhibited: !smc.isAdapterEnabled,
            hardwareCharge: smc.hardwareCharge,
            pluggedIn: smc.isPluggedIn,
            tempC: Self.batteryTempC(),
            heatThrottled: heatThrottled,
            state: currentState,
            lastError: lastError,
            canControlLED: smc.canControlLED,
            calibrationPhase: calibPhase,
            calibrationHoldRemaining: calibrationHoldRemaining()
        )
    }

    /// Whole seconds left in the calibration 100 % hold, or nil outside that phase.
    private func calibrationHoldRemaining() -> Int? {
        guard calibPhase == .holdingAtFull, let until = calibHoldUntil else { return nil }
        return max(0, Int(until.timeIntervalSinceNow.rounded()))
    }

    /// Battery temperature in °C from the AppleSmartBattery IORegistry node
    /// (centi-°C). No SMC/root needed for the read; the daemon happens to run as
    /// root but this works regardless.
    private static func batteryTempC() -> Double {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return 0 }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return 0 }
        if let t = dict["Temperature"] as? Int { return Double(t) / 100.0 }
        return 0
    }
}
