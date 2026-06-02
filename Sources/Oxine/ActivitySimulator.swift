import AppKit
import CoreGraphics
import Foundation
import IOKit

/// Optional companion to Caffeine: when the system has been idle past a
/// threshold, post a real mouse-move HID event so status apps (Teams, Slack)
/// don't flip to "Away". Mirrors domzilla/Caffeine's ActivitySimulator.
///
/// A genuine CGEvent is required: CGWarpMouseCursorPosition does not reset
/// HIDIdleTime because it bypasses the HID layer. Posting events needs the
/// Accessibility permission, which the first post prompts for.
@MainActor
final class ActivitySimulator {
    static let shared = ActivitySimulator()

    private var timer: Timer?
    private let idleThreshold: TimeInterval = 90   // idle seconds before a nudge
    private let checkInterval: TimeInterval = 30    // how often to check

    private init() {}

    func start() {
        stop()
        let timer = Timer(timeInterval: checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAndSimulate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Post one event up front so macOS surfaces the Accessibility prompt when the
    /// feature is first switched on, rather than silently at the next idle window.
    func requestPermission() {
        simulate()
    }

    private func checkAndSimulate() {
        guard systemIdleTime() >= idleThreshold else { return }
        simulate()
    }

    /// Seconds since the last HID input, read from IOHIDSystem's HIDIdleTime.
    private func systemIdleTime() -> TimeInterval {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOHIDSystem"),
                                           &iterator) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }

        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return 0 }
        defer { IOObjectRelease(entry) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any],
              let idleNanos = dict["HIDIdleTime"] as? Int64 else { return 0 }

        return TimeInterval(idleNanos) / 1_000_000_000
    }

    /// Post a mouse-move at the current location: enough to reset the idle timer
    /// without actually moving the cursor anywhere.
    private func simulate() {
        let current = NSEvent.mouseLocation
        guard let screenHeight = NSScreen.main?.frame.height else { return }
        // NSEvent is bottom-left origin, CGEvent is top-left.
        let point = CGPoint(x: current.x, y: screenHeight - current.y)
        CGEvent(mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: point,
                mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }
}
