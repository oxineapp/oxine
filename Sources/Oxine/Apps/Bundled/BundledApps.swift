import Combine
import Foundation
import NotchKit

/// First-party apps that ship inside Oxine but are *installed* from the store
/// like anything else: they run in-process (they're ours, and they need deep
/// hooks — an overlay panel, an event tap) yet speak the real apps protocol
/// through `InternalAppBackend`, so their surfaces, footer slots and settings
/// panes are the same plumbing a third-party app gets. Not installed until the
/// user says so; uninstall stops them and wipes their settings.
enum BundledApps {
    struct Entry {
        let manifest: AppManifest
        let make: () -> InternalAppBackend
        /// Wipe the app's own saved state on uninstall.
        let onUninstall: () -> Void
    }

    @MainActor static var catalog: [Entry] {
        [
            Entry(manifest: AppManifest(
                id: "oxine.screenlyrics", name: "ScreenLyrics",
                tagline: "Live lyrics under the notch", icon: "quote.bubble",
                api: AppsProtocolVersion, minOxine: nil, run: nil,
                surfaces: .init(settings: .init(subtitle: "Size, font & timing"),
                                quickToggle: .init(icon: "quote.bubble", tooltip: "Lyrics under the notch", menu: true)),
                capabilities: [], osPermissions: nil, network: true,
                networkPurpose: "Asks lrclib.net for the synced lyrics of the song that's playing — title, artist, album and length go out, lyrics come back. Nothing else, no account."),
                  make: { ScreenLyricsAppBackend() },
                  onUninstall: { LyricsSettings.reset() }),
            Entry(manifest: AppManifest(
                id: "oxine.fngestures", name: "FnGestures",
                tagline: "Hold fn, scroll for volume, flick for tracks", icon: "hand.draw",
                api: AppsProtocolVersion, minOxine: nil, run: nil,
                surfaces: .init(settings: .init(subtitle: "Gestures & sensitivity"),
                                quickToggle: .init(icon: "hand.draw", tooltip: "fn gestures", menu: true)),
                capabilities: [], osPermissions: ["accessibility"], network: false),
                  make: { FnGesturesAppBackend() },
                  onUninstall: { FnGesturesAppBackend.resetSettings() }),
        ]
    }

    @MainActor static func entry(_ id: String) -> Entry? { catalog.first { $0.manifest.id == id } }
}

// MARK: - View-tree helpers

/// Tiny builders so the backends' settings trees read like the pane they draw.
enum N {
    static func node(_ type: String, id: String? = nil, _ props: [String: JSONValue] = [:], _ children: [AppNode]? = nil) -> AppNode {
        AppNode(type: type, id: id, props: props.isEmpty ? nil : props, children: children)
    }
    static func section(_ header: String, _ children: [AppNode]) -> AppNode { node("section", ["header": .string(header)], children) }
    static func text(_ text: String, style: String = "caption") -> AppNode { node("text", ["text": .string(text), "style": .string(style)]) }
    static func toggle(_ id: String, _ title: String, _ on: Bool) -> AppNode { node("toggle", id: id, ["title": .string(title), "on": .bool(on)]) }
    static func picker(_ id: String, _ title: String, _ options: [String], _ selected: String) -> AppNode {
        node("picker", id: id, ["title": .string(title), "options": .array(options.map { .string($0) }), "selected": .string(selected)])
    }
    static func slider(_ id: String, _ title: String, _ value: Double, _ range: ClosedRange<Double>, step: Double? = nil, text: String? = nil) -> AppNode {
        var p: [String: JSONValue] = ["title": .string(title), "value": .number(value),
                                      "min": .number(range.lowerBound), "max": .number(range.upperBound)]
        if let step { p["step"] = .number(step) }
        if let text { p["valueText"] = .string(text) }
        return node("slider", id: id, p)
    }
    static func button(_ id: String, _ title: String, destructive: Bool = false) -> AppNode {
        node("button", id: id, ["title": .string(title), "destructive": .bool(destructive)])
    }
    static func row(_ title: String, symbol: String? = nil, subtitle: String? = nil, value: String? = nil) -> AppNode {
        var p: [String: JSONValue] = ["title": .string(title)]
        if let symbol { p["symbol"] = .string(symbol) }
        if let subtitle { p["subtitle"] = .string(subtitle) }
        if let value { p["value"] = .string(value) }
        return node("row", p)
    }
    static func keyValue(_ key: String, _ value: String) -> AppNode { node("keyValueRow", ["key": .string(key), "value": .string(value)]) }
    static func stepper(_ id: String, _ title: String, _ value: Int, _ text: String) -> AppNode {
        node("stepper", id: id, ["title": .string(title), "value": .number(Double(value)), "valueText": .string(text)])
    }
}

// MARK: - ScreenLyrics

/// ScreenLyrics as an app. The overlay itself lives in NotchKit (it rides the
/// notch's player feed); this backend turns it on for the app's lifetime and
/// exposes every knob through the settings surface, plus a footer toggle that
/// is the same switch as the song-page button.
@MainActor
final class ScreenLyricsAppBackend: InternalAppBackend {
    private let defaults = NotchKit.settingsDefaults
    private var observer: NSObjectProtocol?
    private var lastPushed: LyricsSettings?

    override func receive(_ msg: HostMessage) {
        switch msg {
        case .hello:
            ScreenLyrics.shared.install()
            // The song-page button writes the same key; mirror it into the footer.
            observer = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.pushIfChanged() } }
            push()
        case .event(let surface, let ref, let kind, let value):
            handle(surface: surface, ref: ref, kind: kind, value: value)
        case .lifecycle(let phase, let surface):
            // Leaving the pane ends the preview so sample lines never linger.
            if phase == "deactivate", surface == "settings" { defaults.set(false, forKey: LyricsSettings.Key.preview) }
        case .bye:
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            defaults.set(false, forKey: LyricsSettings.Key.preview)
            ScreenLyrics.shared.uninstall()
        default: break
        }
    }

    private func handle(surface: String, ref: String?, kind: String, value: JSONValue?) {
        let K = LyricsSettings.Key.self
        let s = LyricsSettings.load()
        switch (surface, kind, ref) {
        case ("quickToggle", "tap", _):
            defaults.set(!(defaults.bool(forKey: K.enabled)), forKey: K.enabled)
        case ("quickToggle", "menu", "track"): defaults.set(!s.showTrack, forKey: K.showTrack)
        case ("quickToggle", "menu", "off"): defaults.set(false, forKey: K.enabled)
        case ("settings", "tap", "reset"): LyricsSettings.reset()
        case ("settings", "change", "size"):
            let v = min(max(Int((value?.numberValue ?? 1).rounded()), LyricsSettings.Range.size.lowerBound), LyricsSettings.Range.size.upperBound)
            defaults.set(v, forKey: K.size)
        case ("settings", "change", let id?):
            switch id {
            case "enabled": defaults.set(value?.boolValue ?? false, forKey: K.enabled)
            case "showTrack": defaults.set(value?.boolValue ?? true, forKey: K.showTrack)
            case "font":
                if let f = LyricsSettings.FontFamily.allCases.first(where: { $0.label == value?.stringValue }) {
                    defaults.set(f.rawValue, forKey: K.fontFamily)
                }
            case "appearance":
                if let a = LyricsSettings.Appearance.allCases.first(where: { $0.label == value?.stringValue }) {
                    defaults.set(a.rawValue, forKey: K.appearance)
                }
            case "duration": defaults.set(value?.numberValue ?? 0.35, forKey: K.animationDuration)
            case "timing": defaults.set(((value?.numberValue ?? 0) * 10).rounded() / 10, forKey: K.timing)
            case "gap": defaults.set(value?.numberValue ?? 4, forKey: K.gap)
            default: break
            }
        default: break
        }
        push()
    }

    private func pushIfChanged() {
        if LyricsSettings.load() != lastPushed { push() }
    }

    private func push() {
        let s = LyricsSettings.load()
        lastPushed = s
        emit(.toggle(active: s.enabled,
                     icon: s.enabled ? "quote.bubble.fill" : "quote.bubble",
                     text: nil,
                     menu: [
                        AppMenuItem(id: "track", title: "Show artist & song", checked: s.showTrack),
                        AppMenuItem(divider: true),
                        AppMenuItem(id: "off", title: "Turn off", destructive: true),
                     ]))
        emit(.view(surface: "settings", body: tree(s)))
    }

    private static let sizeNames = ["Tiny", "Extra small", "Small", "Medium", "Large", "Extra large", "Huge"]

    private func tree(_ s: LyricsSettings) -> [AppNode] {
        [
            N.section("Lyrics", [
                N.toggle("enabled", "Show lyrics under the notch", s.enabled),
                N.text("Synced lyrics come from LRCLIB using the song, artist, album and duration — no account. Not every recording has them. The pill hides while the notch is open and lets clicks pass through."),
                N.toggle("showTrack", "Show artist and song", s.showTrack),
                N.text("A second, smaller line under the lyric. Off keeps the pill to the words alone."),
            ]),
            N.section("Size", [
                N.slider("size", "Size", Double(s.size), 0...6, step: 1,
                         text: "\(s.size) · \(Self.sizeNames[s.size])"),
                N.text("Seven steps. Text, padding, corners and the pill's width scale together."),
                N.slider("gap", "Distance below notch", s.gap, LyricsSettings.Range.gap, step: 1, text: "\(Int(s.gap)) pt"),
            ]),
            N.section("Text", [
                N.picker("font", "Font", LyricsSettings.FontFamily.allCases.map(\.label), s.fontFamily.label),
                N.picker("appearance", "Line change", LyricsSettings.Appearance.allCases.map(\.label), s.appearance.label),
            ] + (s.appearance == .none ? [] : [
                N.slider("duration", "Speed", s.animationDuration, LyricsSettings.Range.animationDuration, step: 0.05,
                         text: String(format: "%.2f s", s.animationDuration)),
                N.text("Respects Reduce Motion."),
            ])),
            N.section("Timing", [
                N.slider("timing", "Offset", s.timing, LyricsSettings.Range.timing, step: 0.1,
                         text: String(format: "%+.1f s", s.timing)),
                N.text("Positive shows lines earlier, negative later. Fixes a lyric file that runs slightly off."),
            ]),
            N.section("Reset", [N.button("reset", "Reset ScreenLyrics", destructive: true)]),
        ]
    }
}

// MARK: - FnGestures

/// FnGestures as an app: the engine is the whole feature; this backend owns it
/// for the app's lifetime, persists its config, and draws the settings pane
/// (with the Accessibility status up top, since nothing works without it).
@MainActor
final class FnGesturesAppBackend: InternalAppBackend {
    private static let suite = UserDefaults(suiteName: "com.oxine.settings")
    private static let keys = ["enabled", "vertical", "horizontal", "sensitivity", "swallow", "invert"].map { "fngestures.\($0)" }

    private let engine = FnGestureEngine()
    private var config: FnGestureEngine.Config {
        didSet { engine.config = config; Self.save(config); push() }
    }

    override init() {
        config = Self.load()
        super.init()
        engine.config = config
    }

    static func resetSettings() { keys.forEach { suite?.removeObject(forKey: $0) } }

    private static func load() -> FnGestureEngine.Config {
        var c = FnGestureEngine.Config()
        guard let d = suite else { return c }
        if let v = d.object(forKey: "fngestures.enabled") as? Bool { c.enabled = v }
        if let v = d.string(forKey: "fngestures.vertical").flatMap(FnGestureEngine.Config.Vertical.init(rawValue:)) { c.vertical = v }
        if let v = d.string(forKey: "fngestures.horizontal").flatMap(FnGestureEngine.Config.Horizontal.init(rawValue:)) { c.horizontal = v }
        if let v = d.object(forKey: "fngestures.sensitivity") as? Double, v.isFinite { c.sensitivity = min(max(v, 0.5), 2) }
        if let v = d.object(forKey: "fngestures.swallow") as? Bool { c.swallowScroll = v }
        if let v = d.object(forKey: "fngestures.invert") as? Bool { c.invert = v }
        return c
    }

    private static func save(_ c: FnGestureEngine.Config) {
        guard let d = suite else { return }
        d.set(c.enabled, forKey: "fngestures.enabled")
        d.set(c.vertical.rawValue, forKey: "fngestures.vertical")
        d.set(c.horizontal.rawValue, forKey: "fngestures.horizontal")
        d.set(c.sensitivity, forKey: "fngestures.sensitivity")
        d.set(c.swallowScroll, forKey: "fngestures.swallow")
        d.set(c.invert, forKey: "fngestures.invert")
    }

    override func receive(_ msg: HostMessage) {
        switch msg {
        case .hello:
            engine.onStatusChanged = { [weak self] _ in self?.push() }
            engine.start()
            push()
        case .event(let surface, let ref, let kind, let value):
            handle(surface: surface, ref: ref, kind: kind, value: value)
        case .bye:
            engine.stop()
        default: break
        }
    }

    private func handle(surface: String, ref: String?, kind: String, value: JSONValue?) {
        switch (surface, kind, ref) {
        case ("quickToggle", "tap", _), ("settings", "change", "enabled"):
            config.enabled = kind == "tap" ? !config.enabled : (value?.boolValue ?? false)
        case ("quickToggle", "menu", let id?) where id.hasPrefix("v:"):
            if let v = FnGestureEngine.Config.Vertical(rawValue: String(id.dropFirst(2))) { config.vertical = v }
        case ("settings", "tap", "grant"):
            FnGestureEngine.requestAccessibility()
        case ("settings", "change", "vertical"):
            if let v = FnGestureEngine.Config.Vertical.allCases.first(where: { $0.label == value?.stringValue }) { config.vertical = v }
        case ("settings", "change", "horizontal"):
            if let v = FnGestureEngine.Config.Horizontal.allCases.first(where: { $0.label == value?.stringValue }) { config.horizontal = v }
        case ("settings", "change", "sensitivity"):
            config.sensitivity = min(max(value?.numberValue ?? 1, 0.5), 2)
        case ("settings", "change", "swallow"):
            config.swallowScroll = value?.boolValue ?? true
        case ("settings", "change", "invert"):
            config.invert = value?.boolValue ?? false
        default: break
        }
    }

    private func push() {
        let c = config
        let status = engine.status
        let active = c.enabled && status == .ready
        emit(.toggle(active: active,
                     icon: active ? "hand.draw.fill" : "hand.draw",
                     text: c.enabled && status == .needsAccessibility ? "no access" : nil,
                     menu: FnGestureEngine.Config.Vertical.allCases.map {
                        AppMenuItem(id: "v:\($0.rawValue)", title: "fn + scroll: \($0.label)", checked: c.vertical == $0)
                     },
                     warning: c.enabled && status == .needsAccessibility))
        var status1: [AppNode] = [
            N.toggle("enabled", "fn gestures", c.enabled),
            N.keyValue("Status", status.label),
        ]
        if c.enabled, status == .needsAccessibility {
            status1.append(N.text("Oxine needs Accessibility to watch the trackpad while fn is held and to send the volume, brightness and media keys. Grant it in System Settings → Privacy & Security → Accessibility."))
            status1.append(N.button("grant", "Grant Accessibility"))
        }
        emit(.view(surface: "settings", body: [
            N.section("Status", status1),
            N.section("Gestures", [
                N.picker("vertical", "fn + scroll up / down", FnGestureEngine.Config.Vertical.allCases.map(\.label), c.vertical.label),
                N.picker("horizontal", "fn + swipe left / right", FnGestureEngine.Config.Horizontal.allCases.map(\.label), c.horizontal.label),
                N.slider("sensitivity", "Sensitivity", c.sensitivity, 0.5...2, step: 0.1, text: String(format: "%.1f×", c.sensitivity)),
                N.toggle("invert", "Invert scroll direction", c.invert),
                N.toggle("swallow", "Keep the page from scrolling", c.swallowScroll),
                N.text("If pressing fn alone opens the emoji picker, set System Settings → Keyboard → “Press 🌐 key to” to Do Nothing."),
            ]),
        ]))
    }
}
