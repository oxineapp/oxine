import CoreGraphics
import Foundation
import ApplicationServices

final class FnState {
    private let lock = NSLock()
    private var _held = false
    private var _flags = CGEventFlags()

    var held: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _held
    }

    var flags: CGEventFlags {
        lock.lock()
        defer { lock.unlock() }
        return _flags
    }

    func setHeld(_ v: Bool) {
        lock.lock()
        _held = v
        lock.unlock()
    }

    func setFlags(_ v: CGEventFlags) {
        lock.lock()
        _flags = v
        lock.unlock()
    }
}

final class GestureEngine {
    let fnState: FnState
    let configManager: ConfigManager
    let debug: Bool

    // fired on real fn held<->released transitions (used to share the MTS callback)
    var onFnChanged: ((Bool) -> Void)?

    private func setFnHeld(_ v: Bool) {
        let old = fnState.held
        fnState.setHeld(v)
        if old != v {
            onFnChanged?(v)
        }
    }

    private var scrollDX = 0.0
    private var scrollDY = 0.0
    private var scrollFired = false
    private var lastScrollTime = 0.0
    private let scrollThreshold = 25.0
    private let rearmGap = 0.15

    private let mtQueue = DispatchQueue(label: "fngestures.mt")
    private var middleTaps: [UInt: ThreeFingerTapRecognizer] = [:]
    private var consumedButtons = Set<CGEventType>()
    private var mtStates: [UInt: MTState] = [:]

    private final class ContinuousState {
        var kind = ""
        var inverted = false
        var started = false
        var stepPixels = 30.0
        var stepsAccum = 0.0
        var lastScroll = 0.0
        var timer: DispatchSourceTimer?
    }

    private var continuousState: ContinuousState?
    private let contLock = NSLock()

    private struct MTState {
        var peakCount = 0
        var lastCount = 0
        var downAt = 0.0
        var baseline: [Int: (x: Float, y: Float)] = [:]
        var baselineCentroid: (x: Float, y: Float) = (0, 0)
        var baselineCount = 0
        var maxMoved: Float = 0
        var swiped = false
        var pinchBase: Float = 0
        var pinched = false
        var rotAccum = 0.0
        var lastAngle = 0.0
        var rotated = false
    }

    init(fnState: FnState, configManager: ConfigManager, debug: Bool) {
        self.fnState = fnState
        self.configManager = configManager
        self.debug = debug
    }

    func log(_ s: String) {
        if debug { appLog(s) }
    }

    // returns true if the event should be consumed
    func handle(type: CGEventType, event: CGEvent, swallow: Bool) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == ActionRunner.magic {
            return false
        }
        if type == .leftMouseUp || type == .rightMouseUp {
            let down: CGEventType = type == .leftMouseUp ? .leftMouseDown : .rightMouseDown
            return consumedButtons.remove(down) != nil
        }
        switch type {
        case .keyDown:
            let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            if code == 63 {
                setFnHeld(true)
                log("fn DOWN")
            } else {
                setFnHeld(event.flags.contains(.maskSecondaryFn))
            }
            fnState.setFlags(event.flags)
        case .keyUp:
            let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            if code == 63 {
                setFnHeld(false)
                log("fn UP")
            } else {
                setFnHeld(event.flags.contains(.maskSecondaryFn))
            }
            fnState.setFlags(event.flags)
        case .flagsChanged:
            let newHeld = event.flags.contains(.maskSecondaryFn)
            if fnState.held != newHeld {
                log("fn state -> \(newHeld) (flagsChanged)")
            }
            setFnHeld(newHeld)
            fnState.setFlags(event.flags)
        case .scrollWheel:
            if fnState.held && !event.flags.contains(.maskSecondaryFn) {
                setFnHeld(false)
                log("fn state healed (scroll event without fn flag)")
            }
            return handleScroll(event: event, swallow: swallow)
        case .leftMouseDown, .rightMouseDown:
            mtQueue.async {
                for device in self.middleTaps.keys { self.middleTaps[device]?.cancel() }
            }
            guard configManager.current.enabled, swallow else { return false }
            let name = type == .leftMouseDown ? "leftClick" : "rightClick"
            if fnState.held && !event.flags.contains(.maskSecondaryFn) {
                setFnHeld(false)
                log("fn state healed (mouse event without fn flag)")
            }
            let hasAction = configManager.hasAction(name: name, flags: event.flags)
            if debug {
                log("CLICK \(name) secFn=\(event.flags.contains(.maskSecondaryFn)) fnTracked=\(fnState.held) hasAction=\(hasAction)")
            }
            if (fnState.held || event.flags.contains(.maskSecondaryFn)), hasAction {
                log("gesture: \(name)")
                configManager.dispatch(name: name, flags: event.flags)
                consumedButtons.insert(type)
                return true
            }
        default:
            break
        }
        return false
    }

    private func handleScroll(event: CGEvent, swallow: Bool) -> Bool {
        if debug {
            let a1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            let a2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
            let p1 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
            let p2 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
            let mom = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
            log("RAWSCROLL a1=\(a1) a2=\(a2) p1=\(p1) p2=\(p2) mom=\(mom) secFn=\(event.flags.contains(.maskSecondaryFn)) fnTracked=\(fnState.held) fired=\(scrollFired) acc=(\(scrollDX),\(scrollDY))")
        }
        guard configManager.current.enabled, configManager.hasScrollGestures() else {
            scrollDX = 0
            scrollDY = 0
            scrollFired = false
            disengageContinuous()
            log("SCROLL ignored: enabled=\(configManager.current.enabled) hasScroll=\(configManager.hasScrollGestures()) gestures=\(configManager.current.gestures.filter { $0.gesture.hasPrefix("scroll") }.count)")
            return false
        }
        let fnActive = fnState.held || event.flags.contains(.maskSecondaryFn)
        let now = Date().timeIntervalSinceReferenceDate
        if !fnActive {
            scrollDX = 0
            scrollDY = 0
            scrollFired = false
            disengageContinuous()
            log("SCROLL ignored: fn not active")
            return false
        }
        let momentum = UInt64(event.getIntegerValueField(.scrollWheelEventMomentumPhase))
        var dx = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        var dy = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        if dx == 0 && dy == 0 {
            dx = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)) * 10
            dy = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) * 10
        }
        let prevScrollTime = lastScrollTime
        lastScrollTime = now
        if let binding = configManager.continuousVerticalBinding() {
            return handleContinuousScroll(dx: dx, dy: dy, momentum: momentum,
                                          binding: binding, now: now, swallow: swallow,
                                          natural: configManager.current.naturalScroll,
                                          flags: event.flags, prevScrollTime: prevScrollTime)
        }
        let natural = configManager.current.naturalScroll
        if scrollFired {
            if momentum == 0 && now - prevScrollTime > rearmGap {
                scrollFired = false
                scrollDX = 0
                scrollDY = 0
            }
            return swallow
        }
        scrollDX += dx
        scrollDY += dy
        let ex = natural ? -scrollDX : scrollDX
        let ey = natural ? -scrollDY : scrollDY
        let name: String = abs(ey) >= abs(ex)
            ? (ey > 0 ? "scrollUp" : "scrollDown")
            : (ex < 0 ? "scrollLeft" : "scrollRight")
        let sens = configManager.sensitivity(for: name, flags: event.flags)
        if max(abs(scrollDX), abs(scrollDY)) < scrollThreshold / sens {
            if debug { log("SCROLL below threshold: \(name) acc=(\(scrollDX),\(scrollDY))") }
            return false
        }
        scrollDX = 0
        scrollDY = 0
        scrollFired = true
        log("scroll gesture: \(name)")
        configManager.dispatch(name: name, flags: event.flags)
        return swallow
    }

    // MARK: continuous scroll (smooth volume/brightness)

    private func handleContinuousScroll(dx: Double, dy: Double, momentum: UInt64,
                                        binding: (inverted: Bool, kind: String),
                                        now: Double, swallow: Bool, natural: Bool,
                                        flags: CGEventFlags, prevScrollTime: Double) -> Bool {
        contLock.lock()
        if continuousState == nil || continuousState!.kind != binding.kind
            || continuousState!.inverted != binding.inverted {
            let c = ContinuousState()
            c.kind = binding.kind
            c.inverted = binding.inverted
            continuousState = c
        }
        let c = continuousState!
        if momentum == 0 {
            if abs(dy) >= abs(dx) {
                // vertical: continuous volume/brightness
                scrollDX = 0
                let effDy = (natural ? -dy : dy) * (c.inverted ? -1 : 1)
                if abs(effDy) > 0.5 {
                    if !c.started {
                        c.started = true
                        let name = c.inverted ? "scrollDown" : "scrollUp"
                        let sens = configManager.sensitivity(for: name, flags: flags)
                        c.stepPixels = (c.kind == "scrollVolume" ? 30.0 : 40.0) / sens
                        startContinuousTimer(c)
                    }
                    c.stepsAccum += effDy
                    c.lastScroll = now
                }
            } else {
                // horizontal: one-shot gesture
                scrollDX += dx
                let sens = configManager.sensitivity(for: "scrollLeft", flags: flags)
                if abs(scrollDX) >= scrollThreshold / sens && !scrollFired {
                    let ex = natural ? -scrollDX : scrollDX
                    let name = ex < 0 ? "scrollLeft" : "scrollRight"
                    let s2 = configManager.sensitivity(for: name, flags: flags)
                    if abs(scrollDX) < scrollThreshold / s2 {
                        c.lastScroll = now
                        contLock.unlock()
                        return swallow
                    }
                    scrollDX = 0
                    scrollFired = true
                    log("scroll gesture: \(name)")
                    configManager.dispatch(name: name, flags: flags)
                }
            }
        }
        contLock.unlock()

        if scrollFired && momentum == 0 && now - prevScrollTime > rearmGap {
            scrollFired = false
            scrollDX = 0
        }
        return swallow
    }

    private func startContinuousTimer(_ c: ContinuousState) {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        t.schedule(deadline: .now() + 0.08, repeating: 0.08)
        t.setEventHandler { [weak self] in self?.continuousTick(c) }
        t.resume()
        c.timer = t
    }

    private func continuousTick(_ c: ContinuousState) {
        contLock.lock()
        let now = Date().timeIntervalSinceReferenceDate
        if now - c.lastScroll > 1.0 {
            c.timer?.cancel()
            c.timer = nil
            continuousState = nil
            contLock.unlock()
            return
        }
        let kind = c.kind
        let step = c.stepPixels
        var steps = Int(c.stepsAccum / step)
        if steps != 0 {
            c.stepsAccum -= Double(steps) * step
            steps = max(-3, min(3, steps))
        }
        contLock.unlock()
        if steps > 0 {
            log("continuous step +\(steps) (\(kind))")
            ActionRunner.postNX(kind == "scrollVolume" ? 0 : 2)
        } else if steps < 0 {
            log("continuous step \(steps) (\(kind))")
            ActionRunner.postNX(kind == "scrollVolume" ? 1 : 3)
        }
    }

    private func disengageContinuous() {
        contLock.lock()
        if let c = continuousState {
            c.timer?.cancel()
            c.timer = nil
            continuousState = nil
        }
        contLock.unlock()
    }

    // MARK: multi-touch

    func mtFrame(device: UInt, touches: [Multitouch.Touch]) {
        mtQueue.async { self.processMT(device: device, touches: touches) }
    }

    private func fireMT(_ name: String) {
        log("mt gesture: \(name)")
        configManager.dispatch(name: name, flags: fnState.flags)
    }

    private func processMT(device: UInt, touches: [Multitouch.Touch]) {
        var st = mtStates[device] ?? MTState()
        let now = Date().timeIntervalSinceReferenceDate
        let dict = Dictionary(uniqueKeysWithValues: touches.map { ($0.id, (x: $0.x, y: $0.y)) })
        let count = dict.count
        let fn = fnState.held
        let cfg = configManager.current
        var middle = middleTaps[device] ?? ThreeFingerTapRecognizer()
        let middleEnabled = cfg.enabled && cfg.middleClick && !fn && AXIsProcessTrusted()
        if middle.update(touches: touches, time: now, enabled: middleEnabled) {
            ActionRunner.queue(.mouse("middle"))
        }
        middleTaps[device] = middle
        guard cfg.enabled && cfg.multitouch else { mtStates[device] = MTState(); return }

        if st.lastCount > 0 && count == 0 {
            let dur = now - st.downAt
            if debug {
                log("TAP candidate: fingers=\(st.lastCount) dur=\(String(format: "%.3f", dur)) moved=\(String(format: "%.3f", st.maxMoved)) fn=\(fn)")
            }
            if st.peakCount <= 3 && dur < 0.25 && st.maxMoved < 0.025 && !st.swiped && !st.pinched && !st.rotated && fn {
                let name = st.peakCount == 1 ? "oneFingerTap"
                    : (st.peakCount == 2 ? "twoFingerTap" : "threeFingerTap")
                fireMT(name)
            }
            st = MTState()
        } else if count > 0 && st.lastCount == 0 {
            st = resetBaseline(now: now, dict: dict)
        } else if count == st.baselineCount && count > 0 {
            updateMaxMoved(&st, dict: dict)
            let cen = centroid(dict)
            let dx = cen.x - st.baselineCentroid.x
            let dy = cen.y - st.baselineCentroid.y
            let inv = cfg.invertSwipes
            if !st.swiped && (count == 3 || count == 4) && fn {
                let v = inv ? -dy : dy
                let dir: String = abs(v) >= abs(dx) ? (v > 0 ? "Up" : "Down") : (dx > 0 ? "Right" : "Left")
                let name = "\(count == 3 ? "threeFingerSwipe" : "fourFingerSwipe")\(dir)"
                let sens = configManager.sensitivity(for: name)
                if Double(abs(dx)) > 0.25 / sens || Double(abs(dy)) > 0.25 / sens {
                    st.swiped = true
                    fireMT(name)
                }
            }
            if count == 2 && fn {
                let d = distance(dict)
                if !st.pinched && st.pinchBase > 0.02 {
                    let r = d / st.pinchBase
                    let name = r < 1 ? "pinchIn" : "pinchOut"
                    let sens = configManager.sensitivity(for: name)
                    let threshold = Float(0.2 / sens)
                    if r < 1 - threshold || r > 1 + threshold {
                        st.pinched = true
                        fireMT(name)
                    }
                }
                if !st.rotated {
                    let a = angle(dict)
                    var da: Double = a - st.lastAngle
                    if da > Double.pi { da -= 2 * Double.pi }
                    if da < -Double.pi { da += 2 * Double.pi }
                    st.rotAccum += da
                    let name = st.rotAccum > 0 ? "rotateRight" : "rotateLeft"
                    let sens = configManager.sensitivity(for: name)
                    if abs(st.rotAccum) > 0.6 / sens {
                        st.rotated = true
                        fireMT(name)
                    }
                    st.lastAngle = a
                }
            }
        } else if count > 0 {
            updateMaxMoved(&st, dict: dict)
            let previous = st
            st = resetBaseline(now: now, dict: dict)
            st.downAt = previous.downAt
            st.peakCount = max(previous.peakCount, count)
            st.maxMoved = previous.maxMoved
            st.swiped = previous.swiped
            st.pinched = previous.pinched
            st.rotated = previous.rotated
        }
        st.peakCount = max(st.peakCount, count)
        st.lastCount = count
        mtStates[device] = st
    }

    private func resetBaseline(now: Double, dict: [Int: (x: Float, y: Float)]) -> MTState {
        var st = MTState()
        st.downAt = now
        st.baseline = dict
        st.baselineCount = dict.count
        st.baselineCentroid = centroid(dict)
        st.maxMoved = 0
        st.swiped = false
        st.pinched = false
        st.rotated = false
        st.rotAccum = 0
        st.pinchBase = dict.count == 2 ? distance(dict) : 0
        st.lastAngle = dict.count == 2 ? angle(dict) : 0
        return st
    }

    private func updateMaxMoved(_ st: inout MTState, dict: [Int: (x: Float, y: Float)]) {
        for (id, p) in st.baseline {
            if let c = dict[id] {
                let dx = c.x - p.x
                let dy = c.y - p.y
                st.maxMoved = max(st.maxMoved, sqrt(dx * dx + dy * dy))
            }
        }
    }

    private func centroid(_ d: [Int: (x: Float, y: Float)]) -> (x: Float, y: Float) {
        guard !d.isEmpty else { return (0, 0) }
        var sx: Float = 0
        var sy: Float = 0
        for p in d.values {
            sx += p.x
            sy += p.y
        }
        return (sx / Float(d.count), sy / Float(d.count))
    }

    private func distance(_ d: [Int: (x: Float, y: Float)]) -> Float {
        let pts = d.keys.sorted().compactMap { d[$0] }
        guard pts.count == 2 else { return 0 }
        let dx = pts[0].x - pts[1].x
        let dy = pts[0].y - pts[1].y
        return sqrt(dx * dx + dy * dy)
    }

    private func angle(_ d: [Int: (x: Float, y: Float)]) -> Double {
        let pts = d.keys.sorted().compactMap { d[$0] }
        guard pts.count == 2 else { return 0 }
        return Double(atan2(pts[0].y - pts[1].y, pts[0].x - pts[1].x))
    }
}
