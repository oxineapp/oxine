import AppKit
import Foundation
import IOKit.ps

/// Sear as an app: a footer toggle with a level menu, a settings pane, and the
/// rules that keep a 1000-nit screen from cooking the battery — off on battery
/// if you ask for that, and always off once the Mac reports it's running hot.
@MainActor
final class SearAppBackend: InternalAppBackend {
    private static let suite = UserDefaults(suiteName: "com.oxine.settings")
    private static let keys = ["mode", "boost", "dim", "offOnBattery"].map { "sear.\($0)" }

    enum Mode: String { case off, boost, dim }

    private struct Config: Equatable {
        var mode = Mode.off
        /// What the footer click goes back to.
        var lastActive = Mode.boost
        /// 0…1 of the way from normal to the boost ceiling / the dim floor.
        var boost = 0.6
        var dim = 0.5
        var offOnBattery = false
    }

    private let engine = SearEngine()
    private var config = Config() { didSet { if config != oldValue { Self.save(config); apply() } } }
    private var observers: [NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?
    /// Why the engine is being held off right now, if it is.
    private var held: String?

    static func resetSettings() { keys.forEach { suite?.removeObject(forKey: $0) } }

    private static func load() -> Config {
        var c = Config()
        guard let d = suite else { return c }
        if let m = d.string(forKey: "sear.mode").flatMap(Mode.init(rawValue:)) { c.mode = m; if m != .off { c.lastActive = m } }
        if let v = d.object(forKey: "sear.boost") as? Double, v.isFinite { c.boost = min(max(v, 0.05), 1) }
        if let v = d.object(forKey: "sear.dim") as? Double, v.isFinite { c.dim = min(max(v, 0.05), 1) }
        c.offOnBattery = d.bool(forKey: "sear.offOnBattery")
        return c
    }

    private static func save(_ c: Config) {
        suite?.set(c.mode.rawValue, forKey: "sear.mode")
        suite?.set(c.boost, forKey: "sear.boost")
        suite?.set(c.dim, forKey: "sear.dim")
        suite?.set(c.offOnBattery, forKey: "sear.offOnBattery")
    }

    override func receive(_ msg: HostMessage) {
        switch msg {
        case .hello:
            config = Self.load()
            engine.onChange = { [weak self] in self?.push() }
            engine.start()
            observers.append(NotificationCenter.default.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.apply() } })
            observers.append(NotificationCenter.default.addObserver(
                forName: .searPowerSourceChanged, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.apply() } })
            if let source = IOPSNotificationCreateRunLoopSource({ _ in
                NotificationCenter.default.post(name: .searPowerSourceChanged, object: nil)
            }, nil)?.takeRetainedValue() {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
                powerSource = source
            }
            apply()
        case .event(let surface, let ref, let kind, let value):
            handle(surface: surface, ref: ref, kind: kind, value: value)
        case .bye:
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode) }
            powerSource = nil
            engine.stop()
        default: break
        }
    }

    private func handle(surface: String, ref: String?, kind: String, value: JSONValue?) {
        switch (surface, kind, ref) {
        case ("quickToggle", "tap", _):
            setMode(config.mode == .off ? config.lastActive : .off)
        case ("quickToggle", "menu", "off"), ("settings", "tap", "off"):
            setMode(.off)
        case ("quickToggle", "menu", let id?) where id.hasPrefix("b:"):
            if let v = Double(id.dropFirst(2)) { config.boost = v; setMode(.boost) }
        case ("quickToggle", "menu", let id?) where id.hasPrefix("d:"):
            if let v = Double(id.dropFirst(2)) { config.dim = v; setMode(.dim) }
        case ("settings", "change", "mode"):
            switch value?.stringValue {
            case "Brighter": setMode(.boost)
            case "Dimmer": setMode(.dim)
            default: setMode(.off)
            }
        case ("settings", "change", "boost"): config.boost = min(max(value?.numberValue ?? 0.6, 0.05), 1)
        case ("settings", "change", "dim"): config.dim = min(max(value?.numberValue ?? 0.5, 0.05), 1)
        case ("settings", "change", "offOnBattery"): config.offOnBattery = value?.boolValue ?? false
        default: break
        }
        push()
    }

    private func setMode(_ mode: Mode) {
        var c = config
        c.mode = mode
        if mode != .off { c.lastActive = mode }
        config = c
    }

    // MARK: Applying

    private var targetFactor: Double {
        switch config.mode {
        case .off: 1
        case .boost: 1 + config.boost * (SearEngine.boostCeiling - 1)
        case .dim: 1 - config.dim * (1 - SearEngine.dimFloor)
        }
    }

    private func apply() {
        held = nil
        if config.mode == .boost {
            // Heat is not optional: the panel and the SoC share a chassis, and
            // by "serious" the Mac is already throttling.
            let thermal = ProcessInfo.processInfo.thermalState
            if thermal == .serious || thermal == .critical { held = "Paused: the Mac is running hot" }
            else if config.offOnBattery, Self.onBattery { held = "Paused on battery" }
            else if !SearEngine.hasXDR { held = "No XDR display connected" }
        }
        engine.factor = held == nil ? targetFactor : 1
        push()
    }

    private static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }

    // MARK: Surfaces

    private func percent(_ factor: Double) -> String {
        let p = Int(((factor - 1) * 100).rounded())
        return p >= 0 ? "+\(p)%" : "\(p)%"
    }

    private func push() {
        let c = config
        let active = c.mode != .off && held == nil
        let icon: String = switch c.mode {
        case .dim: active ? "moon.fill" : "moon"
        default: active ? "sun.max.fill" : "sun.max"
        }
        var menu: [AppMenuItem] = []
        if SearEngine.hasXDR {
            menu += [0.25, 0.5, 0.75, 1].map { v in
                AppMenuItem(id: "b:\(v)", title: "Brighter \(percent(1 + v * (SearEngine.boostCeiling - 1)))",
                            checked: c.mode == .boost && abs(c.boost - v) < 0.01)
            }
            menu.append(AppMenuItem(divider: true))
        }
        menu += [0.25, 0.5, 0.75].map { v in
            AppMenuItem(id: "d:\(v)", title: "Dimmer \(percent(1 - v * (1 - SearEngine.dimFloor)))",
                        checked: c.mode == .dim && abs(c.dim - v) < 0.01)
        }
        menu += [AppMenuItem(divider: true), AppMenuItem(id: "off", title: "Off", checked: c.mode == .off)]
        emit(.toggle(active: active, icon: icon,
                     text: c.mode == .off ? nil : (held == nil ? percent(targetFactor) : "paused"),
                     menu: menu, warning: held != nil && c.mode != .off))

        var status: [AppNode] = [
            N.picker("mode", "Display", ["Normal", "Brighter", "Dimmer"],
                     c.mode == .boost ? "Brighter" : c.mode == .dim ? "Dimmer" : "Normal"),
            N.keyValue("Right now", c.mode == .off ? "Untouched" : (held ?? percent(targetFactor))),
        ]
        if !SearEngine.hasXDR {
            status.append(N.text("Brighter needs an XDR display: the 14- and 16-inch MacBook Pro from 2021 on, or a Pro Display XDR. Dimmer works on every display."))
        }
        emit(.view(surface: "settings", body: [
            N.section("Sear", status),
            N.section("Brighter", [
                N.slider("boost", "Boost", c.boost, 0.05...1, step: 0.05, text: percent(1 + c.boost * (SearEngine.boostCeiling - 1))),
                N.text("Opens the brightness macOS keeps back for HDR video and uses it for everything: up to about 1000 nits against the usual 500. Made for sunlight. It works on top of the brightness keys, so set those to full first."),
                N.toggle("offOnBattery", "Pause on battery power", c.offOnBattery),
                N.text("A brighter panel draws more power and makes more heat. Sear always pauses while the Mac reports it's running hot, and comes back by itself."),
            ]),
            N.section("Dimmer", [
                N.slider("dim", "Dim", c.dim, 0.05...1, step: 0.05, text: percent(1 - c.dim * (1 - SearEngine.dimFloor))),
                N.text("Darker than the lowest brightness step, for a dark room. Works on external displays too."),
            ]),
            N.section("Good to know", [
                N.text("Screenshots and recordings are unaffected: they capture the screen as if Sear were off. Nothing is changed in the system, so turning Sear off, or quitting Oxine, puts the display straight back."),
            ]),
        ]))
    }
}

private extension Notification.Name {
    static let searPowerSourceChanged = Notification.Name("oxine.sear.powerSourceChanged")
}
