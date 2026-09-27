import AppKit
import Foundation
import NotchKit
import SousKit
import SwiftUI
import TemperKit
import UserNotifications

/// Ring 1: the host-brokered APIs an app can call or subscribe to, each gated by
/// that app's grants. This is the *only* door from an app into Oxine — nothing
/// here ever touches the Keychain, notes, or clipboard history (see
/// APPS_DESIGN.md, "Security model").
@MainActor
final class AppCapabilityBroker {
    static let shared = AppCapabilityBroker()

    /// Shared usage monitor for `system.usage` subscribers (2s cadence, cheap,
    /// started lazily on first subscription).
    private lazy var usage: SystemUsageMonitor = SystemUsageMonitor()
    private var usageStarted = false

    private init() {}

    // MARK: - Calls

    /// Handle a `.call`. `grants` is the caller's granted capability set;
    /// `userEventAt` the last time the user interacted with one of its surfaces
    /// (gates `openURL`). Returns (data, error).
    func call(fn: String, args: JSONValue?, appID: String, grants: Set<String>,
              userEventAt: Date?) -> (JSONValue?, String?) {
        // "storage.get" belongs to the "storage" grant, etc.
        let capability = fn.split(separator: ".").first.map(String.init) ?? fn
        guard grants.contains(capability) || capability == "storage" else {
            return (nil, "capability '\(capability)' not granted")
        }
        switch fn {
        case "storage.get":
            guard let key = args?["key"]?.stringValue else { return (nil, "missing key") }
            return (storageRead(appID: appID)[key] ?? .null, nil)
        case "storage.set":
            guard let key = args?["key"]?.stringValue else { return (nil, "missing key") }
            var kv = storageRead(appID: appID)
            kv[key] = args?["value"] ?? .null
            storageWrite(appID: appID, kv)
            return (.bool(true), nil)
        case "notify.post":
            if notchEnabled {
                postNotchNotice(appID: appID, args: args)
            } else {
                postNotification(appID: appID, title: args?["title"]?.stringValue ?? "",
                                 body: args?["body"]?.stringValue ?? "")
            }
            return (.bool(true), nil)
        case "notify.end":
            // Answered elsewhere (read on the phone): take its notice down.
            guard let key = args?["key"]?.stringValue else { return (nil, "missing key") }
            if let id = notices.removeValue(forKey: NoticeKey(app: appID, key: key)) {
                NotchNotices.shared.dismiss(id)
            }
            return (.bool(true), nil)
        case "openURL.open":
            guard let raw = args?["url"]?.stringValue, let url = URL(string: raw) else {
                return (nil, "bad url")
            }
            // Only in response to a recent user gesture on the app's surfaces —
            // background processes don't get to pop browsers.
            guard let at = userEventAt, Date().timeIntervalSince(at) < 10 else {
                return (nil, "openURL requires a recent user interaction")
            }
            guard url.scheme == "https" || url.scheme == "http" else {
                return (nil, "unsupported scheme")
            }
            NSWorkspace.shared.open(url)
            return (.bool(true), nil)
        case "clipboard.write":
            guard let text = args?["text"]?.stringValue else { return (nil, "missing text") }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return (.bool(true), nil)
        case "clipboard.read":
            return (.string(NSPasteboard.general.string(forType: .string) ?? ""), nil)
        default:
            return (nil, "unknown function '\(fn)'")
        }
    }

    // MARK: - Streams

    /// Streamable capabilities and their snapshot producers. Subscription timing
    /// lives in `AppRuntime`; this just answers "what does `cap` look like now".
    func snapshot(cap: String) -> JSONValue? {
        switch cap {
        case "system.usage":
            if !usageStarted { usage.start(); usageStarted = true }
            return .object(["cpu": .number(usage.cpu), "gpu": .number(usage.gpu)])
        case "sous.state":
            let s = SousManager.shared
            guard s.running else { return nil }     // Sous is off or uninstalled
            let m = s.metrics
            return .object([
                "percent": .number(Double(s.displayPercent)),
                "charging": .bool(m.isCharging),
                "pluggedIn": .bool(m.externalConnected),
                "tempC": .number(s.tempC),
                "batteryPowerW": .number(m.batteryPowerW),
                "cycleCount": .number(Double(m.cycleCount)),
                "sousActive": .bool(s.capable && s.config.enabled),
                "chargeLimit": .number(Double(s.config.chargeLimit)),
                "state": .string(String(describing: s.displayState)),
            ])
        case "temper.metrics":
            let t = TemperManager.shared
            guard t.running else { return nil }     // Temper is off or uninstalled
            let m = t.metrics
            let fans: [JSONValue] = t.displayFans.map {
                .object(["rpm": .number($0.actualRPM),
                         "minRPM": .number($0.minRPM),
                         "maxRPM": .number($0.maxRPM)])
            }
            return .object([
                "thermalState": .string(String(describing: m.thermalState)),
                "hottestC": .number(m.hottestC),
                "batteryTempC": .number(m.batteryTempC),
                "cpuUsage": .number(m.cpuUsage),
                "fans": .array(fans),
            ])
        default:
            return nil
        }
    }

    /// Streamable caps and their host-side cadence ceiling (Hz).
    static let streamCeilings: [String: Double] = [
        "system.usage": 1, "sous.state": 0.5, "temper.metrics": 0.5,
    ]

    // MARK: - Storage

    private func storageURL(appID: String) -> URL {
        AppsManager.dataDir(for: appID).appendingPathComponent("kv.json")
    }

    private func storageRead(appID: String) -> [String: JSONValue] {
        guard let data = try? Data(contentsOf: storageURL(appID: appID)),
              let kv = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        else { return [:] }
        return kv
    }

    private func storageWrite(appID: String, _ kv: [String: JSONValue]) {
        guard let data = try? JSONEncoder().encode(kv) else { return }
        try? data.write(to: storageURL(appID: appID), options: .atomic)
    }

    // MARK: - Notifications

    private var notchEnabled: Bool {
        UserDefaults(suiteName: "com.oxine.settings")?.object(forKey: "notchEnabled") as? Bool ?? true
    }

    private struct NoticeKey: Hashable { let app: String; let key: String }
    /// Each keyed notice showing, so the app can replace or end it by its key.
    private var notices: [NoticeKey: UUID] = [:]

    /// An app's notification as a notch notice. A plain one is its title and
    /// body in the app's icon and color; the rest of the notice vocabulary is
    /// there for apps that want it: a message from a person (their picture or
    /// color, reactions, a reply field), a big value, a ring, buttons. What
    /// the person does with it comes back as an event on the "notice"
    /// surface, `ref` = the app's `key`. Posting the same key again replaces
    /// the notice in place. Each app can be moved or turned off in Settings →
    /// Notch → Notifications.
    private func postNotchNotice(appID: String, args: JSONValue?) {
        let app = AppsManager.shared.app(appID)
        let name = app?.name ?? appID
        let title = args?["title"]?.stringValue ?? ""
        let body = args?["body"]?.stringValue ?? ""
        let key = args?["key"]?.stringValue
        let person = args?["person"].flatMap { p in
            p["name"]?.stringValue.map {
                NotchNotice.Person(name: $0, image: Self.image(p["image"]), color: Self.color(p["color"]))
            }
        }
        let actions: [NotchNotice.Action] = (args?["actions"]?.arrayValue ?? []).prefix(3).compactMap { a in
            guard let id = a["id"]?.stringValue, let title = a["title"]?.stringValue else { return nil }
            return .init(id: id, title: title, role: a["role"]?.stringValue.flatMap(NotchNotice.Action.Role.init) ?? .normal,
                         hold: a["hold"]?.boolValue ?? false, icon: a["icon"]?.stringValue)
        }
        let notice = NotchNotice(
            icon: args?["icon"]?.stringValue ?? app?.icon ?? "app.badge.fill",
            tint: Self.color(args?["tint"]) ?? AppArt.tint(for: appID),
            title: title.isEmpty ? (person?.name ?? name) : title,
            subtitle: args?["subtitle"]?.stringValue ?? (title.isEmpty && person == nil ? nil : name),
            detail: body.isEmpty ? nil : body,
            image: Self.image(args?["image"]),
            progress: args?["progress"]?.numberValue.map { min(max($0, 0), 1) },
            actions: actions,
            placement: args?["placement"]?.stringValue.flatMap(NoticePlacement.init) ?? .automatic,
            emphasis: args?["urgent"]?.boolValue == true ? .urgent : .normal,
            duration: args?["duration"]?.numberValue.map { min(max($0, 2), 60) },
            sticky: args?["sticky"]?.boolValue ?? false,
            group: key.map { "\(appID):\($0)" },
            sound: args?["sound"]?.stringValue,
            source: appID, sourceName: name,
            look: args?["look"]?.stringValue.flatMap(NotchNotice.Look.init) ?? (person != nil ? .message : .standard),
            shape: args?["shape"]?.stringValue.flatMap(NotchNotice.Shape.init) ?? .automatic,
            entrance: args?["entrance"]?.stringValue.flatMap(NotchNotice.Entrance.init) ?? .automatic,
            hero: args?["hero"]?.stringValue, emoji: args?["emoji"]?.stringValue,
            person: person,
            reactions: Array((args?["reactions"]?.arrayValue ?? []).compactMap(\.stringValue).prefix(5)),
            reply: args?["reply"]?.stringValue)
        let id = notice.id
        if let key { notices[NoticeKey(app: appID, key: key)] = id }
        NotchNotices.shared.post(notice) { [weak self] action in
            if let key, self?.notices[NoticeKey(app: appID, key: key)] == id {
                self?.notices[NoticeKey(app: appID, key: key)] = nil
            }
            Self.answer(appID: appID, key: key, action: action)
        }
    }

    /// Tell the app what the person did with its notice: "reply" or "react"
    /// (with the text or emoji), "action" (the button's id), "open", or
    /// "dismiss". "open" also opens the app's notch tab, ready to type.
    private static func answer(appID: String, key: String?, action: String) {
        guard let runtime = AppsManager.shared.app(appID)?.runtime else { return }
        let kind: String, value: JSONValue?
        if action.hasPrefix("reply:") {
            (kind, value) = ("reply", .string(String(action.dropFirst(6))))
        } else if action.hasPrefix("react:") {
            (kind, value) = ("react", .string(String(action.dropFirst(6))))
        } else if action == "dismiss" || action == "open" {
            (kind, value) = (action, nil)
        } else {
            (kind, value) = ("action", .string(action))
        }
        if action == "open" { NotchCoordinator.shared.openTab(appID: appID) }
        runtime.sendEvent(surface: "notice", ref: key, kind: kind, value: value)
    }

    /// A "#RRGGBB" prop, or nil.
    private static func color(_ value: JSONValue?) -> Color? {
        guard let hex = value?.stringValue, AppRuntime.isHexColor(hex) else { return nil }
        return Color(hex: hex)
    }

    /// A base64 PNG/JPEG prop (a person's picture, a photo), at most 1 MB.
    private static func image(_ value: JSONValue?) -> NSImage? {
        guard let b64 = value?.stringValue, b64.count < 1_400_000,
              let data = Data(base64Encoded: b64) else { return nil }
        return NSImage(data: data)
    }

    private func postNotification(appID: String, title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let req = UNNotificationRequest(identifier: "app.\(appID).\(UUID().uuidString)",
                                            content: content, trigger: nil)
            center.add(req)
        }
    }
}
