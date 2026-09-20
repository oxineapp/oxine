import AudioToolbox
import CoreAudio
import Foundation

/// Thin, typed reads over the Core Audio object/property API — the only place
/// in TapKit that touches `AudioObjectGetPropertyData` directly.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// One fixed-size value (a UInt32, a pid, an ASBD…).
    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) -> T? {
        var addr = address(selector, scope: scope)
        var out = initial
        var size = UInt32(MemoryLayout<T>.size)
        let err = withUnsafeMutablePointer(to: &out) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
        return err == noErr ? out : nil
    }

    static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, of: T.Type) -> [T] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        return [T](unsafeUninitializedCapacity: count) { buf, n in
            let err = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buf.baseAddress!)
            n = err == noErr ? Int(size) / MemoryLayout<T>.stride : 0
        }
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var addr = address(selector, scope: scope)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = withUnsafeMutablePointer(to: &ref) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
        guard err == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }

    /// The Core Audio process object for a pid, if that process has ever
    /// touched audio.
    static func processObject(pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var out = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &out)
        return err == noErr && out != kAudioObjectUnknown ? out : nil
    }
}

/// One process Core Audio knows about. Browsers and Electron apps play sound
/// from helper processes; `AudioApps` folds those under the app you can see.
public struct AudioProcess: Hashable, Sendable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String
    public let isPlaying: Bool
}

public struct OutputDevice: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let transport: UInt32

    public var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
    public var symbol: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: "display"
        case kAudioDeviceTransportTypeAirPlay: "airplayaudio"
        case kAudioDeviceTransportTypeUSB: "cable.connector"
        default: "hifispeaker"
        }
    }
}

public enum AudioSystem {
    public static func processes() -> [AudioProcess] {
        CA.array(CA.system, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self).compactMap { obj in
            guard let pid = CA.value(obj, kAudioProcessPropertyPID, initial: pid_t(0)), pid > 0 else { return nil }
            let playing = CA.value(obj, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0
            return AudioProcess(objectID: obj, pid: pid,
                                bundleID: CA.string(obj, kAudioProcessPropertyBundleID) ?? "",
                                isPlaying: playing != 0)
        }
    }

    /// Real devices with at least one output stream. Aggregates (ours are
    /// private anyway) and virtual devices stay out of the routing list.
    public static func outputDevices() -> [OutputDevice] {
        CA.array(CA.system, kAudioHardwarePropertyDevices, of: AudioDeviceID.self).compactMap { dev in
            guard !CA.array(dev, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput, of: AudioStreamID.self).isEmpty,
                  let uid = CA.string(dev, kAudioDevicePropertyDeviceUID) else { return nil }
            let transport = CA.value(dev, kAudioDevicePropertyTransportType, initial: UInt32(0)) ?? 0
            guard transport != kAudioDeviceTransportTypeAggregate, transport != kAudioDeviceTransportTypeVirtual else { return nil }
            return OutputDevice(id: dev, uid: uid, name: CA.string(dev, kAudioObjectPropertyName) ?? uid, transport: transport)
        }
    }

    public static func defaultOutputDevice() -> AudioDeviceID? {
        guard let dev = CA.value(CA.system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioDeviceID(kAudioObjectUnknown)),
              dev != kAudioObjectUnknown else { return nil }
        return dev
    }

    public static func setDefaultOutput(_ device: AudioDeviceID) {
        var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        var dev = device
        AudioObjectSetPropertyData(CA.system, &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
    }

    /// The "virtual main" volume is the one the volume keys move, whatever the
    /// device's real channel layout.
    static let volumeSelectors = [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute]

    public static func volume(of device: AudioDeviceID) -> Float? {
        CA.value(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput, initial: Float32(0))
    }

    public static func setVolume(_ volume: Float, of device: AudioDeviceID) {
        var addr = CA.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
        var v = Float32(volume)
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    public static func isMuted(_ device: AudioDeviceID) -> Bool {
        (CA.value(device, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, initial: UInt32(0)) ?? 0) != 0
    }

    public static func setMuted(_ muted: Bool, of device: AudioDeviceID) {
        var addr = CA.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
        var v: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
    }

    public static func defaultOutputUID() -> String? {
        guard let dev = CA.value(CA.system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioDeviceID(kAudioObjectUnknown)),
              dev != kAudioObjectUnknown else { return nil }
        return CA.string(dev, kAudioDevicePropertyDeviceUID)
    }

    /// Calls back on the main queue when processes start or stop playing, when
    /// devices come and go, or when the default output changes. Returns a token;
    /// keep it, and call `cancel()` to stop listening.
    public static func observeChanges(_ handler: @escaping @Sendable () -> Void) -> ChangeObservation {
        ChangeObservation(handler)
    }

    public final class ChangeObservation: @unchecked Sendable {
        private let block: AudioObjectPropertyListenerBlock
        private static let selectors = [kAudioHardwarePropertyProcessObjectList,
                                        kAudioHardwarePropertyDevices,
                                        kAudioHardwarePropertyDefaultOutputDevice]
        fileprivate init(_ handler: @escaping @Sendable () -> Void) {
            block = { _, _ in handler() }
            for s in Self.selectors {
                var addr = CA.address(s)
                AudioObjectAddPropertyListenerBlock(CA.system, &addr, .main, block)
            }
        }
        public func cancel() {
            for s in Self.selectors {
                var addr = CA.address(s)
                AudioObjectRemovePropertyListenerBlock(CA.system, &addr, .main, block)
            }
        }
    }
}
