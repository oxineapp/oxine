import Foundation
import AppKit
import Combine

/// Detects when another battery charge-limiting app is *running*. Such an app
/// drives the same SMC charge registers as Sous, so the two fight over the limit
/// (each keeps re-asserting its own) — the Sous UI warns while one is active.
/// Only the running state counts: a merely-installed competitor isn't controlling
/// anything, so it raises no warning. Shared via SousKit so the standalone
/// sous-vide app warns too. Live: re-checks whenever any app launches or quits.
@MainActor
public final class BatteryConflictDetector: ObservableObject {
    public static let shared = BatteryConflictDetector()

    private static let name = "AlDente"
    /// AlDente ships under several bundle ids (direct download, Setapp, …) that all
    /// share this prefix, so we match the prefix rather than a fixed id — a new
    /// distribution is still caught.
    private static let bundlePrefix = "com.apphousekitchen.aldente"

    /// Name of a competitor that is currently running, nil if none.
    @Published public private(set) var running: String?

    private var kvo: NSKeyValueObservation?

    private init() {
        refresh()
        // KVO on the running-apps set fires for menu-bar/agent apps too — AlDente
        // is an LSUIElement agent, which `didLaunchApplicationNotification` misses.
        kvo = NSWorkspace.shared.observe(\.runningApplications, options: []) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Re-evaluate whether a competitor is running. Cheap (an in-memory scan of the
    /// running apps), safe to call on view appearance as a belt-and-braces refresh.
    public func refresh() {
        let isRunning = NSWorkspace.shared.runningApplications.contains {
            ($0.bundleIdentifier ?? "").lowercased().hasPrefix(Self.bundlePrefix)
        }
        running = isRunning ? Self.name : nil
    }
}
