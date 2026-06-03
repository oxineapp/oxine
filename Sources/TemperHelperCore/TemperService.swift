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
    /// Monotonic time the raw die first crossed the cutout (nil = currently below).
    /// The emergency engages only once it's been hot this long, continuously.
    private var hotSince: Double?
    private var lastError: String?

    /// The stateful Smart controller: smoothing, anticipation, slew, dead-band,
    /// learned idle-floor. Only used for fans in Smart mode.
    private let smart = SmartController()

    // thermalmonitord reclaims fans every ~250ms–4s; re-assert briskly enough to
    // keep our target in force without hammering the SMC. Faster while we're
    // actually driving fans (responsive + clean derivative), slow when there's
    // nothing to control (idle-friendly wakeups).
    private static let fastTick: TimeInterval = 1
    private static let slowTick: TimeInterval = 3
    private var currentInterval: TimeInterval = 1

    func start() {
        queue.async { [self] in
            smcOpen = smc.open()
            if !smcOpen { lastError = "Could not open AppleSMC" }
            log.notice("daemon start: smcOpen=\(self.smcOpen) fans=\(self.smc.fanCount) canControl=\(self.smc.canControlFans) hasFtst=\(self.smc.hasFtst)")
            let t = DispatchSource.makeTimerSource(queue: queue)
            currentInterval = Self.fastTick
            t.schedule(deadline: .now() + 1, repeating: currentInterval)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
            ensureTickRate()
        }
    }

    /// Speed the loop up while we're driving fans, slow it down when passive.
    /// Called whenever the controlled-ness of the config might have changed.
    private func ensureTickRate() {
        let want = config.anyControlled ? Self.fastTick : Self.slowTick
        guard want != currentInterval, let timer else { return }
        currentInterval = want
        timer.schedule(deadline: .now() + want, repeating: want)
    }

    private static func monoNow() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    // MARK: XPC

    func applyConfig(_ data: Data, reply: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            guard let decoded = try? JSONDecoder().decode(TemperConfig.self, from: data) else {
                reply(false); return
            }
            config = TemperSafety.clamp(decoded)
            log.notice("applyConfig: fans=\(self.config.fans.count) controlled=\(self.config.anyControlled) temperament=\(self.config.temperament, format: .fixed(precision: 2))")
            ensureTickRate()
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

    /// Emergency: drive every fan to its maximum rpm (the safe action when too
    /// hot - maximum airflow can never overheat anything, and macOS still throttles
    /// the SoC on top of it). Holds our unlock so the targets stick.
    private func forceMaxCooling(_ n: Int) {
        guard smcOpen else { return }
        if smc.hasFtst { smc.setFtst(true) }
        for i in 0..<max(n, 0) {
            smc.setFanManual(i)
            let hi = smc.maxRPM(i)
            if hi > 0 { smc.setTargetRPM(i, hi) }
        }
        controlling = true
        smart.reset()                  // don't let Smart resume from a stale output
    }

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

        // Hard safety: force EVERY fan to maximum once the raw die has been at/above
        // the cutout *continuously for a few seconds* - no user setting overrides
        // this. The sustain requirement keeps a brief spike (or a glitchy single
        // read) from tripping the emergency, in the same spirit as the rest of
        // Smart: react to lasting heat, not transients. (We force max rather than
        // release to macOS: throttling is the SoC's job and happens regardless of
        // who drives the fans, so handing them back only drops airflow when it's
        // needed most.) Once engaged, hold until it cools well below the cutout.
        let temps = smc.temperatures()                      // one SMC sweep, reused below
        let hottest = temps.map(\.celsius).max() ?? 0
        let bias = Self.pressureBias()
        let now = Self.monoNow()

        if hottest >= TemperSafety.thermalCutoutC {
            if hotSince == nil { hotSince = now }
        } else {
            hotSince = nil
        }
        let sustainedHot = hotSince.map { now - $0 >= TemperSafety.thermalCutoutSustainS } ?? false
        if sustainedHot ||
           (thermalCutout && hottest >= TemperSafety.thermalCutoutC - TemperSafety.cutoutHysteresisC) {
            if !thermalCutout { log.notice("thermal cutout: \(hottest, format: .fixed(precision: 1))°C sustained - forcing fans to maximum") }
            thermalCutout = true
            forceMaxCooling(n)
            return
        }
        thermalCutout = false

        // Smart reads the OS's own thermal-pressure signal so it can ramp harder
        // under sustained load even before the SMC temperature climbs. The
        // controller smooths/anticipates/shapes over time; Manual & Curve are
        // direct maps on the live (raw) hottest reading.
        // Fans' current actual speed (0–1), for the controller's plant learning.
        let fanFraction = (0..<n).map { i -> Double in
            let lo = smc.minRPM(i), hi = smc.maxRPM(i)
            return hi > lo ? min(max((smc.actualRPM(i) - lo) / (hi - lo), 0), 1) : 0
        }.max() ?? 0
        smart.sample(sensors: temps.map { ($0.label, $0.celsius) },
                     power: smc.loadPowerW(), ambient: smc.ambientC(),
                     fanFraction: fanFraction, bias: bias, now: now)
        let targets: [Double?] = (0..<n).map { i in
            guard let setting = config.setting(for: i) else { return nil }
            switch setting.mode {
            case .smart:
                return smart.output(fan: i, bias: bias, temperament: config.temperament, now: now)
            default:
                return setting.resolvedPercent(hottest: hottest, pressureBias: bias, temperament: config.temperament)
            }
        }

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
        // Only surface Smart's reasoning while a fan is actually on Smart, so the
        // verbose diagram never shows a stale snapshot from a since-changed mode.
        let anySmart = config.fans.contains { $0.mode == .smart }
        return TemperStatus(
            controllable: smc.canControlFans,
            fanCount: n,
            fans: fans,
            controlling: controlling,
            hottestC: smc.hottestC(),
            thermalCutout: thermalCutout,
            lastError: lastError,
            smartDebug: anySmart ? smart.lastDebug : nil
        )
    }
}
