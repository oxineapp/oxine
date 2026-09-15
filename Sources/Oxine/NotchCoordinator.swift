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
            self, selector: #selector(settingsChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        apply()
    }

    private var enabled: Bool { suite?.object(forKey: "notchEnabled") as? Bool ?? true }
    private var fauxOnExternal: Bool { suite?.bool(forKey: "notchFauxOnExternal") ?? false }

    @objc private func settingsChanged() { apply() }

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


    /// Tear down and (re)build from the current settings — covers enable/disable
    /// and the faux-notch toggle in one path.
    func apply() {
        presenter?.hide(); presenter = nil
        controller = nil
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
