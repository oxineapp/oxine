import Combine
import Foundation
import TapKit

/// Decant as an app. The tab is native (meters and faders are past the v1 view
/// vocabulary); the settings pane is an ordinary view tree. `bye` releases every
/// tap, so turning Decant off — or uninstalling it — hands each app's volume
/// straight back.
@MainActor
final class DecantAppBackend: InternalAppBackend {
    private let decant = DecantManager.shared
    private var sink: AnyCancellable?
    /// The manager republishes meters fifteen times a second; the pane only
    /// cares about these.
    private var pushed: [String] = []

    override func receive(_ msg: HostMessage) {
        switch msg {
        case .hello:
            decant.start()
            sink = decant.objectWillChange
                .throttle(for: .milliseconds(400), scheduler: DispatchQueue.main, latest: true)
                .sink { [weak self] in self?.push() }
            push()
        case .event(let surface, let ref, let kind, let value):
            guard surface == "settings" else { return }
            switch (kind, ref) {
            case ("change", "boost"): decant.boost = value?.boolValue ?? false
            case ("tap", "grant"): decant.requestPermission()
            case ("tap", "forget"): decant.resetAll()
            default: break
            }
            push()
        case .lifecycle(let phase, let surface):
            if phase == "activate", surface == "settings" { decant.refreshPermission(); push() }
        case .bye:
            sink = nil
            pushed = []
            decant.stop()
        default: break
        }
    }

    private func push() {
        let signature = [label(decant.permission), "\(decant.boost)", "\(decant.policies.count)", "\(decant.pinned.count)"]
        guard signature != pushed else { return }
        pushed = signature
        var access: [AppNode] = [N.keyValue("System Audio Recording", label(decant.permission))]
        if decant.permission != .granted {
            access.append(N.text("To change an app's volume, Oxine reads the sound that app plays and plays it back quieter or louder. macOS calls that recording. Nothing is saved, and nothing leaves this Mac."))
            access.append(N.button("grant", decant.permission == .denied ? "Open System Settings" : "Allow"))
        }
        let saved = decant.policies.count
        emit(.view(surface: "settings", body: [
            N.section("Access", access),
            N.section("Volume", [
                N.toggle("boost", "Allow boosting past 100%", decant.boost),
                N.text("Faders run to 200%, with a notch at 100%. Boosted sound is clipped at full scale rather than allowed to distort the speakers."),
            ]),
            N.section("How it works", [
                N.text("An app you haven't touched plays exactly as it always did. Move its fader, mute it or send it to another output, and Oxine takes over that one app's sound while it's playing. No audio driver is installed and the system output is never changed. Turning Decant off gives every app back at once."),
            ]),
            N.section("Your apps", [
                N.keyValue("Kept on the mixer", decant.pinned.isEmpty ? "None" : "\(decant.pinned.count)"),
                N.keyValue("Saved volumes and outputs", saved == 0 ? "None" : "\(saved)"),
                N.text("Apps show up on the mixer while they play. Add one from the tab to keep it there, or right-click a strip."),
                N.button("forget", "Forget all of them", destructive: true),
            ]),
        ]))
    }

    private func label(_ status: AudioCapturePermission.Status) -> String {
        switch status {
        case .granted: "Allowed"
        case .denied: "Denied"
        case .undetermined: "Not asked yet"
        case .unknown: "Unknown"
        }
    }
}
