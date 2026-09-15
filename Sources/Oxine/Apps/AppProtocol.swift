import Foundation

/// The apps wire protocol: NDJSON, one message per line, discriminated by `t`.
/// App stdout → host (`AppMessage`), host → app stdin (`HostMessage`). This file
/// is the whole `api: 1` contract — additive changes only; breaking ones bump
/// `AppsProtocolVersion`. See APPS_DESIGN.md for the prose spec.

/// One entry in a quick-toggle's right-click menu.
struct AppMenuItem: Codable, Equatable, Sendable {
    var id: String?
    var title: String?
    var checked: Bool?
    var destructive: Bool?
    /// A divider row (id/title ignored).
    var divider: Bool?
}

/// Messages an app sends to the host.
enum AppMessage: Sendable {
    case ready
    /// Replace one surface's rendered tree.
    case view(surface: String, body: [AppNode])
    /// Quick-toggle state: icon/active drive the footer button, `text` is an
    /// optional live caption beside it (e.g. a countdown), `menu` the right-click.
    case toggle(active: Bool, icon: String?, text: String?, menu: [AppMenuItem]?)
    /// Bar-metric value (0…1) plus an optional short readout label.
    case metric(value: Double, text: String?)
    /// Request a transient notch peek. Rate-limited by the host.
    case peek(text: String, icon: String?)
    /// Capability call; host answers with `.ret` carrying the same id.
    case call(id: Int, fn: String, args: JSONValue?)
    /// Subscribe to a capability stream at ~hz (host clamps).
    case sub(cap: String, hz: Double?)
    case unsub(cap: String)
    /// Free-form log line (also lands in the app's log file).
    case log(String)

    /// Decode one NDJSON line. Unknown `t` returns nil (forward compatibility:
    /// newer apps may send messages an older host skips).
    static func decode(_ line: Data) -> AppMessage? {
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: line),
              let t = v["t"]?.stringValue else { return nil }
        switch t {
        case "ready": return .ready
        case "view":
            guard let surface = v["surface"]?.stringValue,
                  let bodyData = try? JSONEncoder().encode(v["body"] ?? .array([])),
                  let body = try? JSONDecoder().decode([AppNode].self, from: bodyData)
            else { return nil }
            return .view(surface: surface, body: body)
        case "toggle":
            var menu: [AppMenuItem]?
            if let m = v["menu"], let d = try? JSONEncoder().encode(m) {
                menu = try? JSONDecoder().decode([AppMenuItem].self, from: d)
            }
            return .toggle(active: v["active"]?.boolValue ?? false,
                           icon: v["icon"]?.stringValue,
                           text: v["text"]?.stringValue,
                           menu: menu)
        case "metric":
            return .metric(value: v["value"]?.numberValue ?? 0, text: v["text"]?.stringValue)
        case "peek":
            guard let text = v["text"]?.stringValue else { return nil }
            return .peek(text: text, icon: v["icon"]?.stringValue)
        case "call":
            guard let id = v["id"]?.numberValue, let fn = v["fn"]?.stringValue else { return nil }
            return .call(id: Int(id), fn: fn, args: v["args"])
        case "sub":
            guard let cap = v["cap"]?.stringValue else { return nil }
            return .sub(cap: cap, hz: v["hz"]?.numberValue)
        case "unsub":
            guard let cap = v["cap"]?.stringValue else { return nil }
            return .unsub(cap: cap)
        case "log":
            return .log(v["text"]?.stringValue ?? "")
        default:
            return nil
        }
    }
}

/// Messages the host sends to an app.
enum HostMessage: Sendable {
    case hello(granted: [String], dataDir: String)
    /// A user interaction on one of the app's surfaces. `ref` is the node id (or
    /// menu-item id); `kind` is "tap", "change", or "menu"; `value` carries the
    /// new value for "change".
    case event(surface: String, ref: String?, kind: String, value: JSONValue?)
    /// One tick of a subscribed capability stream.
    case cap(cap: String, data: JSONValue)
    /// Answer to a `.call`.
    case ret(id: Int, ok: Bool, data: JSONValue?, error: String?)
    /// Surface visibility: phase "activate"/"deactivate" — apps should idle
    /// their updates when nothing of theirs is on screen.
    case lifecycle(phase: String, surface: String?)
    case bye

    /// Encode as one NDJSON line (newline included).
    func encoded() -> Data {
        var obj: [String: JSONValue]
        switch self {
        case .hello(let granted, let dataDir):
            obj = ["t": .string("hello"),
                   "api": .number(Double(AppsProtocolVersion)),
                   "oxine": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"),
                   "granted": .array(granted.map { .string($0) }),
                   "dataDir": .string(dataDir)]
        case .event(let surface, let ref, let kind, let value):
            obj = ["t": .string("event"), "surface": .string(surface), "kind": .string(kind)]
            if let ref { obj["ref"] = .string(ref) }
            if let value { obj["value"] = value }
        case .cap(let cap, let data):
            obj = ["t": .string("cap"), "cap": .string(cap), "data": data]
        case .ret(let id, let ok, let data, let error):
            obj = ["t": .string("ret"), "id": .number(Double(id)), "ok": .bool(ok)]
            if let data { obj["data"] = data }
            if let error { obj["error"] = .string(error) }
        case .lifecycle(let phase, let surface):
            obj = ["t": .string("lifecycle"), "phase": .string(phase)]
            if let surface { obj["surface"] = .string(surface) }
        case .bye:
            obj = ["t": .string("bye")]
        }
        var data = (try? JSONEncoder().encode(JSONValue.object(obj))) ?? Data()
        data.append(0x0A)
        return data
    }
}
