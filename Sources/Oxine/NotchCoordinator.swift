import AppKit
import NotchKit
import SwiftUI
import TemperKit

/// Wires NotchKit into Oxine: owns the notch controller + window and rebuilds
/// them when the relevant settings change. Thin glue, mirroring the Sous/Temper
/// observers in `AppDelegate` — the engine and modules live in NotchKit.
@MainActor
final class NotchCoordinator {
    static let shared = NotchCoordinator()

    private var controller: NotchController?
    private var presenter: NotchPresenter?
    private let suite = UserDefaults(suiteName: "com.oxine.settings")
    /// Who's waiting, per app, in their colors (see `setAttention`).
    private var attention: [String: [String]] = [:]

    private init() {}

    /// Configure NotchKit and bring the notch up if enabled. Call once at launch
    /// (after `PanelKit.configure`).
    func start() {
        NotchKit.configure(.oxine)
        // Feed the notch bar's "Fan speed" metric from Temper (NotchKit stays
        // TemperKit-free). Averages all fans, per the spec.
        NotchKit.fanReadout = {
            let fans = TemperManager.shared.displayFans
            guard !fans.isEmpty else { return nil }
            let n = Double(fans.count)
            let avgFrac = fans.map(\.fraction).reduce(0, +) / n
            let avgRPM = fans.map(\.actualRPM).reduce(0, +) / n
            return MetricReadout(fraction: avgFrac, text: "\(Int(avgRPM.rounded())) rpm")
        }
        // App-contributed bar metrics ("app:<id>" tokens in the metric pickers).
        NotchKit.externalBarMetrics = {
            AppsManager.shared.barMetricApps.map { app in
                ExternalBarMetric(
                    id: "app:\(app.id)",
                    label: app.manifest.surfaces.barMetric?.label ?? app.name,
                    color: .panelAccent,
                    readout: { [weak app] in
                        guard let app else { return nil }
                        return MetricReadout(fraction: app.runtime.metricValue,
                                             text: app.runtime.metricText ?? "")
                    })
            }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: .notchSettingsChanged, object: nil)
        // Display changes (lid closed, monitor plugged) move the notch screen.
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        apply()
    }

    private var enabled: Bool { suite?.object(forKey: "notchEnabled") as? Bool ?? true }
    private var fauxOnExternal: Bool { suite?.bool(forKey: "notchFauxOnExternal") ?? false }

    @objc private func settingsChanged() { apply() }

    /// The screen the notch was last built for (see `screenSignature`).
    private var builtFor: String?
    private var pendingScreenCheck: DispatchWorkItem?

    /// The notch's screen, where it sits, and its cutout. macOS posts
    /// screen-parameter changes far more often than any of these move (wake,
    /// Dock and menu bar changes, HDR headroom following the brightness), and a
    /// rebuild restarts every notch module, so only a change here rebuilds.
    private static func screenSignature() -> String? {
        guard let s = NotchGeometry.preferredScreen() else { return nil }
        let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        return "\(id) \(s.frame) \(s.backingScaleFactor) \(NotchGeometry.notchFrame(for: s))"
    }

    /// Waits for a reconfiguration burst to settle, then rebuilds only if the
    /// notch's screen actually changed.
    @objc private func screensChanged() {
        pendingScreenCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, Self.screenSignature() != self.builtFor else { return }
            self.apply()
        }
        pendingScreenCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Global-shortcut action: open/close the notch by toggling its pin. Pinning
    /// keeps it expanded without hover; unpinning lets it collapse. (This is the
    /// "pin, then unpin" toggle — it does not enable/disable the whole feature.)
    func toggle() {
        guard let controller else { return }
        controller.pinned.toggle()
    }

    /// Flash a transient peek line beside the cutout (used by apps' `peek`
    /// messages, already rate-limited in `AppRuntime`). No-op with the notch off.
    func peek(_ text: String) {
        controller?.peek(text)
    }

    /// An app's unread people, as "#RRGGBB" colors (already checked): the
    /// closed notch's outline breathes through everyone's, app by app.
    func setAttention(appID: String, colors: [String]) {
        guard attention[appID, default: []] != colors else { return }
        attention[appID] = colors.isEmpty ? nil : colors
        controller?.setAttention(attentionColors)
    }

    private var attentionColors: [Color] {
        attention.keys.sorted().flatMap { attention[$0] ?? [] }.map(Color.init(hex:))
    }

    /// Keep the notch open whatever the pointer does (a file panel is up
    /// over it), or let it go again.
    func holdOpen(_ held: Bool) {
        controller?.heldOpen = held
    }

    /// Open the notch on an app's tab (its notice's "Open" was pressed).
    func openTab(appID: String) {
        controller?.open(tab: "app:\(appID)")
    }


    /// Tear down and (re)build from the current settings — covers enable/disable
    /// and the faux-notch toggle in one path.
    func apply() {
        presenter?.hide(); presenter = nil
        controller = nil
        builtFor = Self.screenSignature()
        guard enabled else { return }

        // Tabs: Home (player + webcam slot), Shelf, Calendar — plus a tab per
        // enabled app that declares a notchTab surface. The notch reopens to
        // whichever tab was last used.
        var modules: [any NotchModule] = [
            HomeModule(),
            ShelfModule(),
            CalendarModule(),
            WeatherModule()
        ]
        modules.append(contentsOf: AppsManager.shared.notchTabApps.map { RemoteNotchModule(app: $0) })
        let controller = NotchController(modules: modules)
        controller.setAttention(attentionColors)
        let presenter = NotchPresenter(controller: controller, allowFauxNotch: fauxOnExternal)
        self.controller = controller
        self.presenter = presenter
        presenter.show()
    }
}

extension Notification.Name {
    /// Posted by Settings when a notch toggle changes so the coordinator rebuilds.
    static let notchSettingsChanged = Notification.Name("notchSettingsChanged")
}
