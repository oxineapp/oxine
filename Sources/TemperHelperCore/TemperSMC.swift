import Foundation
import IOKit
import TemperShared

// MARK: - Low-level AppleSMC access (fan keys)
//
// Same canonical AppleSMC struct protocol as SousHelperCore/SMC.swift (SMCKit /
// smcFanControl / iStats layout). Fan control on Apple Silicon is documented in
// agoodkind/macos-smc-fan and exelban/stats#2928:
//   FNum            fan count (uint8)
//   F%dAc           actual RPM       (float on Apple Silicon, fpe2 on legacy)
//   F%dMn / F%dMx   min / max RPM    (guidelines, not hard limits)
//   F%dTg           target RPM (write to drive the fan)
//   F%dMd / F%dmd   mode: 0 auto, 1 manual, 3 system (uppercase M4-, lowercase M5)
//   Ftst            diagnostic flag - set 1 to suppress thermalmonitord's reclaim
//                   so a manual mode/target write sticks (absent on M5).
// Reads are unprivileged; writes need root (this daemon).

private let kSMCReadKey: UInt8 = 5
private let kSMCWriteKey: UInt8 = 6
private let kSMCGetKeyInfo: UInt8 = 9
private let kKernelIndexSMC: UInt32 = 2
private let kSMCSuccess: UInt8 = 0

private struct SMCVersion {
    var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
    var release: UInt16 = 0
}
private struct SMCPLimitData {
    var version: UInt16 = 0, length: UInt16 = 0
    var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
}
private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)
private let zeroBytes: SMCBytes = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                                   0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)

private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    // CRITICAL: padding makes the struct match the kernel's 80-byte
    // SMCKeyData_t. Without it Swift packs to 76 and every call returns
    // kIOReturnBadArgument - i.e. all SMC reads/writes silently no-op.
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = zeroBytes
}

/// A thin, synchronous SMC connection. Confined to the daemon's serial queue -
/// not thread-safe on its own.
final class TemperSMC {
    private var conn: io_connect_t = 0

    func open() -> Bool {
        let device = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard device != 0 else { return false }
        defer { IOObjectRelease(device) }
        return IOServiceOpen(device, mach_task_self_, 0, &conn) == kIOReturnSuccess
    }

    func close() { if conn != 0 { IOServiceClose(conn); conn = 0 } }

    private func fourCharCode(_ s: String) -> UInt32 {
        var r: UInt32 = 0
        for ch in s.utf8.prefix(4) { r = (r << 8) | UInt32(ch) }
        return r
    }

    private func call(_ input: inout SMCParamStruct, _ output: inout SMCParamStruct) -> Bool {
        var outSize = MemoryLayout<SMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(conn, kKernelIndexSMC,
                                           &input, MemoryLayout<SMCParamStruct>.stride,
                                           &output, &outSize)
        return kr == kIOReturnSuccess && output.result == kSMCSuccess
    }

    private func keyInfo(_ key: UInt32) -> SMCKeyInfoData? {
        var input = SMCParamStruct(); input.key = key; input.data8 = kSMCGetKeyInfo
        var output = SMCParamStruct()
        return call(&input, &output) ? output.keyInfo : nil
    }

    /// Raw bytes + declared size for `keyStr`, or nil if absent/unreadable.
    func read(_ keyStr: String) -> (bytes: [UInt8], size: Int)? {
        let key = fourCharCode(keyStr)
        guard let info = keyInfo(key) else { return nil }
        var input = SMCParamStruct()
        input.key = key
        input.keyInfo.dataSize = info.dataSize
        input.data8 = kSMCReadKey
        var output = SMCParamStruct()
        guard call(&input, &output) else { return nil }
        let size = min(Int(info.dataSize), 32)
        var out = [UInt8](repeating: 0, count: size)
        withUnsafeBytes(of: output.bytes) { raw in for i in 0..<size { out[i] = raw[i] } }
        return (out, Int(info.dataSize))
    }

    @discardableResult
    func write(_ keyStr: String, _ data: [UInt8]) -> Bool {
        let key = fourCharCode(keyStr)
        guard let info = keyInfo(key) else { return false }
        var input = SMCParamStruct()
        input.key = key
        input.keyInfo.dataSize = info.dataSize
        input.data8 = kSMCWriteKey
        withUnsafeMutableBytes(of: &input.bytes) { raw in
            for i in 0..<min(data.count, 32) { raw[i] = data[i] }
        }
        var output = SMCParamStruct()
        return call(&input, &output)
    }

    func exists(_ keyStr: String) -> Bool { keyInfo(fourCharCode(keyStr)) != nil }

    // MARK: Typed reads

    /// Decode a numeric SMC value: 4-byte little-endian float (Apple Silicon) or
    /// 2-byte fpe2 fixed-point (legacy: raw / 4).
    func readNumber(_ keyStr: String) -> Double? {
        guard let (b, size) = read(keyStr) else { return nil }
        if size >= 4, b.count >= 4 {
            let raw = UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
            let v = Double(Float(bitPattern: raw))
            return v.isFinite ? v : nil
        }
        if size == 2, b.count >= 2 {
            let raw = UInt16(b[0]) << 8 | UInt16(b[1])   // fpe2 is big-endian
            return Double(raw) / 4.0
        }
        if let first = b.first { return Double(first) }
        return nil
    }

    func readByte(_ keyStr: String) -> Int? {
        guard let (b, _) = read(keyStr), let first = b.first else { return nil }
        return Int(first)
    }

    /// Encode a numeric value to match the key's declared SMC type, then write it.
    @discardableResult
    func writeNumber(_ keyStr: String, _ value: Double) -> Bool {
        let key = fourCharCode(keyStr)
        guard let info = keyInfo(key) else { return false }
        var bytes: [UInt8]
        if info.dataSize >= 4 {
            let bits = Float(value).bitPattern
            bytes = [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF),
                     UInt8((bits >> 16) & 0xFF), UInt8((bits >> 24) & 0xFF)]
        } else {
            let raw = UInt16(min(max(value, 0), 65535/4) * 4)   // fpe2 big-endian
            bytes = [UInt8(raw >> 8), UInt8(raw & 0xFF)]
        }
        return write(keyStr, bytes)
    }
}

// MARK: - Fan-control semantics

extension TemperSMC {
    private static let ftstKey = "Ftst"

    var fanCount: Int { readByte("FNum") ?? 0 }

    func actualRPM(_ i: Int) -> Double { readNumber("F\(i)Ac") ?? 0 }
    func minRPM(_ i: Int) -> Double { readNumber("F\(i)Mn") ?? 0 }
    func maxRPM(_ i: Int) -> Double { readNumber("F\(i)Mx") ?? 0 }
    func targetRPM(_ i: Int) -> Double { readNumber("F\(i)Tg") ?? 0 }

    /// The mode key for fan `i`, probing the M4-and-earlier uppercase form first,
    /// then the M5 lowercase form. nil if neither exists.
    func modeKey(_ i: Int) -> String? {
        let upper = "F\(i)Md", lower = "F\(i)md"
        if exists(upper) { return upper }
        if exists(lower) { return lower }
        return nil
    }

    var hasFtst: Bool { exists(Self.ftstKey) }
    func setFtst(_ on: Bool) { write(Self.ftstKey, [on ? 1 : 0]) }

    /// Whether this Mac has fans we can actually drive (a writable target key).
    var canControlFans: Bool {
        guard fanCount > 0 else { return false }
        return exists("F0Tg")
    }

    /// Put fan `i` into manual mode (best-effort; relies on Ftst being set first
    /// on M4-class machines, and is retried every daemon tick until it sticks).
    func setFanManual(_ i: Int) {
        guard let key = modeKey(i) else { return }
        write(key, [1])
    }

    /// Hand fan `i` back to the system's thermal management.
    func setFanAuto(_ i: Int) {
        guard let key = modeKey(i) else { return }
        write(key, [0])
    }

    func setTargetRPM(_ i: Int, _ rpm: Double) { writeNumber("F\(i)Tg", rpm) }

    // MARK: Temperatures

    /// A pragmatic set of SMC temperature keys spanning Apple Silicon and Intel.
    /// Many won't exist on any given machine (Apple Silicon routes most per-core
    /// sensors through the HID sensor hub, not the SMC); we read whatever answers.
    static let tempKeys = TemperSensors.tempKeys

    /// Read every present temperature sensor (°C), de-duplicated by label with a
    /// plausibility filter so junk keys don't show up.
    func temperatures() -> [(key: String, label: String, celsius: Double)] {
        var out: [(String, String, Double)] = []
        var seenLabels = Set<String>()
        for (key, label) in Self.tempKeys {
            guard let c = readNumber(key), c >= 10, c < 130 else { continue }
            guard !seenLabels.contains(label) else { continue }
            seenLabels.insert(label)
            out.append((key, label, c))
        }
        return out
    }

    /// The hottest readable SMC temperature, or 0 if none answer.
    func hottestC() -> Double { temperatures().map(\.celsius).max() ?? 0 }

    // Extra control inputs for the Smart controller (all `flt`, read unprivileged).
    /// The leading "load" signal for feedforward: heatpipe power `PHPC` (heat
    /// actually reaching the cooling path - responsive and transport-aware) with
    /// total system power `PSTR` as a fallback on machines without it.
    func loadPowerW() -> Double {
        let phpc = readNumber("PHPC") ?? 0
        return phpc > 0 ? phpc : (readNumber("PSTR") ?? 0)
    }
    /// Ambient temperature (°C): the heat sink the fan works against. Virtual
    /// ambient first, then the lid sensor.
    func ambientC() -> Double { readNumber("TVA0") ?? readNumber("TAOL") ?? 0 }
}
