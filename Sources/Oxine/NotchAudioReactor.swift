import Foundation
import NotchKit
import TapKit

/// Feeds the notch's little equaliser real audio. It only ever listens while a
/// visualiser is actually asking (the bars are on screen and something plays):
/// the first request opens the hub's shared system listener, and a couple of
/// seconds without requests closes it again. Never prompts — without the System
/// Audio Recording grant it returns nil and the bars fall back to their
/// animation.
@MainActor
final class NotchAudioReactor {
    static let shared = NotchAudioReactor()
    private static let client = "oxine.notch"
    static let settingKey = "notchRealAudioBars"

    private var analyzer: SpectrumAnalyzer?
    private var lastAsked = Date.distantPast
    private var watchdog: Timer?
    private var bandCount = 0

    func install() {
        NotchKit.audioBands = { count in NotchAudioReactor.shared.bands(count) }
    }

    private var enabled: Bool {
        NotchKit.settingsDefaults.object(forKey: Self.settingKey) as? Bool ?? true
    }

    private func bands(_ count: Int) -> [Float]? {
        guard enabled else { close(); return nil }
        lastAsked = Date()
        if analyzer == nil || bandCount != count {
            guard AudioCapturePermission.status == .granted else { return nil }
            TapHub.shared.join(Self.client)
            guard let tap = try? TapHub.shared.openSystemListener(for: Self.client),
                  let made = SpectrumAnalyzer(ring: tap.samples, sampleRate: tap.sampleRate, bands: count) else {
                TapHub.shared.leave(Self.client); return nil
            }
            analyzer = made; bandCount = count
            watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                Task { @MainActor in NotchAudioReactor.shared.checkIdle() }
            }
        }
        return analyzer?.bands()
    }

    private func checkIdle() {
        if Date().timeIntervalSince(lastAsked) > 2.5 { close() }
    }

    private func close() {
        guard analyzer != nil else { return }
        analyzer = nil
        watchdog?.invalidate(); watchdog = nil
        TapHub.shared.leave(Self.client)
    }
}
