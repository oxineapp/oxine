import AppKit
import Combine
import Foundation
import NotchKit

/// Ears On as an app: listening runs for the app's lifetime; the footer
/// switch pauses and resumes it, and the settings pane picks the sounds.
@MainActor
final class EarsOnAppBackend: InternalAppBackend {
    private let engine = EarsOnEngine.shared
    private var cancellables: Set<AnyCancellable> = []

    override func receive(_ msg: HostMessage) {
        switch msg {
        case .hello:
            engine.$status.combineLatest(engine.$lastHeard)
                .sink { [weak self] _, _ in self?.push() }
                .store(in: &cancellables)
            engine.start()
            push()
        case .event(let surface, let ref, let kind, let value):
            handle(surface: surface, ref: ref, kind: kind, value: value)
            push()
        case .bye:
            cancellables = []
            engine.stop()
        default: break
        }
    }

    private func handle(surface: String, ref: String?, kind: String, value: JSONValue?) {
        switch (surface, kind, ref) {
        case ("quickToggle", "tap", _):
            engine.enabled.toggle()
        case ("quickToggle", "menu", "headphones"):
            engine.headphonesOnly.toggle()
        case ("settings", "tap", "try"):
            engine.announce(.doorbell, test: true)
        case ("settings", "tap", "privacy"):
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        case ("settings", "change", let id?):
            switch id {
            case "enabled": engine.enabled = value?.boolValue ?? true
            case "headphonesOnly": engine.headphonesOnly = value?.boolValue ?? true
            case "pause": engine.pausesMedia = value?.boolValue ?? true
            case "sensitivity":
                if let s = EarsOnEngine.Sensitivity.allCases.first(where: { $0.label == value?.stringValue }) {
                    engine.sensitivity = s
                }
            default:
                if id.hasPrefix("sound."), let sound = EarsOnSound(rawValue: String(id.dropFirst(6))) {
                    engine.set(sound, on: value?.boolValue ?? sound.onByDefault)
                }
            }
        default: break
        }
    }

    private func push() {
        let listening = engine.status == .listening
        emit(.toggle(active: engine.enabled,
                     icon: listening ? "ear.fill" : "ear",
                     text: nil,
                     menu: [AppMenuItem(id: "headphones", title: "Only with headphones on",
                                        checked: engine.headphonesOnly)]))
        var status: [AppNode] = [N.keyValue("Status", engine.status.text)]
        if let last = engine.lastHeard { status.append(N.keyValue("Last heard", last)) }
        if engine.status == .needsMicrophone {
            status.append(N.button("privacy", "Open Microphone settings"))
        }
        emit(.view(surface: "settings", body: [
            N.section("Listening", [
                N.toggle("enabled", "Listen for sounds around you", engine.enabled),
            ] + status + [
                N.toggle("headphonesOnly", "Only while headphones are on", engine.headphonesOnly),
                N.text("With speakers you can hear the room yourself, and the Mac's own sound could set it off. The orange microphone dot shows while it listens."),
                N.toggle("pause", "Pause what's playing when it hears something", engine.pausesMedia),
                N.picker("sensitivity", "Sensitivity", EarsOnEngine.Sensitivity.allCases.map(\.label), engine.sensitivity.label),
                N.text("Higher catches quieter sounds, and more false ones."),
            ]),
            N.section("Sounds", EarsOnSound.allCases.map { N.toggle("sound." + $0.rawValue, $0.name, engine.isOn($0)) }),
            N.section("Try it", [
                N.button("try", "Pretend the doorbell rang"),
                N.text("Shows the notice and pauses your music, as the real thing would."),
            ]),
            N.section("Privacy", [
                N.text("Apple's sound recognition runs on this Mac. Nothing is recorded, kept or sent anywhere. It listens through the Mac's own microphone, never your headphones', so AirPods don't drop to call quality."),
            ]),
        ]))
    }
}
