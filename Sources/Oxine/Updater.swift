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
final class UpdaterManager: ObservableObject {
    static let shared = UpdaterManager()

    private let driver: OxineUpdaterDriver
    private let updater: SPUUpdater

    /// Mirrors Sparkle's "can a check start right now" so the button disables
    /// itself while a check/download is already in flight.
    @Published var canCheckForUpdates = true

    /// User-facing toggle for scheduled background checks (Sparkle persists it).
    @Published var automaticallyChecks: Bool {
        didSet { updater.automaticallyChecksForUpdates = automaticallyChecks }
    }

    private init() {
        // Custom user driver → Oxine's own dark update UI (see UpdaterUI.swift)
        // instead of Sparkle's stock AppKit windows.
        driver = OxineUpdaterDriver()
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                             userDriver: driver, delegate: nil)
        automaticallyChecks = updater.automaticallyChecksForUpdates
        do {
            try updater.start()
        } catch {
            log("updater failed to start: \(error.localizedDescription)")
        }
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    /// Manual check. Brings the app forward first — an accessory app's Sparkle
    /// dialogs would otherwise open behind whatever's frontmost.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        updater.checkForUpdates()
    }
}
