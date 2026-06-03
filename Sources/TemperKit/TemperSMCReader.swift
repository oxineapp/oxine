import Foundation
import IOKit
import TemperShared

/// Read-only, unprivileged AppleSMC access for fan speeds and temperatures - the
/// monitoring half of Temper, which works on every Mac with no daemon and no
/// admin prompt. SMC *reads* need no root (only the daemon's fan *writes* do), so
/// the dashboard reads directly. Same 80-byte struct ABI as the daemon's SMC and
/// SousKit's `AppSMC`.
final class TemperSMCReader: @unchecked Sendable {
    static let shared = TemperSMCReader()

    private let queue = DispatchQueue(label: "com.oxine.tempersmc")
    private var conn: io_connect_t = 0
    private var opened = false

    private func ensureOpen() {
        guard !opened else { return }
        opened = true
        let device = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard device != 0 else { return }
        defer { IOObjectRelease(device) }
        _ = IOServiceOpen(device, mach_task_self_, 0, &conn)
    }

    /// All fans the SMC reports, with live RPMs. Target is reported as the actual
    /// speed here (the privileged daemon is the source of truth for real targets).
    func fans() -> [FanInfo] {
        queue.sync {
            ensureOpen()
            guard conn != 0, let count = readByte("FNum"), count > 0 else { return [] }
            return (0..<count).map { i in
                FanInfo(index: i,
                        actualRPM: readNumber("F\(i)Ac") ?? 0,
                        minRPM: readNumber("F\(i)Mn") ?? 0,
                        maxRPM: readNumber("F\(i)Mx") ?? 0,
                        targetRPM: readNumber("F\(i)Ac") ?? 0)
            }
        }
    }

    /// Present SMC temperature sensors (°C), de-duplicated by label.
    func temperatures() -> [(key: String, label: String, celsius: Double)] {
        queue.sync {
            ensureOpen()
            guard conn != 0 else { return [] }
            var out: [(String, String, Double)] = []
            var seen = Set<String>()
            for (key, label) in Self.tempKeys {
                // Floor at 10°C: a powered Mac's internal sensors never read that
                // low, so anything below it is a transient garbage read (the cause
                // of the occasional bogus "2°C").
                guard let c = readNumber(key), c >= 10, c < 130, !seen.contains(label) else { continue }
                seen.insert(label)
                out.append((key, label, c))
            }
            return out
        }
    }

    /// The same pragmatic key list the daemon probes (see TemperSMC.tempKeys).
    private static let tempKeys: [(key: String, label: String)] = [
        ("TC0P", "CPU"), ("TC0D", "CPU die"), ("TC0E", "CPU"), ("TC0F", "CPU"),
        ("Tp09", "CPU perf"), ("Tp01", "CPU perf"), ("Tp05", "CPU eff"),
        ("TG0P", "GPU"), ("TG0D", "GPU die"), ("Tg05", "GPU"), ("Tg0D", "GPU"),
        ("TaLP", "Airflow L"), ("TaRP", "Airflow R"), ("TA0P", "Ambient"),
        ("Ts0P", "Enclosure"), ("Ts1P", "Enclosure"),
        ("TB0T", "Battery"), ("TB1T", "Battery"), ("TB2T", "Battery"),
        ("TW0P", "Wi-Fi"), ("TH0x", "SSD"), ("Tm0P", "Mainboard"),
    ]

    // MARK: SMC plumbing (read path only)

    private func fourCharCode(_ s: String) -> UInt32 {
        var r: UInt32 = 0
        for ch in s.utf8.prefix(4) { r = (r << 8) | UInt32(ch) }
        return r
    }

    private func call(_ input: inout SMCParam, _ output: inout SMCParam) -> Bool {
        var outSize = MemoryLayout<SMCParam>.stride
        let kr = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCParam>.stride, &output, &outSize)
        return kr == kIOReturnSuccess && output.result == 0
    }

    /// Raw bytes + declared size for a key, or nil if absent.
    private func read(_ keyStr: String) -> (bytes: [UInt8], size: Int)? {
        let key = fourCharCode(keyStr)
        var info = SMCParam(); info.key = key; info.data8 = 9   // READ_KEYINFO
        var infoOut = SMCParam()
        guard call(&info, &infoOut), infoOut.keyInfo.dataSize > 0 else { return nil }
        var input = SMCParam()
        input.key = key
        input.keyInfo.dataSize = infoOut.keyInfo.dataSize
        input.data8 = 5                                         // READ_BYTES
        var output = SMCParam()
        guard call(&input, &output) else { return nil }
        let size = min(Int(infoOut.keyInfo.dataSize), 32)
        var out = [UInt8](repeating: 0, count: size)
        withUnsafeBytes(of: output.bytes) { raw in for i in 0..<size { out[i] = raw[i] } }
        return (out, Int(infoOut.keyInfo.dataSize))
    }

    private func readByte(_ keyStr: String) -> Int? {
        guard let (b, _) = read(keyStr), let first = b.first else { return nil }
        return Int(first)
    }

    /// 4-byte little-endian float (Apple Silicon) or 2-byte fpe2 (legacy).
    private func readNumber(_ keyStr: String) -> Double? {
        guard let (b, size) = read(keyStr) else { return nil }
        if size >= 4, b.count >= 4 {
            let raw = UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
            let v = Double(Float(bitPattern: raw))
            return v.isFinite ? v : nil
        }
        if size == 2, b.count >= 2 {
            let raw = UInt16(b[0]) << 8 | UInt16(b[1])
            return Double(raw) / 4.0
        }
        if let first = b.first { return Double(first) }
        return nil
    }
}

// Minimal mirror of the AppleSMC struct ABI (must total 80 bytes - see the
// padding note in SousKit/SMCReader.swift; without it every call no-ops).
private struct SMCVers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
private struct SMCPLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
private struct SMCKeyInfo { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }
private typealias SMCBuf = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
private struct SMCParam {
    var key: UInt32 = 0
    var vers = SMCVers()
    var pLimitData = SMCPLimit()
    var keyInfo = SMCKeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBuf = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}
