import SwiftUI

public struct LyricsSettingsView: View {
    @AppStorage("notchLyricsEnabled", store: NotchKit.settingsDefaults) private var enabled = false
    @AppStorage("notchLyricsFont", store: NotchKit.settingsDefaults) private var font = 22.0
    @AppStorage("notchLyricsWidth", store: NotchKit.settingsDefaults) private var width = 520.0
    @AppStorage("notchLyricsX", store: NotchKit.settingsDefaults) private var x = 0.0
    @AppStorage("notchLyricsY", store: NotchKit.settingsDefaults) private var y = 8.0
    @AppStorage("notchLyricsOffset", store: NotchKit.settingsDefaults) private var offset = 0.3
    @AppStorage("notchLyricsTrackInfo", store: NotchKit.settingsDefaults) private var trackInfo = true
    @AppStorage("notchLyricsPreview", store: NotchKit.settingsDefaults) private var preview = false
    public init() {}
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("ScreenLyrics below the notch", isOn: $enabled)
            Text("Fetches synced lyrics from LRCLIB using the current song, artist, album and duration. Hides when paused or the notch is expanded.")
                .font(.caption).foregroundStyle(.secondary)
            if enabled {
                Toggle("Preview placement", isOn: $preview)
                Toggle("Show artist and song", isOn: $trackInfo)
                adjustment("Text size", value: $font, range: 12...48, step: 1, suffix: "pt")
                adjustment("Width", value: $width, range: 240...1000, step: 10, suffix: "pt")
                adjustment("Horizontal position", value: $x, range: -1500...1500, step: 5, suffix: "pt")
                adjustment("Distance below notch", value: $y, range: 0...1500, step: 2, suffix: "pt")
                HStack {
                    Text("Timing")
                    Spacer()
                    Text(String(format: "%+.1f s", offset)).monospacedDigit()
                    Stepper("Timing", value: $offset, in: -10...10, step: 0.1).labelsHidden()
                }
                Slider(value: $offset, in: -10...10, step: 0.1)
                Text("Positive timing shows lyrics earlier; negative timing shows them later. Zero is saved exactly. The overlay lets clicks pass through.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reset size, position & timing") { font = 22; width = 520; x = 0; y = 8; offset = 0.3 }
            }
        }
        .onDisappear { preview = false }
    }
    private func adjustment(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, suffix: String) -> some View {
        VStack(spacing: 3) {
            HStack { Text(title); Spacer(); Text("\(Int(value.wrappedValue)) \(suffix)").monospacedDigit() }
            Slider(value: value, in: range, step: step)
        }
    }
}
