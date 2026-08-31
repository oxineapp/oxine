import Foundation

/// Recognizes a short, stationary three-finger contact, including staggered lifts.
/// A fourth finger, Fn, a physical click or swipe cancels the entire contact.
struct ThreeFingerTapRecognizer {
    private var started: Double?
    private var origins: [Int: (Float, Float)] = [:]
    private var peak = 0
    private var cancelled = false

    mutating func cancel() { cancelled = true }

    mutating func update(touches: [Multitouch.Touch], time: Double, enabled: Bool) -> Bool {
        if touches.isEmpty {
            let fire = enabled && !cancelled && peak == 3 && started.map { time - $0 <= 0.3 } == true
            self = Self()
            return fire
        }
        if started == nil { started = time }
        if !enabled { cancelled = true }
        peak = max(peak, touches.count)
        if peak > 3 { cancelled = true }
        for touch in touches {
            if let (x, y) = origins[touch.id] {
                if hypot(touch.x - x, touch.y - y) > 0.025 { cancelled = true }
            } else {
                origins[touch.id] = (touch.x, touch.y)
                if origins.count > 3 { cancelled = true }
            }
        }
        return false
    }
}
