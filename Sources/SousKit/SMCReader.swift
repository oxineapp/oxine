import Foundation
import IOKit

/// Read-only, unprivileged AppleSMC access for real-time power telemetry.
///
/// `AppleSmartBattery` (IORegistry) only refreshes its electrical fields about
/// once a minute, so it's useless for a live Power Flow. The SMC keys
/// (`PDTR` adapter-in, `B0AC`/`B0AV` battery current/voltage) refresh together
/// once a second. SMC *reads* need no root (only the charge-control *writes* in
/// the daemon do), so the app reads them directly. Float keys are 4-byte
/// little-endian IEEE-754; the battery integers are little-endian too.
final class AppSMC: @unchecked Sendable {
    static let shared = AppSMC()

    private let queue = DispatchQueue(label: "com.oxine.appsmc")
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

    /// Adapter power drawn from the wall, in watts (0 when unplugged / unknown).
    func adapterPowerW() -> Double? { readFloat("PDTR") }
    /// Battery current in amps, signed: positive = into the battery (`B0AC`, mA).
    /// Reads 0 while Sous holds the charge.
    func batteryCurrentA() -> Double? {
        readBytes("B0AC", count: 2).map { Double(Int16(bitPattern: UInt16($0[0]) | (UInt16($0[1]) << 8))) / 1000 }
    }
    /// Battery pack voltage in volts (`B0AV`, mV).
    func batteryVoltageV() -> Double? {
        readBytes("B0AV", count: 2).map { Double(UInt16($0[0]) | (UInt16($0[1]) << 8)) / 1000 }
    }

    // MARK: SMC plumbing (read path only)

    private func readFloat(_ key: String) -> Double? {
        guard let bytes = readBytes(key, count: 4) else { return nil }
        let raw = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        let v = Double(Float(bitPattern: raw))
        return v.isFinite ? abs(v) : nil
    }

    private func readBytes(_ key: String, count: Int) -> [UInt8]? {
        queue.sync {
            ensureOpen()
            guard conn != 0, let bytes = read(key), bytes.count >= count else { return nil }
            return bytes
        }
    }

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

    private func read(_ keyStr: String) -> [UInt8]? {
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
        return out
    }
}

// Minimal mirror of the AppleSMC struct ABI (matches SMCKit / the daemon's SMC).
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
    var padding: UInt16 = 0   // makes the struct the kernel's 80-byte size (else 76 → all calls fail)
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBuf = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}
