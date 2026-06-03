import Foundation
import IOKit
import Darwin
import TemperShared

/// One temperature sensor reading for the dashboard.
public struct TempSensor: Identifiable, Sendable, Equatable {
    public var key: String
    public var label: String
    public var celsius: Double
    public var id: String { key }
}

/// A read-only snapshot of the machine's thermal + performance state, gathered
/// with zero privileges. This is the always-available half of Temper - it works
/// on every Mac (fanless Airs included) with no daemon and no admin prompt.
public struct TemperMetrics: Sendable, Equatable {
    /// macOS's own thermal-pressure signal - the headline, present on all Macs.
    public var thermalState: ProcessInfo.ThermalState = .nominal
    public var fans: [FanInfo] = []
    public var sensors: [TempSensor] = []
    /// Whole-machine CPU utilisation, 0–1.
    public var cpuUsage: Double = 0
    public var batteryTempC: Double = 0
    /// Hottest temperature we can see (sensors + battery), or 0 if none.
    public var hottestC: Double = 0

    public var hasFans: Bool { !fans.isEmpty }

    public static func == (l: TemperMetrics, r: TemperMetrics) -> Bool {
        l.thermalState == r.thermalState && l.fans == r.fans && l.sensors == r.sensors
            && l.cpuUsage == r.cpuUsage && l.batteryTempC == r.batteryTempC && l.hottestC == r.hottestC
    }
}

/// Gathers `TemperMetrics`. Holds the previous CPU tick counts so it can report a
/// delta-based utilisation. Owned by `TemperManager` and only ever read on the
/// main actor, so its mutable tick cache needs no extra synchronisation.
@MainActor
final class ThermalReader {
    private var prevTicks: (user: Double, system: Double, idle: Double, nice: Double)?
    /// Last computed CPU usage, reused on ticks that don't refresh it so fans can
    /// update faster than CPU load (the caller drives the cadence).
    private var cachedCPU = 0.0

    /// Read a fresh snapshot. `updateCPU` controls whether CPU load is recomputed
    /// this call (its delta is measured over the gap between recompute calls, so
    /// recomputing at a steady 1 Hz keeps the figure honest); fans/temps are
    /// always fresh.
    func read(updateCPU: Bool = true) -> TemperMetrics {
        var m = TemperMetrics()
        m.thermalState = ProcessInfo.processInfo.thermalState
        m.fans = TemperSMCReader.shared.fans()
        m.sensors = TemperSMCReader.shared.temperatures()
            .map { TempSensor(key: $0.key, label: $0.label, celsius: $0.celsius) }
        m.batteryTempC = Self.batteryTempC()
        if updateCPU { cachedCPU = cpuUsage() }
        m.cpuUsage = cachedCPU
        let temps = m.sensors.map(\.celsius) + (m.batteryTempC > 0 ? [m.batteryTempC] : [])
        m.hottestC = temps.max() ?? 0
        return m
    }

    /// Whole-machine CPU usage from `HOST_CPU_LOAD_INFO` tick deltas (0–1).
    private func cpuUsage() -> Double {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info_data_t()
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let user = Double(info.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3)
        defer { prevTicks = (user, system, idle, nice) }
        guard let p = prevTicks else { return 0 }   // first sample has no baseline
        let dUser = user - p.user, dSystem = system - p.system
        let dIdle = idle - p.idle, dNice = nice - p.nice
        let total = dUser + dSystem + dIdle + dNice
        guard total > 0 else { return 0 }
        return min(max((dUser + dSystem + dNice) / total, 0), 1)
    }

    /// Battery temperature in °C from AppleSmartBattery (centi-°C). No privilege
    /// needed; returns 0 on desktops / read failure.
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

public extension ProcessInfo.ThermalState {
    /// Short user-facing label for the thermal-pressure pill.
    var temperLabel: String {
        switch self {
        case .nominal:  return "Nominal"
        case .fair:     return "Fair"
        case .serious:  return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}
