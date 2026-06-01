import Foundation
import IOKit
import os
import SousShared

private let log = Logger(subsystem: "com.oxine.soushelper", category: "control")

/// The daemon's brain. Owns the SMC connection and a serial maintenance loop
/// that decides, every tick, whether to inhibit charging and/or the adapter.
/// All state lives on `queue`; the class is `@unchecked Sendable` because every
/// access is funnelled through that queue.
final class SousService: NSObject, SousXPCProtocol, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.oxine.soushelper.control")
    private let smc = SMC()
    private var smcOpen = false

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
            log.notice("applyConfig: enabled=\(self.config.enabled) limit=\(self.config.chargeLimit) sailing=\(self.config.sailingRange) topUp=\(self.config.topUpActive) discharge=\(self.config.dischargeActive)")
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
            reply(true)
            // Don't exit(0): with KeepAlive launchd would just respawn us. The app
            // calls SMAppService.unregister(), which actually unloads the daemon.
        }
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
        guard config.enabled, config.controlLED else { smc.setLED(.auto); return }
        switch currentState {
        case .holding, .sailing:                    smc.setLED(.green)
        case .charging, .toppingUp, .heatProtect:   smc.setLED(.amber)
        case .discharging:                          smc.setLED(.blinkAmber)
        case .off, .unplugged:                      smc.setLED(.auto)
        }
    }

    private func tick() {
        guard smcOpen else { return }
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

        // Master switch off → behave like macOS does by default.
        guard config.enabled else { release(); return }

        // A failed BUIC read must NOT be treated as 0% (which would silently
        // enable charging). Hold the last hardware decision and bail.
        guard charge >= 0 else { lastError = "BUIC read failed"; return }
        lastError = nil

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
            canControlLED: smc.canControlLED
        )
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
