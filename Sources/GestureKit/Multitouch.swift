import AppKit
import Foundation

// ABI reference: the MTTouch/MTVector definitions and Boolean registration result
// in https://github.com/asmagill/hs._asm.undocumented.touchdevice/blob/master/MultitouchSupport.h
// These are private APIs; fail closed on malformed frames instead of inventing taps.
typealias MTContactCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Void

struct Finger {
    var frame: Int32 = 0
    var timestamp: Double = 0
    var identifier: Int32 = 0
    var state: Int32 = 0
    var fingerID: Int32 = 0
    var handID: Int32 = 0
    var x: Float = 0
    var y: Float = 0
    var velocityX: Float = 0
    var velocityY: Float = 0
    var total: Float = 0
    var pressure: Float = 0
    var angle: Float = 0
    var majorAxis: Float = 0
    var minorAxis: Float = 0
    var absoluteX: Float = 0
    var absoluteY: Float = 0
    var absoluteVelocityX: Float = 0
    var absoluteVelocityY: Float = 0
    var unknown14: Int32 = 0
    var unknown15: Int32 = 0
    var density: Float = 0
}

fileprivate var gMTFrame: ((UInt, [Multitouch.Touch]?) -> Void)?

/// Only aggregate counts are kept for the live menu. No touch coordinates are logged.
private final class TouchStatus {
    let lock = NSLock()
    var devices = 0
    var frames = 0
    var peak = 0
    var contacts: [UInt: Int] = [:]

    func receive(device: UInt, count: Int) {
        lock.lock()
        let first = frames == 0
        frames += 1
        contacts[device] = count
        peak = max(peak, count)
        lock.unlock()
        if first { appLog("MTS touch frames received") }
    }

    func setDevices(_ count: Int) {
        lock.lock()
        devices = count
        if count == 0 { contacts.removeAll() }
        lock.unlock()
    }

    var description: String {
        lock.lock(); defer { lock.unlock() }
        if devices == 0 { return "Trackpad: no touch devices connected" }
        if frames == 0 { return "Trackpad: \(devices) device(s), waiting for touch" }
        return "Trackpad: \(contacts.values.max() ?? 0) fingers · peak \(peak)"
    }
}

final class Multitouch {
    struct Touch {
        let id: Int
        let x: Float
        let y: Float
        let size: Float
    }

    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias Register = @convention(c) (UnsafeMutableRawPointer?, MTContactCallback?) -> Bool
    private typealias Start = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    private typealias Stop = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias DeviceID = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt64>?) -> Int32

    // Retain each device object, not just its pointer, after releasing the enumeration array.
    private final class Device {
        let object: Unmanaged<AnyObject>
        var pointer: UnsafeMutableRawPointer { object.toOpaque() }
        init(_ pointer: UnsafeMutableRawPointer) {
            object = Unmanaged<AnyObject>.fromOpaque(pointer).retain()
        }
        deinit { object.release() }
    }

    private let handle: UnsafeMutableRawPointer
    private let createList: CreateList
    private let register: Register
    private let unregister: Register
    private let start: Start
    private let stop: Stop
    private let deviceID: DeviceID
    private let callback: MTContactCallback
    private var devices: [UInt64: Device] = [:]
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private static let status = TouchStatus()
    var deviceCount: Int { devices.count }
    var statusText: String { Self.status.description }

    static func setFrameHandler(_ handler: @escaping (UInt, [Touch]?) -> Void) {
        gMTFrame = handler
    }

    /// Decode all 96-byte records, including touch-down (3) as well as touching (4).
    /// A nil result is malformed data, not an all-fingers-up event.
    static func decodeFrame(_ raw: UnsafeRawPointer?, count: Int) -> [Touch]? {
        guard count >= 0, count <= 32 else { return nil }
        guard count > 0 else { return [] }
        guard let raw else { return nil }
        var result: [Touch] = []
        var identifiers = Set<Int>()
        for index in 0..<count {
            let finger = raw.loadUnaligned(fromByteOffset: index * MemoryLayout<Finger>.stride, as: Finger.self)
            guard (0...7).contains(finger.state) else { return nil }
            guard finger.state == 3 || finger.state == 4 else { continue }
            guard finger.x.isFinite, finger.y.isFinite, finger.total.isFinite,
                  (-0.2...1.2).contains(finger.x), (-0.2...1.2).contains(finger.y),
                  identifiers.insert(Int(finger.identifier)).inserted else { return nil }
            result.append(Touch(id: Int(finger.identifier), x: finger.x, y: finger.y, size: finger.total))
        }
        return result
    }

    init?() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW) else { return nil }
        guard let list = dlsym(h, "MTDeviceCreateList"),
              let reg = dlsym(h, "MTRegisterContactFrameCallback"),
              let unreg = dlsym(h, "MTUnregisterContactFrameCallback"),
              let begin = dlsym(h, "MTDeviceStart"),
              let end = dlsym(h, "MTDeviceStop"),
              let identity = dlsym(h, "MTDeviceGetDeviceID") else { dlclose(h); return nil }
        handle = h
        createList = unsafeBitCast(list, to: CreateList.self)
        register = unsafeBitCast(reg, to: Register.self)
        unregister = unsafeBitCast(unreg, to: Register.self)
        start = unsafeBitCast(begin, to: Start.self)
        stop = unsafeBitCast(end, to: Stop.self)
        deviceID = unsafeBitCast(identity, to: DeviceID.self)
        callback = { device, raw, count, _, _ in
            guard let device else { return }
            let key = UInt(bitPattern: device)
            guard let touches = Multitouch.decodeFrame(raw, count: Int(count)) else {
                gMTFrame?(key, nil)
                return
            }
            Multitouch.status.receive(device: key, count: touches.count)
            gMTFrame?(key, touches)
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.timer != nil else { return }
            self.disable()
            self.setActive(true)
        }
    }

    deinit {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        timer?.invalidate()
        for device in devices.values {
            _ = unregister(device.pointer, callback)
            stop(device.pointer)
        }
        // Do not dlclose: callbacks already queued by the framework can still return.
    }

    // Registration/start must share the live main run loop. A GCD worker has no
    // persistent run loop on which MultitouchSupport can deliver device events.
    func setActive(_ on: Bool) {
        precondition(Thread.isMainThread)
        guard on else { disable(); return }
        probe()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in self?.probe() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func disable() {
        precondition(Thread.isMainThread)
        timer?.invalidate(); timer = nil
        for device in devices.values {
            _ = unregister(device.pointer, callback)
            stop(device.pointer)
        }
        devices.removeAll()
        Self.status.setDevices(0)
    }

    private func probe() {
        guard let list = createList()?.takeRetainedValue() else { return }
        var seen = Set<UInt64>()
        for index in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let pointer = UnsafeMutableRawPointer(mutating: raw)
            var identity: UInt64 = 0
            guard deviceID(pointer, &identity) == 0 else { continue }
            seen.insert(identity)
            // MTDeviceIsAlive returns false even for a device delivering frames
            // on this Mac. Presence in enumeration is the reliable connection test.
            if devices[identity] != nil { continue }
            // This API returns true on success, not OSStatus zero.
            guard register(pointer, callback) else {
                appLog("MTS callback registration failed")
                continue
            }
            devices[identity] = Device(pointer)
            start(pointer, 0)
            appLog("MTS device connected (\(devices.count) active)")
        }
        for key in devices.keys.filter({ !seen.contains($0) }) {
            if let device = devices.removeValue(forKey: key) {
                _ = unregister(device.pointer, callback)
                stop(device.pointer)
            }
        }
        Self.status.setDevices(devices.count)
    }
}
