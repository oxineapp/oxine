import Foundation
import IOKit
import IOKit.ps

/// A read-only snapshot of the battery's electrical state, gathered without any
/// privileges from `IOPowerSources` (the macOS-shown %, AC state) and the
/// `AppleSmartBattery` IORegistry node (voltage/current/temperature and, on
/// Apple Silicon, the `PowerTelemetryData` that drives Power Flow).
struct BatteryMetrics: Sendable, Equatable {
    var hasBattery = false
    var macOSPercent = -1
    var externalConnected = false
    var isCharging = false
    var fullyCharged = false
    var tempC: Double = 0
    var voltageV: Double = 0
    var amperageA: Double = 0          // signed: positive = into the battery
    var batteryPowerW: Double = 0      // signed: positive = charging the battery
    var adapterMaxWatts: Double = 0    // rated ceiling from AdapterDetails
    var adapterInputW: Double?         // instantaneous draw from the wall
    var systemLoadW: Double?           // instantaneous Mac consumption
    var adapterDescription: String?
    var currentCapacitymAh: Double = 0 // charge left in the cell (AppleRawCurrentCapacity)
    var maxCapacitymAh: Double = 0     // full-charge capacity now (AppleRawMaxCapacity)
    var designCapacitymAh: Double = 0  // factory capacity (DesignCapacity)
    var cycleCount = 0
    // Detailed hardware readout (Stats widget).
    var batterySerial: String?
    var lowPowerMode = false
    var adapterName: String?
    var adapterManufacturer: String?
    var adapterSerial: String?
    var adapterVoltageV: Double = 0    // wall-side voltage (AdapterDetails)
    var adapterCurrentA: Double = 0    // wall-side current (AdapterDetails)

    /// True once we've successfully read a battery (used to gate the UI between
    /// "no battery / desktop Mac" and live data).
    var isValid: Bool { hasBattery }

    // MARK: Calculated battery-life detail

    /// Energy currently in the cell, in watt-hours (capacity × pack voltage).
    var energyNowWh: Double { currentCapacitymAh / 1000 * voltageV }
    /// Energy at a full charge, in watt-hours.
    var energyFullWh: Double { maxCapacitymAh / 1000 * voltageV }

    /// State-of-health: full-charge capacity as a fraction of the design
    /// capacity, 0–1. Nil when we don't have both numbers.
    var healthFraction: Double? {
        guard maxCapacitymAh > 0, designCapacitymAh > 0 else { return nil }
        return min(maxCapacitymAh / designCapacitymAh, 1)
    }

    /// Estimated seconds of runtime left on battery, from live power draw. Nil
    /// when plugged in or the draw is too small/noisy to project.
    var secondsToEmpty: Double? {
        guard !externalConnected, voltageV > 0, energyNowWh > 0 else { return nil }
        let drawW = abs(batteryPowerW)
        guard drawW > 0.5 else { return nil }
        return energyNowWh / drawW * 3600
    }

    /// Estimated seconds until the cell is full while charging, from live power.
    /// Nil when not actively charging or the inflow is negligible.
    var secondsToFull: Double? {
        guard externalConnected, isCharging, voltageV > 0, energyFullWh > energyNowWh else { return nil }
        let inW = batteryPowerW
        guard inW > 0.5 else { return nil }
        return (energyFullWh - energyNowWh) / inW * 3600
    }
}

enum BatteryReader {
    /// Apple Silicon check that survives a universal binary running on Intel.
    static let isAppleSilicon: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let ok = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0
        return ok && value == 1
    }()

    static func read() -> BatteryMetrics {
        var m = BatteryMetrics()
        readPowerSources(into: &m)
        readSmartBattery(into: &m)
        readSMCPower(into: &m)      // real-time power overlay (sub-second)
        return m
    }

    /// Overlay live wattages from SMC. `AppleSmartBattery`'s electrical fields
    /// only refresh ~1×/min, so the Power Flow would look frozen using them;
    /// `PDTR`/`PPBR`/`PSTR` update sub-second. Direction comes from IORegistry
    /// (`isCharging`), which doesn't flip faster than that anyway.
    private static func readSMCPower(into m: inout BatteryMetrics) {
        // Verified on-device: PDTR = adapter input power, PSTR = system (Mac)
        // power. Conservation gives the battery flow: PDTR − PSTR is positive
        // into the battery (charging) and negative when the battery assists.
        let smc = AppSMC.shared
        let adapter = smc.adapterPowerW()    // PDTR
        let sysPower = smc.systemPowerW()     // PSTR

        if let adapter { m.adapterInputW = adapter }
        if let sysPower { m.systemLoadW = sysPower }
        if let adapter, let sysPower {
            m.batteryPowerW = adapter - sysPower
        } else if let battMag = smc.batteryPowerW() {
            m.batteryPowerW = m.isCharging ? battMag : -battMag
        }
    }

    private static func readPowerSources(into m: inout BatteryMetrics) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return }
        for src in list {
            guard let d = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            guard (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            m.hasBattery = true
            if let p = d[kIOPSCurrentCapacityKey] as? Int { m.macOSPercent = p }
            if let s = d[kIOPSPowerSourceStateKey] as? String { m.externalConnected = (s == kIOPSACPowerValue) }
            if let c = d[kIOPSIsChargingKey] as? Bool { m.isCharging = c }
            if let f = d[kIOPSIsChargedKey] as? Bool { m.fullyCharged = f }
        }
    }

    private static func readSmartBattery(into m: inout BatteryMetrics) {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return }
        defer { IOObjectRelease(svc) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &unmanaged, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let d = unmanaged?.takeRetainedValue() as? [String: Any] else { return }

        m.hasBattery = true
        if let t = d["Temperature"] as? Int { m.tempC = Double(t) / 100.0 }
        if let v = d["Voltage"] as? Int { m.voltageV = Double(v) / 1000.0 }
        // InstantAmperage is signed (two's complement, mA); prefer it over the
        // averaged Amperage for a live reading.
        let amp = (d["InstantAmperage"] as? Int) ?? (d["Amperage"] as? Int)
        if let amp { m.amperageA = Double(amp) / 1000.0 }
        m.batteryPowerW = m.voltageV * m.amperageA

        // Capacity figures drive the calculated runtime + health detail. The
        // `AppleRaw*` keys are the true mAh values on Apple Silicon (plain
        // CurrentCapacity/MaxCapacity report a 0–100 percentage there).
        if let cur = (d["AppleRawCurrentCapacity"] as? Int) ?? (d["CurrentCapacity"] as? Int) {
            m.currentCapacitymAh = Double(cur)
        }
        if let mx = (d["AppleRawMaxCapacity"] as? Int) ?? (d["MaxCapacity"] as? Int) {
            m.maxCapacitymAh = Double(mx)
        }
        if let dc = d["DesignCapacity"] as? Int { m.designCapacitymAh = Double(dc) }
        if let cc = d["CycleCount"] as? Int { m.cycleCount = cc }
        m.batterySerial = d["Serial"] as? String
        m.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        if let adapter = d["AdapterDetails"] as? [String: Any] {
            if let w = adapter["Watts"] as? Int { m.adapterMaxWatts = Double(w) }
            m.adapterDescription = adapter["Description"] as? String
            m.adapterName = (adapter["Name"] as? String) ?? (adapter["Description"] as? String)
            m.adapterManufacturer = adapter["Manufacturer"] as? String
            m.adapterSerial = (adapter["SerialString"] as? String) ?? (adapter["SerialNumber"] as? String)
            // AdapterDetails reports millivolts / milliamps when present.
            if let mv = (adapter["AdapterVoltage"] as? Int) ?? (adapter["Voltage"] as? Int) {
                m.adapterVoltageV = Double(mv) / 1000.0
            }
            if let ma = adapter["Current"] as? Int { m.adapterCurrentA = Double(ma) / 1000.0 }
        }
        // Apple Silicon exposes instantaneous power telemetry (values in mW).
        if let tele = d["PowerTelemetryData"] as? [String: Any] {
            if let inW = tele["SystemPowerIn"] as? Int { m.adapterInputW = Double(inW) / 1000.0 }
            if let load = tele["SystemLoad"] as? Int { m.systemLoadW = Double(load) / 1000.0 }
        }
    }
}
