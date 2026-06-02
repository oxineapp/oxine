import Foundation
import IOKit

// MARK: - Low-level AppleSMC access
//
// Mirrors the long-established AppleSMC struct protocol (the layout used by
// SMCKit / smcFanControl / iStats). The charge- and adapter-control key logic
// is ported from charlie0129/batt (Apache-2.0): CH0B/CH0C (+ CHTE fallback) for
// charging, CH0I/CH0J/CHIE for the power adapter, BUIC for hardware charge, and
// AC-W for adapter presence. Apple Silicon only.

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

/// 32-byte SMC payload buffer (matches `UInt8 bytes[32]`).
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
    // CRITICAL: this padding makes the struct match the kernel's 80-byte
    // SMCKeyData_t. Without it Swift packs to 76 and every call returns
    // kIOReturnBadArgument (0xe00002c2) — i.e. SMC silently does nothing.
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = zeroBytes
}

/// A thin, synchronous SMC connection. Confined to the daemon's serial queue —
/// not thread-safe on its own.
final class SMC {
    private var conn: io_connect_t = 0

    func open() -> Bool {
        let device = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard device != 0 else { return false }
        defer { IOObjectRelease(device) }
        return IOServiceOpen(device, mach_task_self_, 0, &conn) == kIOReturnSuccess
    }

    func close() {
        if conn != 0 { IOServiceClose(conn); conn = 0 }
    }

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

    /// Read raw bytes for `keyStr`, or nil if the key is absent/unreadable.
    func read(_ keyStr: String) -> [UInt8]? {
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
        withUnsafeBytes(of: output.bytes) { raw in
            for i in 0..<size { out[i] = raw[i] }
        }
        return out
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

    func exists(_ keyStr: String) -> Bool { read(keyStr) != nil }
}

// MARK: - Battery-control semantics (ported from batt)

extension SMC {
    private static let chargeKey1 = "CH0B"
    private static let chargeKey2 = "CH0C"
    private static let chargeKey3 = "CHTE"        // single-key fallback
    private static let adapterKey1 = "CH0I"
    private static let adapterKey2 = "CH0J"
    private static let adapterKey3 = "CHIE"        // Tahoe / macOS 26 firmware
    private static let acPowerKey = "AC-W"
    private static let hwChargeKey = "BUIC"
    // MagSafe LED: colour is *controlled* by writing ACLC; MSLD is the LED
    // status register, present only on Macs that actually have the LED — so we
    // gate on it for capability and write to ACLC for control.
    private static let ledControlKey = "ACLC"
    private static let ledPresenceKey = "MSLD"

    var canControlCharging: Bool {
        (exists(Self.chargeKey1) && exists(Self.chargeKey2)) || exists(Self.chargeKey3)
    }
    var canControlAdapter: Bool {
        exists(Self.adapterKey1) || exists(Self.adapterKey2) || exists(Self.adapterKey3)
    }

    /// true = battery is allowed to charge; false = charging inhibited (hold).
    func setChargingEnabled(_ enabled: Bool) {
        if exists(Self.chargeKey1) && exists(Self.chargeKey2) {
            let v: [UInt8] = enabled ? [0x0] : [0x2]
            write(Self.chargeKey1, v)
            write(Self.chargeKey2, v)
        } else {
            write(Self.chargeKey3, enabled ? [0,0,0,0] : [1,0,0,0])
        }
    }

    var isChargingEnabled: Bool {
        if exists(Self.chargeKey1) {
            guard let v = read(Self.chargeKey1) else { return true }
            return v.first == 0x0
        }
        guard let v = read(Self.chargeKey3) else { return true }
        return v.allSatisfy { $0 == 0 }
    }

    /// true = adapter powers the system normally; false = adapter cut so the
    /// battery drains while plugged (the "discharge" mechanism).
    func setAdapterEnabled(_ enabled: Bool) {
        if exists(Self.adapterKey1) {
            write(Self.adapterKey1, enabled ? [0x0] : [0x1])
        } else if exists(Self.adapterKey2) {
            write(Self.adapterKey2, enabled ? [0x0] : [0x1])
        } else if exists(Self.adapterKey3) {
            write(Self.adapterKey3, enabled ? [0x0] : [0x8])  // Tahoe disable = 0x8
        }
    }

    var isAdapterEnabled: Bool {
        for k in [Self.adapterKey1, Self.adapterKey2, Self.adapterKey3] where exists(k) {
            guard let v = read(k) else { return true }
            return v.first == 0x0
        }
        return true
    }

    /// Hardware battery percentage (BUIC). Falls back to -1 if unavailable.
    var hardwareCharge: Int {
        guard let v = read(Self.hwChargeKey), let b = v.first else { return -1 }
        return Int(b)
    }

    var isPluggedIn: Bool {
        guard let v = read(Self.acPowerKey), let b = v.first else { return false }
        return Int8(bitPattern: b) > 0
    }

    // MARK: MagSafe LED (ACLC)

    /// MagSafe LED states. Raw values are the `ACLC` byte (verified mapping):
    /// 0 restores system control, 1 off, 3 green, 4 orange, 6 slow-blink orange.
    enum LEDMode: UInt8 { case auto = 0, off = 1, green = 3, amber = 4, blinkAmber = 6 }

    /// This Mac actually has a MagSafe status LED (gates on the MSLD register).
    var canControlLED: Bool { exists(Self.ledPresenceKey) }

    func setLED(_ mode: LEDMode) {
        guard canControlLED else { return }
        write(Self.ledControlKey, [mode.rawValue])
    }

}
