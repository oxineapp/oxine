import CoreGraphics
import Foundation

struct Action: Codable {
    var type: String
    var command: String?
    var target: String?
    var kind: String?
    var key: String?
    var media: String?
    var button: String?
    var mods: [String] = []

    static func shell(_ cmd: String) -> Action { Action(type: "shell", command: cmd) }
    static func key(_ key: String, _ mods: [String]) -> Action { Action(type: "key", key: key, mods: mods) }
    static func media(_ key: String) -> Action { Action(type: "media", media: key) }
    static func open(_ target: String, kind: String? = nil) -> Action { Action(type: "open", target: target, kind: kind) }
    static func mouse(_ button: String) -> Action { Action(type: "mouse", button: button) }
}

extension Action {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        command = try? c.decode(String.self, forKey: .command)
        target = try? c.decode(String.self, forKey: .target)
        kind = try? c.decode(String.self, forKey: .kind)
        key = try? c.decode(String.self, forKey: .key)
        mods = (try? c.decode([String].self, forKey: .mods)) ?? []
        media = try? c.decode(String.self, forKey: .media)
        button = try? c.decode(String.self, forKey: .button)
    }
}

struct GestureEntry: Codable {
    var gesture: String
    var modifiers: [String]
    var action: Action?
    var sensitivity: Double?

    init(gesture: String, modifiers: [String] = [], action: Action? = nil, sensitivity: Double? = nil) {
        self.gesture = gesture
        self.modifiers = modifiers
        self.action = action
        self.sensitivity = sensitivity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gesture = try c.decode(String.self, forKey: .gesture)
        modifiers = try c.decodeIfPresent([String].self, forKey: .modifiers) ?? []
        action = try c.decodeIfPresent(Action.self, forKey: .action)
        if let d = try? c.decode(Double.self, forKey: .sensitivity) {
            sensitivity = d
        } else if let i = try? c.decode(Int.self, forKey: .sensitivity) {
            sensitivity = Double(i)
        } else {
            sensitivity = nil
        }
    }
}

struct Config: Codable {
    var enabled: Bool
    var swallowScroll: Bool
    var naturalScroll: Bool
    var invertSwipes: Bool
    var multitouch: Bool
    var middleClick: Bool = true
    var gestures: [GestureEntry]

    init(enabled: Bool = true, swallowScroll: Bool = true, naturalScroll: Bool = false,
         invertSwipes: Bool = false, multitouch: Bool = true, gestures: [GestureEntry] = []) {
        self.enabled = enabled
        self.swallowScroll = swallowScroll
        self.naturalScroll = naturalScroll
        self.invertSwipes = invertSwipes
        self.multitouch = multitouch
        self.gestures = gestures
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        swallowScroll = try c.decodeIfPresent(Bool.self, forKey: .swallowScroll) ?? true
        naturalScroll = try c.decodeIfPresent(Bool.self, forKey: .naturalScroll) ?? false
        invertSwipes = try c.decodeIfPresent(Bool.self, forKey: .invertSwipes) ?? false
        middleClick = try c.decodeIfPresent(Bool.self, forKey: .middleClick) ?? true
        multitouch = try c.decodeIfPresent(Bool.self, forKey: .multitouch) ?? true
        gestures = try c.decodeIfPresent([GestureEntry].self, forKey: .gestures) ?? []
    }
}

final class ConfigManager {
    let url: URL
    private let lock = NSLock()
    private var _current: Config
    var lastError: String?

    var current: Config {
        lock.lock()
        defer { lock.unlock() }
        return _current
    }

    init(url: URL) {
        self.url = url
        _current = Config()
        load()
    }

    func load() {
        lock.lock()
        defer { lock.unlock() }
        do {
            let data = try Data(contentsOf: url)
            _current = try JSONDecoder().decode(Config.self, from: data)
            lastError = nil
            appLog("config loaded: \(url.path)")
        } catch {
            let ns = error as NSError
            appLog("config load failed: domain=\(ns.domain) code=\(ns.code) exists=\(FileManager.default.fileExists(atPath: url.path)) path=\(url.path)")
            lastError = "\(error.localizedDescription)"
            if !FileManager.default.fileExists(atPath: url.path) {
                _current = defaultConfig()
                writeLocked()
                appLog("default config written: \(url.path)")
            } else {
                appLog("config parse error: \(error.localizedDescription) (keeping defaults)")
            }
        }
    }

    func reload() {
        lock.lock()
        defer { lock.unlock() }
        if let data = try? Data(contentsOf: url),
           let cfg = try? JSONDecoder().decode(Config.self, from: data) {
            _current = cfg
            lastError = nil
            appLog("config reloaded")
        } else {
            lastError = "failed to parse config, keeping current"
            appLog("config reload failed")
        }
    }

    func toggleEnabled() {
        lock.lock()
        _current.enabled.toggle()
        writeLocked()
        lock.unlock()
    }

    func apply(_ cfg: Config) {
        lock.lock()
        _current = cfg
        writeLocked()
        lock.unlock()
        appLog("config applied")
    }

    func mutate(_ f: (inout Config) -> Void) {
        lock.lock()
        f(&_current)
        writeLocked()
        lock.unlock()
    }

    // scrollUp/scrollDown bound to scrollVolume/scrollBrightness => continuous vertical scroll
    func continuousVerticalBinding() -> (inverted: Bool, kind: String)? {
        let cfg = current
        guard cfg.enabled else { return nil }
        for e in cfg.gestures {
            guard let a = e.action else { continue }
            if (a.type == "scrollVolume" || a.type == "scrollBrightness")
                && (e.gesture == "scrollUp" || e.gesture == "scrollDown") {
                return (inverted: e.gesture == "scrollDown", kind: a.type)
            }
        }
        return nil
    }

    func sensitivity(for gesture: String, flags: CGEventFlags) -> Double {
        let cfg = current
        let wanted = modNames(flags)
        for e in cfg.gestures where e.gesture == gesture && Set(e.modifiers) == wanted {
            return max(0.1, e.sensitivity ?? 1.0)
        }
        return 1.0
    }

    func sensitivity(for gesture: String) -> Double {
        let cfg = current
        for e in cfg.gestures where e.gesture == gesture && e.modifiers.isEmpty {
            return max(0.1, e.sensitivity ?? 1.0)
        }
        return 1.0
    }

    func setSensitivity(gesture: String, sensitivity: Double) {
        mutate { cfg in
            for i in cfg.gestures.indices where cfg.gestures[i].gesture == gesture && cfg.gestures[i].modifiers.isEmpty {
                cfg.gestures[i].sensitivity = sensitivity
                return
            }
            cfg.gestures.append(GestureEntry(gesture: gesture, modifiers: [], action: nil, sensitivity: sensitivity))
        }
    }

    private func writeLocked() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(_current) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    func dispatch(name: String, flags: CGEventFlags) {
        let cfg = current
        guard cfg.enabled else { return }
        let wanted = modNames(flags)
        for entry in cfg.gestures where entry.gesture == name {
            if Set(entry.modifiers) == wanted {
                if let action = entry.action {
                    appLog("dispatch: \(name) -> \(action.type) \(action.media ?? action.key ?? action.command ?? action.target ?? "")")
                    ActionRunner.queue(action)
                }
                return
            }
        }
    }

    func hasAction(name: String, flags: CGEventFlags) -> Bool {
        let cfg = current
        guard cfg.enabled else { return false }
        let wanted = modNames(flags)
        return cfg.gestures.contains {
            $0.gesture == name && Set($0.modifiers) == wanted && $0.action != nil
        }
    }

    func hasScrollGestures() -> Bool {
        let cfg = current
        return cfg.enabled && cfg.gestures.contains { $0.gesture.hasPrefix("scroll") && $0.action != nil }
    }

    private func modNames(_ flags: CGEventFlags) -> Set<String> {
        var s = Set<String>()
        if flags.contains(.maskCommand) { s.insert("cmd") }
        if flags.contains(.maskShift) { s.insert("shift") }
        if flags.contains(.maskAlternate) { s.insert("alt") }
        if flags.contains(.maskControl) { s.insert("ctrl") }
        return s
    }

    private func defaultConfig() -> Config {
        let g: [(String, Action?)] = [
            ("scrollUp", Action(type: "scrollVolume")),
            ("scrollDown", nil),
            ("scrollLeft", .media("previous")),
            ("scrollRight", .media("next")),
            ("threeFingerSwipeUp", .media("playPause")),
            ("threeFingerSwipeDown", .media("mute")),
            ("threeFingerSwipeLeft", .key("[", ["cmd"])),
            ("threeFingerSwipeRight", .key("]", ["cmd"])),
            ("fourFingerSwipeUp", .media("brightnessUp")),
            ("fourFingerSwipeDown", .media("brightnessDown")),
            ("fourFingerSwipeLeft", .shell("open -a Terminal")),
            ("fourFingerSwipeRight", .shell("open ~")),
            ("pinchIn", .key("-", ["cmd"])),
            ("pinchOut", .key("=", ["cmd"])),
            ("rotateLeft", nil),
            ("rotateRight", nil),
            ("oneFingerTap", nil),
            ("twoFingerTap", nil),
            ("threeFingerTap", nil),
            ("leftClick", .mouse("middle")),
            ("rightClick", nil),
        ]
        return Config(
            enabled: true,
            swallowScroll: true,
            naturalScroll: detectNaturalScroll(),
            invertSwipes: false,
            multitouch: true,
            gestures: g.map { GestureEntry(gesture: $0.0, modifiers: [], action: $0.1) }
        )
    }

    private func detectNaturalScroll() -> Bool {
        let p = Process()
        p.launchPath = "/usr/bin/defaults"
        p.arguments = ["read", "-g", "com.apple.swipescrolldirection"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }
}
