import Foundation
import TemperShared

/// The stateful half of Smart, daemon-side. It turns the whole sensor array -
/// temperatures, power, ambient, heatpipe - into one shaped fan command, using an
/// energy-balance view of the machine rather than just reacting to a number.
///
/// Layers (cheap → deep):
///   • Effective temperature from the die at two time constants (fast spike / slow
///     sustained) plus inertia-weighted accumulation across all sensors, so a brief
///     spike is bet to pass while lasting heat commits to cooling.
///   • Power feedforward: heat *leads* the die temperature, so a jump in heatpipe
///     power (`PHPC`) pre-spins the fan before the die even moves. `PHPC` measures
///     the heat actually reaching the cooling path, so it's inherently
///     transport-aware - it only rises when airflow can help (the heatpipe
///     *temperature* `TCHP` barely moves on Apple Silicon, so gating on that did
///     nothing). Falls back to system power `PSTR` where `PHPC` is absent. Cool
///     reacts to instantaneous power, Silent only to sustained power.
///   • Ambient normalisation: the setpoint relaxes in a hot room, tightens in a
///     cold one (in `TemperSmart.feedback`).
///   • Learned plant model: from (rpm, power, die−ambient) at steady state it
///     learns this machine's cooling coefficient k(rpm), then suggests the rpm that
///     should hold the setpoint for the current power. Used only to *raise* toward
///     a learned floor - feedback stays the safety floor, and the raw-die cutout
///     above this always wins.
///
/// Plus asymmetric (temperament-scaled) slew, a dead-band, and graceful spin-down.
/// State is touched only from the daemon's serial queue; no locking.
final class SmartController {
    // MARK: Tunables
    private let fastTau = 8.0, slowTau = 45.0          // s — die fast/slow EWMA
    private let powerFastTau = 4.0, powerSlowTau = 30.0 // s — power leads temp, so smooth less
    private let ambientTau = 30.0
    private let slewUpPerSec = 25.0, slewDownPerSec = 6.0
    private let deadband = 4.0
    private let accumulationWeight = 1.2, accumulationCap = 16.0
    private let idleFloorMin = 35.0, idleFloorMax = 70.0

    // MARK: Per-sensor model
    private struct SensorState { var ewma: Double; var baseline: Double; var vol: Double }
    private var sensors: [String: SensorState] = [:]
    private(set) var accumulation = 0.0

    // MARK: Die + power + ambient + heatpipe signals
    private var fast: Double?, slow: Double?
    private var powerFast = 0.0, powerSlow = 0.0, powerBaseline = 5.0
    private var ambient = 25.0
    private var lastTime: Double?
    private var tickDt = 1.0
    private(set) var risePerSec = 0.0
    private(set) var idleFloor = 50.0

    // MARK: Learned plant model — cooling coefficient k = P/(Tdie−Tamb) per rpm bin
    private var kBins = [Double](repeating: 0, count: 6)
    private var kCount = [Int](repeating: 0, count: 6)

    // MARK: Per-fan output state
    private struct FanState { var output = 0.0; var driving = false }
    private var fans: [Int: FanState] = [:]

    /// Update the whole model once per tick, before resolving any fan.
    /// `fanFraction` is the fans' current actual speed (0–1), for plant learning.
    func sample(sensors readings: [(id: String, celsius: Double)],
                power: Double, ambient ambientNow: Double,
                fanFraction: Double, bias: Double, now: Double) {
        tickDt = lastTime.map { max(now - $0, 1e-3) } ?? 1.0
        lastTime = now
        let calm = bias < 0.2
        let aFast = 1 - exp(-tickDt / fastTau)

        // --- temperatures: per-sensor model → control die + accumulation ---
        // Smart steers on the CPU die *average* (TemperSensors.smartControlKey), a
        // calmer, representative signal — not the hottest core, which spikes and
        // over-cools. We still track the hottest across all sensors as a fallback
        // (Macs without the die-avg key) and keep accumulation aggregate so lasting
        // heat anywhere still lifts demand.
        var hottest = 0.0, accNum = 0.0, accDen = 0.0
        var controlEwma: Double?
        for (id, c) in readings where c > 0 {
            var s = sensors[id] ?? SensorState(ewma: c, baseline: c, vol: 0)
            let prev = s.ewma
            s.ewma = prev + aFast * (c - prev)
            let inst = abs(s.ewma - prev) / tickDt
            s.vol += 0.1 * (inst - s.vol)
            if calm, inst < 0.2 { s.baseline += 0.01 * (s.ewma - s.baseline) }
            sensors[id] = s
            hottest = max(hottest, s.ewma)
            if id == TemperSensors.smartControlKey { controlEwma = s.ewma }
            let excess = max(0, s.ewma - s.baseline)
            let inertia = 1.0 / (s.vol + 0.05)
            accNum += excess * inertia; accDen += inertia
        }
        accumulation = accDen > 0 ? accNum / accDen : 0
        let die = controlEwma ?? hottest

        if let f = fast {
            risePerSec = (die - f) / tickDt
            fast = die
            slow = (slow ?? f) + (1 - exp(-tickDt / slowTau)) * (die - (slow ?? f))
        } else { fast = die; slow = die; risePerSec = 0 }

        // --- power (leading signal) ---
        if power > 0 {
            powerFast += (1 - exp(-tickDt / powerFastTau)) * (power - powerFast)
            powerSlow += (1 - exp(-tickDt / powerSlowTau)) * (power - powerSlow)
        }
        // --- ambient ---
        if ambientNow > 0 { ambient += (1 - exp(-tickDt / ambientTau)) * (ambientNow - ambient) }

        // --- learn idle baselines + the plant model, only when calm & steady ---
        if calm, abs(risePerSec) < 0.2 {
            if let f = fast { idleFloor += 0.01 * (f - idleFloor); idleFloor = min(max(idleFloor, idleFloorMin), idleFloorMax) }
            if power > 0 { powerBaseline += 0.01 * (powerFast - powerBaseline); powerBaseline = max(2, powerBaseline) }
            learnPlant(fanFraction: fanFraction, power: powerFast, die: fast ?? 0)
        }
    }

    /// Learn cooling coefficient k = P / (Tdie − Tamb) at the current fan speed.
    private func learnPlant(fanFraction: Double, power: Double, die: Double) {
        let dT = die - ambient
        guard power > 3, dT > 3, fanFraction >= 0 else { return }
        let k = power / dT
        let bin = min(max(Int(fanFraction * Double(kBins.count - 1) + 0.5), 0), kBins.count - 1)
        kBins[bin] = kCount[bin] == 0 ? k : kBins[bin] + 0.05 * (k - kBins[bin])
        kCount[bin] += 1
    }

    /// Smallest rpm fraction (×100) whose learned k can hold `setpoint` at `power`,
    /// or nil if we haven't learned enough yet.
    private func plantSuggestion(setpoint: Double, power: Double) -> Double? {
        let dTtarget = setpoint - ambient
        guard dTtarget > 2, power > 3, kCount.contains(where: { $0 > 3 }) else { return nil }
        let kNeeded = power / dTtarget
        for b in 0..<kBins.count where kCount[b] > 3 && kBins[b] >= kNeeded {
            return Double(b) / Double(kBins.count - 1) * 100
        }
        return 100   // even the fastest learned speed can't hold it → full tilt
    }

    /// The shaped fan percentage for a Smart fan this tick, or nil to release it.
    func output(fan i: Int, bias: Double, temperament t: Double, now: Double) -> Double? {
        guard let fast, let slow else { return nil }
        let t01 = min(max(t, 0), 1)
        var st = fans[i] ?? FanState()

        // Effective control temperature: Silent leans on slow + accumulation, Cool
        // on fast. Accumulation lift commits Silent once heat is genuinely lasting.
        var controlTemp = slow + (fast - slow) * t01
        controlTemp += min(accumulation * accumulationWeight, accumulationCap)

        // Ambient-adjusted feedback (the reactive floor).
        let setpoint = TemperSmart.targetTempC(temperament: t01) + min(max(ambient - 25, -8), 12) * 0.6
        let fb = TemperSmart.feedback(tempC: controlTemp, risingCPerSec: risePerSec,
                                      pressureBias: bias, temperament: t01, ambientC: ambient)

        // Power feedforward on transported heat (PHPC): react to load at the source,
        // before the die heats. Cool uses instantaneous power, Silent only sustained.
        let powerBlend = powerSlow + (powerFast - powerSlow) * t01
        let powerExcess = max(0, powerBlend - powerBaseline)
        let ff = powerExcess * (1.0 + t01 * 3.5)

        // Learned plant model: a physics-based floor on the steady rpm needed to
        // *hold* the setpoint - but only as the die actually approaches it. Far
        // below setpoint (idle, or any cool die under a Cool setpoint it can never
        // reach) the steady-state floor is meaningless and must not spin the fan up;
        // it phases in across the same band feedback uses, so it refines an
        // already-rising demand rather than flooring a cool machine at the lowest
        // *learned* rpm bin (which is never idle-low, since fans seldom run that slow).
        var demand = fb + ff
        var plantFloor = -1.0
        if let m = plantSuggestion(setpoint: setpoint, power: powerFast) {
            let band = 20 - t01 * 6
            let proximity = min(max((controlTemp - (setpoint - band)) / band, 0), 1)
            plantFloor = m * proximity
            demand = max(demand, plantFloor)
        }
        demand = min(demand, 100)

        // Hands-off when cool, calm, no load, and not rising (learned-floor gated).
        let wantsOff = demand < 1 && controlTemp < idleFloor + 3 && bias < 0.25
            && risePerSec < 0.3 && powerExcess < 3
        let target = wantsOff ? 0 : demand

        // Snapshot this tick's reasoning for the verbose diagram (output filled in
        // at each exit). Cheap; only the app reads it, and only when asked.
        func record(_ outputPct: Double) {
            lastDebug = SmartDebug(temperament: t01, controlTempC: controlTemp, setpointC: setpoint,
                                   feedback: fb, feedforward: min(ff, 100), plantFloor: plantFloor,
                                   demand: demand, output: outputPct, accumulation: accumulation,
                                   risePerSec: risePerSec, powerW: powerFast, powerBaselineW: powerBaseline,
                                   ambientC: ambient, idleFloorC: idleFloor, handsOff: wantsOff)
        }

        if st.driving, !wantsOff, abs(target - st.output) < deadband {
            record(st.output); fans[i] = st; return st.output
        }
        let upRate = slewUpPerSec * (0.3 + 0.7 * t01)
        if target > st.output { st.output = min(target, st.output + upRate * tickDt) }
        else { st.output = max(target, st.output - slewDownPerSec * tickDt) }

        if wantsOff, st.output <= 1.0 { st.output = 0; st.driving = false; record(-1); fans[i] = st; return nil }
        st.driving = st.output > 0
        fans[i] = st
        record(st.driving ? st.output : -1)
        return st.driving ? st.output : nil
    }

    /// Last tick's Smart reasoning (most recently resolved Smart fan), for the
    /// verbose diagram. Reset to nil when Smart isn't driving anything.
    private(set) var lastDebug: SmartDebug?

    func reset() { fans.removeAll(); lastDebug = nil }
}
