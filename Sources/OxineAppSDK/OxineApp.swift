import Foundation

/// The app side of Oxine's app protocol (NDJSON over stdin/stdout; see
/// APPS_DESIGN.md): send views, calls and attention to the host, and run a
/// handler for each message it sends back. Everything runs on the main actor.
@MainActor
public enum OxineApp {
    private static var nextCall = 1
    private static var pending: [Int: ([String: Any]) -> Void] = [:]

    /// One message to the host.
    public static func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    /// Replace a surface's tree ("notchTab", "panelTab", "settings").
    public static func view(_ surface: String, _ body: [[String: Any]]) {
        send(["t": "view", "surface": surface, "body": body])
    }

    /// Who's waiting, as "#RRGGBB": the notch glows in their colors.
    public static func attention(_ colors: [String]) {
        send(["t": "attention", "colors": colors])
    }

    /// A capability call; `reply` gets the host's answer (`ok`, `data`, `error`).
    public static func call(_ fn: String, _ args: [String: Any] = [:], reply: (([String: Any]) -> Void)? = nil) {
        let id = nextCall
        nextCall += 1
        if let reply { pending[id] = reply }
        send(["t": "call", "id": id, "fn": fn, "args": args])
    }

    public static func log(_ text: String) { send(["t": "log", "text": text]) }

    /// Runs just before the app exits (the host said goodbye, went away, or
    /// terminated it): stop anything it started.
    public static var willExit: (@MainActor () -> Void)?

    private static func quit() {
        willExit?()
        exit(0)
    }

    private static var termination: DispatchSourceSignal?

    /// Later, on the main actor.
    public static func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            work()
        }
    }

    /// Read the host's messages until it says goodbye (or goes away), handing
    /// each to `handle` on the main actor. Answers to calls go to their reply.
    public static func run(_ handle: @escaping @MainActor ([String: Any]) -> Void) -> Never {
        // The host sends SIGTERM when goodbye wasn't enough.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { quit() } }
        source.resume()
        termination = source
        Thread {
            while let line = readLine() {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let data = line.data(using: .utf8),
                              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { return }
                        if message["t"] as? String == "ret", let id = message["id"] as? Int {
                            pending.removeValue(forKey: id)?(message)
                            return
                        }
                        if message["t"] as? String == "bye" { quit() }
                        handle(message)
                    }
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { quit() } }
        }.start()
        dispatchMain()
    }
}

/// One view node: a type, an optional id (events come back with it as
/// `ref`), props, children.
public func node(_ type: String, _ id: String? = nil, _ props: [String: Any] = [:],
                 _ children: [[String: Any]]? = nil) -> [String: Any] {
    var n: [String: Any] = ["type": type]
    if let id { n["id"] = id }
    if !props.isEmpty { n["props"] = props }
    if let children { n["children"] = children }
    return n
}

/// A person's color, the same every time for the same name or id: what
/// their avatar, bubbles, notices and the notch's glow use.
public func personColor(_ key: String) -> String {
    let hash = key.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value }
    let hue = Double(hash % 360) / 360
    // HSB (hue, 0.55, 0.95) → RGB.
    let s = 0.55, v = 0.95
    let i = Int(hue * 6) % 6, f = hue * 6 - Double(Int(hue * 6))
    let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
    let (r, g, b): (Double, Double, Double) = [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)][i]
    return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
}
