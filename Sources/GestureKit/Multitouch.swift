import Foundation

typealias MTContactCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Void

// Reverse-engineered MultitouchSupport.framework contact struct (stable layout since 10.6)
struct Finger {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var unknown1: Int32
    var unknown2: Int32
    var x: Float
    var y: Float
    var z: Float
    var size: Float
    var zero1: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var mmData: UnsafeMutableRawPointer?
    var zero2a: Int32
    var zero2b: Int32
    var vel1: Float
    var vel2: Float
}

fileprivate var gMTFrame: ((UInt, [Multitouch.Touch]) -> Void)?

final class Multitouch {
    struct Touch {
        let id: Int
        let x: Float
        let y: Float
        let size: Float
    }

    private var handle: UnsafeMutableRawPointer?
    private var callbackRef: MTContactCallback?
    private var known = Set<UInt>()
    private var registered = Set<UInt>()
    private var active = false
    private var timer: DispatchSourceTimer?
    private let enumQueue = DispatchQueue(label: "fngestures.mts.enum")

    static func setFrameHandler(_ handler: @escaping (UInt, [Touch]) -> Void) {
        gMTFrame = handler
    }

    init?() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW) else {
            return nil
        }
        self.handle = h
        let cb: MTContactCallback = { device, fingersRaw, n, timestamp, frame in
            guard let device, n >= 0, let g = gMTFrame else { return }
            guard n > 0 else { g(UInt(bitPattern: device), []); return }
            guard let fingersRaw else { return }
            let fingers = fingersRaw.assumingMemoryBound(to: Finger.self)
            var touches: [Touch] = []
            for i in 0..<Int(n) {
                let f = fingers[i]
                if f.state == 4 {
                    touches.append(Touch(id: Int(f.identifier), x: f.x, y: f.y, size: f.size))
                }
            }
            g(UInt(bitPattern: device), touches)
        }
        self.callbackRef = cb
    }

    // Oxine owns one callback for both Fn gestures and plain middle-click taps.
    func setActive(_ on: Bool) {
        enumQueue.async { [weak self] in
            guard let self, let h = self.handle,
                  let p1 = dlsym(h, "MTDeviceCreateList"),
                  let p2 = dlsym(h, "MTDeviceStart"),
                  let p3 = dlsym(h, "MTRegisterContactFrameCallback"),
                  let p4 = dlsym(h, "MTUnregisterContactFrameCallback") else { return }
            let createList = unsafeBitCast(p1, to: (@convention(c) () -> CFMutableArray?).self)
            let start = unsafeBitCast(p2, to: (@convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32).self)
            let register = unsafeBitCast(p3, to: (@convention(c) (UnsafeMutableRawPointer?, MTContactCallback?) -> Int32).self)
            let unregister = unsafeBitCast(p4, to: (@convention(c) (UnsafeMutableRawPointer?, MTContactCallback?) -> Int32).self)
            self.active = on
            if let list = createList() {
                let n = CFArrayGetCount(list)
                for i in 0..<n {
                    let dev = unsafeBitCast(CFArrayGetValueAtIndex(list, i), to: UnsafeMutableRawPointer.self)
                    self.known.insert(UInt(bitPattern: dev))
                }
            }
            if on {
                self.startTimer()
                for key in self.known where !self.registered.contains(key) {
                    let dev = UnsafeMutableRawPointer(bitPattern: key)
                    _ = start(dev, 0)
                    if register(dev, self.callbackRef) == 0 {
                        self.registered.insert(key)
                        appLog("MTS device registered")
                    }
                }
            } else {
                for key in self.registered {
                    let dev = UnsafeMutableRawPointer(bitPattern: key)
                    _ = unregister(dev, self.callbackRef)
                }
                self.registered.removeAll()
                appLog("MTS released (fn up, \(self.registered.count) unregistered)")
            }
        }
    }

    // arm for fn-driven sharing: start the device probe, but don't register until fn is held
    func enable() {
        enumQueue.async { [weak self] in
            guard let self else { return }
            self.startTimer()
            appLog("multi-touch armed (registering on fn hold)")
        }
    }

    func disable() {
        enumQueue.async { [weak self] in
            guard let self, let h = self.handle,
                  let p = dlsym(h, "MTUnregisterContactFrameCallback") else { return }
            let unregister = unsafeBitCast(p, to: (@convention(c) (UnsafeMutableRawPointer?, MTContactCallback?) -> Int32).self)
            self.active = false
            self.timer?.cancel()
            self.timer = nil
            for key in self.registered {
                let dev = UnsafeMutableRawPointer(bitPattern: key)
                _ = unregister(dev, self.callbackRef)
            }
            self.registered.removeAll()
            self.known.removeAll()
            appLog("MTS devices unregistered")
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: enumQueue)
        t.schedule(deadline: .now() + 10, repeating: 10)
        t.setEventHandler { [weak self] in self?.probe() }
        t.resume()
        self.timer = t
    }

    private func probe() {
        guard let h = handle,
              let p1 = dlsym(h, "MTDeviceCreateList") else { return }
        let createList = unsafeBitCast(p1, to: (@convention(c) () -> CFMutableArray?).self)
        guard let list = createList() else { return }
        if active { setActive(true) }
        let n = CFArrayGetCount(list)
        for i in 0..<n {
            let dev = unsafeBitCast(CFArrayGetValueAtIndex(list, i), to: UnsafeMutableRawPointer.self)
            known.insert(UInt(bitPattern: dev))
        }
    }
}