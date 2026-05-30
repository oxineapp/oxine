import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Binding var showSetup: Bool
    @ObservedObject var clipboardManager: ClipboardManager
    
    @AppStorage("launchAtLogin", store: UserDefaults(suiteName: "com.menubar.settings")) var launchAtLogin = true
    @AppStorage("showPreview", store: UserDefaults(suiteName: "com.menubar.settings")) var showPreview = true
    @AppStorage("maxItems", store: UserDefaults(suiteName: "com.menubar.settings")) var maxItems = 50
    @AppStorage("glassOpacity", store: UserDefaults(suiteName: "com.menubar.settings")) var glassOpacity = 0.7
    
    @State var showClearConfirm = false
    @State var focusDimLevel = FocusModeManager.shared.overlayOpacity
    @State var focusBlurIntensity = FocusModeManager.shared.blurIntensity
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Button(action: { showSetup = true }) {
                        HStack {
                            Image(systemName: "wand.and.stars")
                                .foregroundColor(Color(red: 0.4, green: 0.85, blue: 1.0))
                            Text("Re-run Setup")
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white.opacity(0.3))
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .foregroundColor(.white)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.white.opacity(0.04))
                        )
                    }
                    .buttonStyle(.plain)
                    
                    SettingSection(title: "General") {
                        Toggle("Launch at login", isOn: $launchAtLogin)
                            .onChange(of: launchAtLogin) { _, enabled in
                                do {
                                    if enabled {
                                        try SMAppService.mainApp.register()
                                    } else {
                                        try SMAppService.mainApp.unregister()
                                    }
                                } catch {
                                    print("[LaunchAtLogin] Failed: \(error)")
                                }
                            }
                        Toggle("Show item preview", isOn: $showPreview)

                        Divider().opacity(0.1)

                        VStack(spacing: 6) {
                            HStack {
                                Text("Glass tint")
                                    .foregroundColor(.white.opacity(0.8))
                                Spacer()
                                Text("\(Int(glassOpacity * 100))%")
                                    .foregroundColor(.white.opacity(0.4))
                                    .font(.caption)
                            }
                            Slider(value: $glassOpacity, in: 0.0...1.0, step: 0.02)
                                .tint(Color(red: 0.4, green: 0.85, blue: 1.0))
                        }
                    }
                    
SettingSection(title: "Clipboard") {
                        HStack {
                            Text("Max items to store")
                                .foregroundColor(.white.opacity(0.8))
                            Spacer()
                            Picker("", selection: $maxItems) {
                                Text("25").tag(25)
                                Text("50").tag(50)
                                Text("100").tag(100)
                                Text("200").tag(200)
                            }
                            .frame(width: 80)
                        }
                        
                        Divider()
                            .opacity(0.1)
                        
                        Button(action: { showClearConfirm = true }) {
                            HStack(spacing: 8) {
                                Image(systemName: "trash.fill")
                                Text("Clear All History")
                                    .fontWeight(.medium)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundColor(.red.opacity(0.85))
                            .font(.system(size: 12))
                            .background(Color.red.opacity(0.08))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.red.opacity(0.15), lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: { NSPasteboard.general.clearContents() }) {
                            HStack(spacing: 8) {
                                Image(systemName: "xmark.circle")
                                Text("Clear Clipboard")
                                    .fontWeight(.medium)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundColor(.white.opacity(0.75))
                            .font(.system(size: 12))
                            .background(Color.white.opacity(0.04))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    
                    SettingSection(title: "Focus") {
                        VStack(spacing: 6) {
                            HStack {
                                Text("Dim level")
                                    .foregroundColor(.white.opacity(0.8))
                                Spacer()
                                Text("\(Int(focusDimLevel * 100))%")
                                    .foregroundColor(.white.opacity(0.4))
                                    .font(.caption)
                            }
                            Slider(value: $focusDimLevel, in: 0.0...0.8, step: 0.05)
                                .tint(Color(red: 0.4, green: 0.85, blue: 1.0))
                                .onChange(of: focusDimLevel) { _, newValue in
                                    FocusModeManager.shared.overlayOpacity = newValue
                                }
                        }

                        Divider().opacity(0.1)

                        VStack(spacing: 6) {
                            HStack {
                                Text("Blur intensity")
                                    .foregroundColor(.white.opacity(0.8))
                                Spacer()
                                Text("\(Int(focusBlurIntensity * 100))%")
                                    .foregroundColor(.white.opacity(0.4))
                                    .font(.caption)
                            }
                            Slider(value: $focusBlurIntensity, in: 0.0...1.0, step: 0.05)
                                .tint(Color(red: 0.4, green: 0.85, blue: 1.0))
                                .onChange(of: focusBlurIntensity) { _, newValue in
                                    FocusModeManager.shared.blurIntensity = newValue
                                }
                        }
                    }

                    SettingSection(title: "Integrations") {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Obsidian")
                                    .foregroundColor(.white.opacity(0.9))
                                Text("~/Documents/MenuBar Notes")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(Color(red: 0.4, green: 0.85, blue: 1.0))
                        }
                    }
                    
                    SettingSection(title: "Keyboard Shortcuts") {
                        HStack {
                            Text("Toggle popup")
                                .foregroundColor(.white.opacity(0.8))
                            Spacer()
                            Text("⇧⌘V")
                                .font(.caption)
                                .padding(4)
                                .background(Color.white.opacity(0.1))
                                .cornerRadius(4)
                        }
                        
                    }
                    
                    SettingSection(title: "About") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Version")
                                    .foregroundColor(.white.opacity(0.8))
                                Spacer()
                                Text("2.2.0")
                                    .foregroundColor(.white.opacity(0.5))
                                    .font(.caption)
                            }
                            
                            HStack {
                                Text("App Name")
                                    .foregroundColor(.white.opacity(0.8))
                                Spacer()
                                Text("MenuBar")
                                    .foregroundColor(.white.opacity(0.5))
                                    .font(.caption)
                            }
                            
                            HStack {
                                Text("Auth Engine")
                                    .foregroundColor(.white.opacity(0.8))
                                Spacer()
                                Text("@alfaoz/menuauth")
                                    .foregroundColor(.white.opacity(0.5))
                                    .font(.caption)
                            }
                            
                        }
                    }
                    
                    Spacer()
                }
                .padding(8)
            }
        }
        .alert("Clear all history?", isPresented: $showClearConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                clipboardManager.clearHistory()
            }
        } message: {
            Text("This cannot be undone.")
        }
    }
}

struct SettingSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.4))
                .textCase(.uppercase)
                .tracking(1.0)
                .padding(.leading, 4)
            
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.04))
            )
            .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
