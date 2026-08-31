import SwiftUI
import AppKit

public struct LyricsSettingsView: View {
    @AppStorage("notchLyricsEnabled", store: NotchKit.settingsDefaults) private var enabled = false
    @AppStorage("notchLyricsFont", store: NotchKit.settingsDefaults) private var font = 22.0
    @AppStorage("notchLyricsFontFamily", store: NotchKit.settingsDefaults) private var fontFamily = "system"
    @AppStorage("notchLyricsWidth", store: NotchKit.settingsDefaults) private var width = 520.0
    @AppStorage("notchLyricsHeight", store: NotchKit.settingsDefaults) private var height = 160.0
    @AppStorage("notchLyricsX", store: NotchKit.settingsDefaults) private var x = 0.0
    @AppStorage("notchLyricsY", store: NotchKit.settingsDefaults) private var y = 8.0
    @AppStorage("notchLyricsOffset", store: NotchKit.settingsDefaults) private var offset = 0.3
    @AppStorage("notchLyricsTrackInfo", store: NotchKit.settingsDefaults) private var trackInfo = true
    @AppStorage("notchLyricsPreview", store: NotchKit.settingsDefaults) private var preview = false
    @AppStorage("notchLyricsShowBounds", store: NotchKit.settingsDefaults) private var showBounds = false
    @AppStorage("notchLyricsBackground", store: NotchKit.settingsDefaults) private var background = true
    @AppStorage("notchLyricsBackgroundOpacity", store: NotchKit.settingsDefaults) private var opacity = 0.82
    @AppStorage("notchLyricsAnimation", store: NotchKit.settingsDefaults) private var animation = "fade"
    @AppStorage("notchLyricsAnimationDuration", store: NotchKit.settingsDefaults) private var duration = 0.25
    private static let families = NSFontManager.shared.availableFontFamilies.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    public init() {}
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("ScreenLyrics below the notch", isOn: $enabled)
            Text("Fetches synced lyrics from LRCLIB using the current song, artist, album and duration. Hides when paused or the notch is expanded.")
                .font(.caption).foregroundStyle(.secondary)
            if enabled {
                Toggle("Preview lyrics & animations", isOn: $preview)
                Text("Preview cycles through sample lines every three seconds. It turns off when you leave Settings.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show maximum lyric area outline", isOn: $showBounds)
                Text("The dashed box shows the exact maximum area on screen, even without music. It stays visible until you switch this off. Text wraps inside it; extra lines are truncated.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show artist and song", isOn: $trackInfo)

                Divider().opacity(0.15)
                Text("Appearance").font(.headline)
                Toggle("Show background", isOn: $background)
                HStack {
                    Text("Background opacity")
                    Spacer()
                    Text("\(Int((opacity * 100).rounded()))%").monospacedDigit()
                }
                Slider(value: $opacity, in: 0...1, step: 0.01).disabled(!background)
                Text("Zero opacity or background off leaves only the text. The area outline is controlled separately.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Font", selection: $fontFamily) {
                    Text("System").tag("system")
                    Text("Rounded").tag("rounded")
                    Text("Serif").tag("serif")
                    Text("Monospaced").tag("monospaced")
                    Divider()
                    ForEach(Self.families, id: \.self) { family in Text(family).tag("family:" + family) }
                    if fontFamily.hasPrefix("family:"), !Self.families.contains(String(fontFamily.dropFirst(7))) {
                        Text("Unavailable font (using System)").tag(fontFamily)
                    }
                }
                adjustment("Text size", value: $font, range: 12...48, step: 1, suffix: "pt")
                Picker("Text appearance", selection: $animation) {
                    Text("None").tag("none")
                    Text("Fade").tag("fade")
                    Text("Slide up").tag("slide")
                    Text("Pop").tag("pop")
                    Text("Typewriter").tag("typewriter")
                }
                if animation != "none" {
                    HStack {
                        Text("Animation duration")
                        Spacer()
                        Text(String(format: "%.2f s", duration)).monospacedDigit()
                    }
                    Slider(value: $duration, in: 0.1...2, step: 0.05)
                    Text("Shorter is faster. Respects macOS Reduce Motion.").font(.caption).foregroundStyle(.secondary)
                }

                Divider().opacity(0.15)
                Text("Area & position").font(.headline)
                adjustment("Maximum width", value: $width, range: 240...1000, step: 10, suffix: "pt")
                adjustment("Maximum height", value: $height, range: 100...500, step: 10, suffix: "pt")
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
                Button("Reset appearance, area & timing") {
                    font = 22; fontFamily = "system"; width = 520; height = 160; x = 0; y = 8; offset = 0.3
                    background = true; opacity = 0.82; animation = "fade"; duration = 0.25; showBounds = false
                }
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
