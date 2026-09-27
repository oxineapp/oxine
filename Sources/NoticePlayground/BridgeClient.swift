import AppKit
import NoticeBridge
import SwiftUI

/// The playground's line to Oxine: posts notices and settings as distributed
/// notifications, and hears back what's showing and which buttons were
/// pressed. Oxine ignores it all until the bridge switch is on in its settings.
@MainActor
final class BridgeClient: ObservableObject {
    static let shared = BridgeClient()

    @Published private(set) var state: NoticeState?
    /// Oxine answered within the last few seconds.
    @Published private(set) var connected = false
    @Published private(set) var bridgeOn: Bool
    @Published private(set) var log: [String] = []

    private var names: [UUID: String] = [:]
    /// Notices Oxine has reported showing, so a live example can tell "not
    /// shown yet" from "dismissed".
    private var seen: Set<UUID> = []
    private var answered: Set<UUID> = []
    private var lastHeard = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    private var oxineSettings: UserDefaults? { UserDefaults(suiteName: NoticeBridge.suite) }

    private init() {
        bridgeOn = UserDefaults(suiteName: NoticeBridge.suite)?.bool(forKey: NoticeBridge.enabledKey) ?? false
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: NoticeBridge.Message.state.name, object: nil, queue: .main) { note in
            let json = note.userInfo?[NoticeBridge.payloadKey] as? String
            MainActor.assumeIsolated { BridgeClient.shared.heardState(json) }
        })
        observers.append(center.addObserver(forName: NoticeBridge.Message.action.name, object: nil, queue: .main) { note in
            let json = note.userInfo?[NoticeBridge.payloadKey] as? String
            MainActor.assumeIsolated { BridgeClient.shared.heardAction(json) }
        })
        let t = Timer(timeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                let client = BridgeClient.shared
                client.ping()
                client.connected = Date().timeIntervalSince(client.lastHeard) < 5
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        ping()
    }

    // MARK: the switch

    /// Oxine's overall notification style ("automatic", "notch", "floating"),
    /// read from and written to its settings; it applies from the next notice.
    var style: String {
        get { oxineSettings?.string(forKey: "notchNoticePlacement") ?? "automatic" }
        set {
            objectWillChange.send()
            oxineSettings?.set(newValue, forKey: "notchNoticePlacement")
        }
    }

    func setBridge(_ on: Bool) {
        oxineSettings?.set(on, forKey: NoticeBridge.enabledKey)
        bridgeOn = on
        if on { ping() } else { connected = false; state = nil }
    }

    // MARK: sending

    @discardableResult
    func post(_ payload: NoticePayload, name: String? = nil) -> UUID {
        names[payload.id] = name ?? payload.title
        send(.post, payload)
        return payload.id
    }

    func dismiss(_ id: UUID) { send(.dismiss, NoticeDismiss(id: id)) }
    func dismissAll() { send(.dismissAll, NoticeDismiss(id: UUID())) }
    func setMetrics(_ change: NoticeMetricsChange) { send(.metrics, change) }
    func ping() { send(.ping, NoticeDismiss(id: UUID())) }

    /// For live examples: false once Oxine has shown it and then let it go,
    /// or once it was answered or closed there.
    func stillShowing(_ id: UUID) -> Bool {
        if answered.contains(id) { return false }
        let showing = state?.notices.contains { $0.id == id } ?? false
        return showing || !seen.contains(id)
    }

    private func send<T: Encodable>(_ message: NoticeBridge.Message, _ value: T) {
        DistributedNotificationCenter.default().postNotificationName(
            message.name, object: nil, userInfo: NoticeBridge.encode(value), deliverImmediately: true)
    }

    // MARK: hearing

    private func heardState(_ json: String?) {
        guard let state = NoticeBridge.decode(NoticeState.self, from: json.map { [NoticeBridge.payloadKey: $0] }) else { return }
        self.state = state
        seen.formUnion(state.notices.map(\.id))
        lastHeard = Date()
        connected = true
    }

    private func heardAction(_ json: String?) {
        guard let event = NoticeBridge.decode(NoticeActionEvent.self, from: json.map { [NoticeBridge.payloadKey: $0] }) else { return }
        answered.insert(event.id)
        log.insert("\(names[event.id] ?? "Notice") → \(event.action)", at: 0)
        if log.count > 10 { log.removeLast() }
    }
}

extension NoticePayload.RGBA {
    init(_ color: Color) {
        let c = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        self.init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
    }
    var color: Color { Color(red: r, green: g, blue: b, opacity: a) }
}
