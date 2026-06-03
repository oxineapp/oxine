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

    /// Last accepted reading per SMC key, so a transient garbage frame can hold
    /// the previous value instead of dropping the sensor. Touched only under
    /// `queue`, so it needs no extra locking.
    private var lastGoodTemp: [String: Double] = [:]

    /// Present SMC temperature sensors (°C), de-duplicated by label. The basic
    /// curated list, or the richer grouped set for the extended view.
    func temperatures(extended: Bool = false) -> [(key: String, label: String, celsius: Double, group: String?)] {
        let list: [(key: String, label: String, group: String?)] = extended
            ? TemperSensors.extendedTempKeys.map { ($0.key, $0.label, $0.group) }
            : TemperSensors.tempKeys.map { ($0.key, $0.label, nil) }
        return queue.sync {
            ensureOpen()
            guard conn != 0 else { return [] }
            var out: [(String, String, Double, String?)] = []
            var seen = Set<String>()
            // De-dup by group+label so the extended view can reuse short labels
            // (e.g. "Left"/"Right") across different subsystem groups.
            for (key, label, group) in list where !seen.contains((group ?? "") + label) {
                guard let raw = readNumber(key) else { continue }   // key absent → try next
                let prev = lastGoodTemp[key]
                // We can't tell a real low temperature from a glitch in a single
                // sample (7°C and a bogus 2°C are both "low"), so judge by history,
                // not an absolute floor. Reject only a sudden low-side nosedive —
                // a >25°C drop into the cold zone within one tick, the signature of
                // a stale/zeroed SMC frame — and HOLD the sensor's last good value
                // so CPU perf/eff never disappear from the list. A genuine low temp
                // (no prior, or reached gradually) passes straight through.
                let plausible = raw >= 0 && raw < 130
                let glitch = plausible && raw < 25 && (prev.map { $0 - raw > 25 } ?? false)
                let value: Double
                if plausible && !glitch {
                    value = raw
                    lastGoodTemp[key] = raw
                } else if let prev {
                    value = prev
                } else {
                    continue                                        // implausible, no baseline yet
                }
                seen.insert((group ?? "") + label)
                out.append((key, label, value, group))
            }
            return out
        }
    }

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

    /// Raw bytes, declared size, and SMC data type (FourCC) for a key, or nil if
    /// absent. The type lets the decoder honor the real encoding instead of
    /// guessing from byte length.
    private func read(_ keyStr: String) -> (bytes: [UInt8], size: Int, type: UInt32)? {
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
        return (out, Int(infoOut.keyInfo.dataSize), infoOut.keyInfo.dataType)
    }

    private func readByte(_ keyStr: String) -> Int? {
        guard let (b, _, _) = read(keyStr), let first = b.first else { return nil }
        return Int(first)
    }

    /// Decode a key's value using its declared SMC data type, not a guess from
    /// byte length. Apple Silicon temps are `flt` (4-byte little-endian float);
    /// Intel temps are big-endian fixed-point `spXY` (signed) / `fpXY` (unsigned),
    /// where the low hex digit is the fraction-bit count (sp78 → ÷256, fpe2 → ÷4).
    private func readNumber(_ keyStr: String) -> Double? {
        guard let (b, size, type) = read(keyStr) else { return nil }
        if size >= 4, b.count >= 4 {
            let raw = UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
            let v = Double(Float(bitPattern: raw))
            return v.isFinite ? v : nil
        }
        if size == 2, b.count >= 2 {
            let mag = UInt16(b[0]) << 8 | UInt16(b[1])           // SMC fixed-point is big-endian
            let t = Self.fourCC(type)
            if t.hasPrefix("sp"), let frac = Int(t.suffix(1), radix: 16) {
                return Double(Int16(bitPattern: mag)) / Double(1 << frac)
            }
            if t.hasPrefix("fp"), let frac = Int(t.suffix(1), radix: 16) {
                return Double(mag) / Double(1 << frac)
            }
            return Double(mag) / 4.0                             // legacy fpe2 assumption
        }
        if let first = b.first { return Double(first) }
        return nil
    }

    /// The SMC data type rendered as its FourCC string (e.g. "flt ", "sp78"). The
    /// device may report it byte-swapped; if the natural order doesn't start with
    /// a letter, try the reverse.
    private static func fourCC(_ v: UInt32) -> String {
        let be = [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]
        let s = String(bytes: be, encoding: .ascii) ?? ""
        if let f = s.first, f.isLetter { return s }
        return String(bytes: be.reversed(), encoding: .ascii) ?? s
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
