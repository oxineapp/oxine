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

    /// True once we've successfully read a battery (used to gate the UI between
    /// "no battery / desktop Mac" and live data).
    var isValid: Bool { hasBattery }
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

        if let adapter = d["AdapterDetails"] as? [String: Any] {
            if let w = adapter["Watts"] as? Int { m.adapterMaxWatts = Double(w) }
            m.adapterDescription = adapter["Description"] as? String
        }
        // Apple Silicon exposes instantaneous power telemetry (values in mW).
        if let tele = d["PowerTelemetryData"] as? [String: Any] {
            if let inW = tele["SystemPowerIn"] as? Int { m.adapterInputW = Double(inW) / 1000.0 }
            if let load = tele["SystemLoad"] as? Int { m.systemLoadW = Double(load) / 1000.0 }
        }
    }
}
