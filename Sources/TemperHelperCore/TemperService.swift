import Foundation
import IOKit
import os
import TemperShared

/// The fan daemon's brain. Owns the SMC connection and a serial maintenance loop
/// that, every tick, decides each fan's target and re-asserts manual control -
/// `thermalmonitord` reclaims the fans every few seconds, so persistent control
/// means continuously re-writing the unlock + mode + target. All state lives on
/// `queue`; the class is `@unchecked Sendable` because every access funnels
/// through it.
final class TemperService: NSObject, TemperXPCProtocol, @unchecked Sendable {
    private let log: Logger
    private let queue: DispatchQueue
    private let smc = TemperSMC()
    private var smcOpen = false

    init(branding: TemperHelperBranding) {
        self.log = Logger(subsystem: branding.logSubsystem, category: "fan")
        self.queue = DispatchQueue(label: branding.logSubsystem + ".fan")
        super.init()
    }

    private var config = TemperConfig()
    private var timer: DispatchSourceTimer?
    private var controlling = false
    private var thermalCutout = false
    private var lastError: String?

    // thermalmonitord reclaims fans every ~250ms–4s; re-assert briskly enough to
    // keep our target in force without hammering the SMC.
    private static let tickInterval: TimeInterval = 2

    func start() {
        queue.async { [self] in
            smcOpen = smc.open()
            if !smcOpen { lastError = "Could not open AppleSMC" }
            log.notice("daemon start: smcOpen=\(self.smcOpen) fans=\(self.smc.fanCount) canControl=\(self.smc.canControlFans) hasFtst=\(self.smc.hasFtst)")
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
            guard let decoded = try? JSONDecoder().decode(TemperConfig.self, from: data) else {
                reply(false); return
            }
            config = TemperSafety.clamp(decoded)
            log.notice("applyConfig: fans=\(self.config.fans.count) controlled=\(self.config.anyControlled)")
            tick()                 // apply immediately, don't wait for the timer
            reply(true)
        }
    }

    func fetchStatus(reply: @escaping @Sendable (Data?) -> Void) {
        queue.async { [self] in
            reply(try? JSONEncoder().encode(snapshot()))
        }
    }

    func helperVersion(reply: @escaping @Sendable (String) -> Void) {
        reply(TemperXPC.helperVersion)
    }

    func uninstall(reply: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            release()                       // hand the fans back to macOS
            controlling = false
            reply(true)
            // Don't exit(0): KeepAlive would respawn us. The app calls the
            // privileged uninstall script, which actually unloads the daemon.
        }
    }

    // MARK: Control loop (always on `queue`)

    /// Hand every fan back to the system's thermal management and drop the unlock.
    private func release() {
        guard smcOpen else { return }
        let n = smc.fanCount
        for i in 0..<max(n, 0) { smc.setFanAuto(i) }
        if smc.hasFtst { smc.setFtst(false) }
        controlling = false
    }

    private func tick() {
        guard smcOpen else { return }
        let n = smc.fanCount
        guard n > 0, smc.canControlFans else { return }   // nothing to drive

        // All fans on Auto → release once, then stay passive.
        guard config.anyControlled else {
            if controlling { release() }
            return
        }

        // Hard safety: if anything is too hot, abandon manual control and let
        // macOS's thermal management take over - no user setting overrides this.
        let hottest = smc.hottestC()
        if hottest >= TemperSafety.thermalCutoutC {
            if !thermalCutout { log.notice("thermal cutout at \(hottest, format: .fixed(precision: 1))°C - releasing fans") }
            thermalCutout = true
            if controlling { release() }
            return
        }
        thermalCutout = false

        // Smart reads the OS's own thermal-pressure signal so it can ramp harder
        // under sustained load even before the SMC temperature climbs.
        let bias = Self.pressureBias()
        let targets = (0..<n).map { config.setting(for: $0)?.resolvedPercent(hottest: hottest, pressureBias: bias) }

        // If NOTHING wants driving this tick (e.g. every fan is Smart and idle, or
        // Default), fully hand back to macOS: drop the unlock and release. With the
        // Ftst unlock still asserted, a fan written to "auto" floors at its minimum
        // instead of being allowed to idle toward 0 - so we must release entirely.
        if targets.allSatisfy({ $0 == nil }) {
            if controlling { release() }
            return
        }

        // At least one fan needs driving - hold the unlock (the daemon reclaims it
        // each tick) and drive each fan to its target; idle fans go back to auto.
        if smc.hasFtst { smc.setFtst(true) }
        for i in 0..<n {
            guard let pct = targets[i] else {
                smc.setFanAuto(i)
                continue
            }
            smc.setFanManual(i)
            let lo = smc.minRPM(i), hi = smc.maxRPM(i)
            guard hi > lo else { continue }
            let rpm = lo + min(max(pct / 100, 0), 1) * (hi - lo)   // 0 % == the fan's safe minimum
            smc.setTargetRPM(i, rpm)
        }
        controlling = true
        lastError = nil
    }

    /// Map macOS's coarse thermal-pressure state to a 0–1 bias for Smart.
    private static func pressureBias() -> Double {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return 0
        case .fair:     return 0.4
        case .serious:  return 0.75
        case .critical: return 1
        @unknown default: return 0
        }
    }

    private func snapshot() -> TemperStatus {
        guard smcOpen else {
            return TemperStatus(lastError: lastError ?? "SMC unavailable")
        }
        let n = smc.fanCount
        let fans = (0..<max(n, 0)).map { i in
            FanInfo(index: i,
                    actualRPM: smc.actualRPM(i),
                    minRPM: smc.minRPM(i),
                    maxRPM: smc.maxRPM(i),
                    targetRPM: smc.targetRPM(i))
        }
        return TemperStatus(
            controllable: smc.canControlFans,
            fanCount: n,
            fans: fans,
            controlling: controlling,
            hottestC: smc.hottestC(),
            thermalCutout: thermalCutout,
            lastError: lastError
        )
    }
}
