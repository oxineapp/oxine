import AppKit
import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac awake on demand (Caffeine in the footer). Modeled on
/// domzilla/Caffeine: holds a short, self-expiring IOKit power assertion that is
/// refreshed on a timer, so a wedged app can never pin the Mac awake forever.
/// Left-click starts at the saved default duration; right-click picks another
/// (which becomes the new default).
@MainActor
final class CaffeineManager: ObservableObject {
    static let shared = CaffeineManager()

    /// Whether the keep-awake assertion is currently held.
    @Published private(set) var isActive = false
    /// Seconds left on a timed session, or nil when running indefinitely. Updates
    /// once a second so the footer countdown stays live.
    @Published private(set) var remaining: TimeInterval?

    /// Selectable session lengths. `0` means indefinite (no auto-release).
    static let presets: [(label: String, seconds: TimeInterval)] = [
        ("15 minutes", 15 * 60),
        ("30 minutes", 30 * 60),
        ("1 hour", 60 * 60),
        ("2 hours", 2 * 60 * 60),
        ("5 hours", 5 * 60 * 60),
        ("Indefinitely", 0),
    ]

    /// Duration a plain click starts with. `0` == indefinite. Defaults to 1 hour.
    var defaultDuration: TimeInterval {
        get { UserDefaults.standard.object(forKey: "caffeineDefaultDuration") as? Double ?? 3600 }
        set { UserDefaults.standard.set(newValue, forKey: "caffeineDefaultDuration") }
    }

    /// Nudge the mouse when the system goes idle so chat apps stay "Available".
    var keepAppsActive: Bool {
        get { UserDefaults.standard.bool(forKey: "caffeineKeepAppsActive") }
        set {
            UserDefaults.standard.set(newValue, forKey: "caffeineKeepAppsActive")
            if newValue { ActivitySimulator.shared.requestPermission() }
            if isActive {
                newValue ? ActivitySimulator.shared.start() : ActivitySimulator.shared.stop()
            }
        }
    }

    // A short assertion (kAssertionTimeout) refreshed every kRefreshInterval. Both
    // mirror Caffeine: the timeout is the dead-man's switch, the refresh keeps it live.
    private let kAssertionTimeout: CFTimeInterval = 8
    private let kRefreshInterval: TimeInterval = 10

    private var assertionID: IOPMAssertionID?
    private var refreshTimer: Timer?
    private var displayTimer: Timer?
    private var endDate: Date?
    private var sessionActive = true

    private init() { observeWorkspace() }

    // MARK: - Control

    func toggle() {
        if isActive { stop() } else { start() }
    }

    /// Start (or restart) keeping the Mac awake. `duration` nil uses the saved
    /// default; a `0` duration runs indefinitely.
    func start(duration: TimeInterval? = nil) {
        let seconds = duration ?? defaultDuration
        startAssertionLoop()

        displayTimer?.invalidate()
        if seconds <= 0 {
            endDate = nil
            remaining = nil
        } else {
            endDate = Date().addingTimeInterval(seconds)
            remaining = seconds
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            displayTimer = timer
        }

        isActive = true
        if keepAppsActive { ActivitySimulator.shared.start() }
    }

    /// Pick a duration from the right-click menu: remember it as the new default
    /// and start running it straight away.
    func startAndSetDefault(_ seconds: TimeInterval) {
        defaultDuration = seconds
        start(duration: seconds)
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        displayTimer?.invalidate()
        displayTimer = nil
        endDate = nil
        remaining = nil
        releaseAssertion()
        ActivitySimulator.shared.stop()
        isActive = false
    }

    // MARK: - Display

    /// Compact countdown for the footer: "h:mm:ss", "m:ss", or "∞" when held open.
    var statusText: String {
        guard isActive else { return "" }
        guard let remaining else { return "∞" }
        let total = max(0, Int(remaining.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    // MARK: - Assertion lifecycle

    private func startAssertionLoop() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: kRefreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAssertion() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        refreshAssertion()
    }

    private func refreshAssertion() {
        // Skip while the user session is switched away; reacquire on return.
        guard sessionActive else { return }
        if let id = assertionID { IOPMAssertionRelease(id) }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithDescription(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            "Oxine is keeping your Mac awake" as CFString,
            nil, nil, nil,
            kAssertionTimeout,
            nil,
            &id
        )
        assertionID = (result == kIOReturnSuccess) ? id : nil
    }

    private func releaseAssertion() {
        if let id = assertionID { IOPMAssertionRelease(id) }
        assertionID = nil
    }

    private func tick() {
        guard let endDate else { return }
        let left = endDate.timeIntervalSinceNow
        if left <= 0 { stop() } else { remaining = left }
    }

    // MARK: - Workspace

    private func observeWorkspace() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessionActive = false }
        }
        nc.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sessionActive = true
                if self.isActive { self.refreshAssertion() }
            }
        }
        // Run-loop timers freeze during system sleep, so on wake re-check whether a
        // timed session already elapsed and deactivate promptly if so.
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }
}
