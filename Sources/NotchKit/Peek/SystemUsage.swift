import Foundation
import Darwin
import IOKit

/// Whole-machine CPU + GPU utilisation (0…1). CPU is `host_statistics(HOST_CPU_LOAD_INFO)`;
/// GPU is the IOAccelerator "Device Utilization %" from the IO registry. Both are
/// permission-free and cheap; used by the metric ear content and the notch bar.
@MainActor
public final class SystemUsageMonitor: ObservableObject {
    @Published public private(set) var cpu: Double = 0
    @Published public private(set) var gpu: Double = 0

    private var timer: Timer?
    private var prev: (total: Double, busy: Double)?

    func start() {
        guard timer == nil else { return }
        sample(); sampleGPU()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample(); self?.sampleGPU() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// GPU busy fraction from the accelerator's PerformanceStatistics. Keys differ
    /// by silicon (Apple Silicon = "Device Utilization %"), so we try the common
    /// ones and take the busiest reported GPU.
    private func sampleGPU() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        var best = 0.0
        var found = false
        var svc = IOIteratorNext(iterator)
        while svc != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let perf = dict["PerformanceStatistics"] as? [String: Any] {
                let util = (perf["Device Utilization %"] as? NSNumber)
                    ?? (perf["GPU Activity(%)"] as? NSNumber)
                    ?? (perf["Renderer Utilization %"] as? NSNumber)
                if let util { best = max(best, util.doubleValue / 100.0); found = true }
            }
            IOObjectRelease(svc)
            svc = IOIteratorNext(iterator)
        }
        if found { gpu = min(max(best, 0), 1) }
    }

    private func sample() {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info()
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let user = Double(info.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3)
        let total = user + system + idle + nice
        let busy = user + system + nice
        if let p = prev {
            let dT = total - p.total, dB = busy - p.busy
            if dT > 0 { cpu = max(0, min(1, dB / dT)) }
        }
        prev = (total, busy)
    }
}
