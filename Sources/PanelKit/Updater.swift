import AppKit
import Combine
import Sparkle

/// Thin SwiftUI-friendly wrapper around Sparkle's updater.
///
/// Why Sparkle works here despite no Apple notarization: updates are trusted via
/// Sparkle's own EdDSA signature (the public half is in Info.plist as
/// `SUPublicEDKey`; the private half lives in the developer's Keychain and signs
/// every release). That signature — not a Developer ID / notarization — is the
/// trust anchor. Sparkle also strips the Gatekeeper quarantine flag from an
/// update *after* it verifies that signature, so every update after the initial
/// manual DMG install launches clean (no "unidentified developer" wall).
///
/// The app is an accessory (`LSUIElement`, no Dock tile, no app menu), so the
/// only *manual* entry point is the "Check for Updates" button in Settings;
/// scheduled background checks still run on Sparkle's own timer (`SUFeedURL` +
/// `SUScheduledCheckInterval` in Info.plist).
@MainActor
public final class UpdaterManager: ObservableObject {
    public static let shared = UpdaterManager()

    private let driver: PanelUpdaterDriver
    private let updater: SPUUpdater

    /// Mirrors Sparkle's "can a check start right now" so the button disables
    /// itself while a check/download is already in flight.
    @Published public var canCheckForUpdates = true

    /// User-facing toggle for scheduled background checks (Sparkle persists it).
    @Published public var automaticallyChecks: Bool {
        didSet { updater.automaticallyChecksForUpdates = automaticallyChecks }
    }

    private init() {
        // Custom user driver → Oxine's own dark update UI (see UpdaterUI.swift)
        // instead of Sparkle's stock AppKit windows.
        driver = PanelUpdaterDriver()
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                             userDriver: driver, delegate: nil)
        automaticallyChecks = updater.automaticallyChecksForUpdates
        do {
            try updater.start()
        } catch {
            panelLog("updater failed to start: \(error.localizedDescription)")
        }
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    /// Manual check. Brings the app forward first — an accessory app's Sparkle
    /// dialogs would otherwise open behind whatever's frontmost.
    public func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        updater.checkForUpdates()
    }

    /// Lightweight check fired when the panel opens. Uses Sparkle's *background*
    /// check: it stays silent when we're current and only surfaces the update
    /// window (via the user driver) when there's something to install — so the
    /// popup appears right when the user opens the app. Throttled so opening the
    /// panel repeatedly doesn't re-hit the feed; a found update still re-pops on
    /// a later open until it's installed or skipped.
    private static let openCheckInterval: TimeInterval = 1800   // ≤ once / 30 min
    private let lastOpenCheckKey = "panelLastOpenUpdateCheck"
    public func checkOnOpen() {
        guard automaticallyChecks else { return }
        let store = PanelKit.settingsDefaults
        let last = store.object(forKey: lastOpenCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > Self.openCheckInterval else { return }
        store.set(Date(), forKey: lastOpenCheckKey)
        updater.checkForUpdatesInBackground()
    }
}
