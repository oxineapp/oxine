import SwiftUI
import AppKit
import PanelKit
import SousKit

/// sous-vide's Settings — the same theme selector and size editor as Oxine
/// (the shared PanelKit components), plus the Sous controls, updates, and about.
struct SousVideSettings: View {
    @ObservedObject private var sous = SousManager.shared
    @ObservedObject private var updater = UpdaterManager.shared
    @AppStorage("glassOpacity", store: PanelKit.settingsDefaults) private var glassOpacity = 0.7

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingSection(title: "General") {
                    VStack(spacing: 6) {
                        HStack {
                            Text("Glass tint").foregroundColor(.white.opacity(0.8))
                            Spacer()
                            Text("\(Int(glassOpacity * 100))%").foregroundColor(.white.opacity(0.4)).font(.caption)
                        }
                        Slider(value: $glassOpacity, in: 0.0...1.0, step: 0.02).tint(Color.panelAccent)
                    }
                }

                SettingSection(title: "Window") {
                    PanelSizeEditor()
                }

                SettingSection(title: "Appearance") {
                    ThemeAccentPicker()
                }

                SettingSection(title: "Sous · Battery") {
                    SousSettings(sous: sous)
                }

                SettingSection(title: "Software Update") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $updater.automaticallyChecks) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Check for updates automatically").foregroundColor(.white.opacity(0.85))
                                Text("Updates are signed and verified, then installed in place.")
                                    .font(.caption2).foregroundColor(.white.opacity(0.5))
                            }
                        }
                        .toggleStyle(SwitchToggleStyle(tint: Color.panelAccent))

                        Button(action: { updater.checkForUpdates() }) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                Text("Check for Updates").fontWeight(.medium)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .foregroundColor(Color.panelAccent).font(.system(size: 12))
                            .background(Color.panelAccent.opacity(0.10)).cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.panelAccent.opacity(0.22), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .disabled(!updater.canCheckForUpdates)
                        .opacity(updater.canCheckForUpdates ? 1 : 0.5)
                    }
                }

                SettingSection(title: "About") {
                    HStack {
                        Text("Version").foregroundColor(.white.opacity(0.8))
                        Spacer()
                        Text(appVersion).foregroundColor(.white.opacity(0.5)).font(.caption)
                    }
                }

                Button(action: { NSApplication.shared.terminate(nil) }) {
                    HStack(spacing: 8) {
                        Image(systemName: "power")
                        Text("Quit sous-vide").fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .foregroundColor(.white.opacity(0.7)).font(.system(size: 12))
                    .background(Color.white.opacity(0.04)).cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(8)
        }
    }
}
