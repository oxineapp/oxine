import AppKit
import Foundation
import NotchKit
import SousKit
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
            let title = args?["title"]?.stringValue ?? ""
            let body = args?["body"]?.stringValue ?? ""
            postNotification(appID: appID, title: title, body: body)
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
