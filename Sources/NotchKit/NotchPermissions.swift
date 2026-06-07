import SwiftUI
import AppKit
import EventKit
import AVFoundation
import CoreLocation

/// Reads and (re)requests the permissions the notch modules need: Calendar
/// (glanceable timeline), Location (weather), Camera (mirror). Surfaced in
/// Settings so a grant made elsewhere, or one lost across an update, can be
/// re-checked or re-asked without relaunching.
@MainActor
public final class NotchPermissions: NSObject, ObservableObject {
    public enum Access: Equatable { case granted, denied, notDetermined }

    @Published public private(set) var calendar: Access = .notDetermined
    @Published public private(set) var camera: Access = .notDetermined
    @Published public private(set) var location: Access = .notDetermined

    private let store = EKEventStore()
    private let loc = CLLocationManager()

    public override init() {
        super.init()
        loc.delegate = self
        refresh()
    }

    /// Re-read all three (cheap, synchronous).
    public func refresh() {
        calendar = mapEK(EKEventStore.authorizationStatus(for: .event))
        camera = mapAV(AVCaptureDevice.authorizationStatus(for: .video))
        location = mapCL(loc.authorizationStatus)
    }

    public func requestCalendar() {
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            store.requestFullAccessToEvents { [weak self] _, _ in
                DispatchQueue.main.async { self?.refresh() }
            }
        } else {
            open("Privacy_Calendars")
        }
    }

    public func requestCamera() {
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
        } else {
            open("Privacy_Camera")
        }
    }

    public func requestLocation() {
        if loc.authorizationStatus == .notDetermined {
            loc.requestWhenInUseAuthorization()
        } else {
            open("Privacy_LocationServices")
        }
        refresh()
    }

    /// Open the relevant System Settings privacy pane (for an already-decided one).
    private func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func mapEK(_ s: EKAuthorizationStatus) -> Access {
        switch s {
        case .fullAccess, .authorized, .writeOnly: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }
    private func mapAV(_ s: AVAuthorizationStatus) -> Access {
        switch s {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }
    private func mapCL(_ s: CLAuthorizationStatus) -> Access {
        switch s {
        case .authorized, .authorizedAlways, .authorizedWhenInUse: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }
}

extension NotchPermissions: CLLocationManagerDelegate {
    public nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        Task { @MainActor in self.refresh() }
    }
}
