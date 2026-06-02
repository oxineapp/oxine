import SwiftUI
import PanelKit
import SousKit
import ServiceManagement

struct SettingsView: View {
    @Binding var showSetup: Bool
    @ObservedObject var clipboardManager: ClipboardManager
    
    @AppStorage("launchAtLogin", store: UserDefaults(suiteName: "com.oxine.settings")) var launchAtLogin = true
    @AppStorage("showPreview", store: UserDefaults(suiteName: "com.oxine.settings")) var showPreview = true
    @AppStorage("maxItems", store: UserDefaults(suiteName: "com.oxine.settings")) var maxItems = 50
    @AppStorage("glassOpacity", store: UserDefaults(suiteName: "com.oxine.settings")) var glassOpacity = 0.7
    @AppStorage("requireBiometricsForClipboard", store: UserDefaults(suiteName: "com.oxine.settings")) var requireClipboardAuth = false
    @AppStorage("requireBiometricsForNotes", store: UserDefaults(suiteName: "com.oxine.settings")) var requireNotesAuth = false
    @AppStorage("notesEditorBundleID", store: UserDefaults(suiteName: "com.oxine.settings")) var notesEditorBundleID = ""
    @AppStorage("notesFolderPath", store: UserDefaults(suiteName: "com.oxine.settings")) var notesFolderPath = ""
    @ObservedObject private var sous = SousManager.shared
    @ObservedObject private var tabConfig = TabBarConfig.shared
    @State private var editingTabs = false

    @StateObject private var justType = JustTypeSyncManager()
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var updater = UpdaterManager.shared

    /// Single source of truth for the displayed version — reads the bundle so it
    /// can never drift from what ships (and what Sparkle compares against).
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    /// Human label for the saved caffeine default, for the Settings menu button.
    private var defaultDurationLabel: String {
        CaffeineManager.presets.first { $0.seconds == caffeine.defaultDuration }?.label ?? "1 hour"
    }

    @State var showClearConfirm = false
    @State var focusDimLevel = FocusModeManager.shared.overlayOpacity
    @State var focusBlurIntensity = FocusModeManager.shared.blurIntensity
    @ObservedObject private var caffeine = CaffeineManager.shared
    @State private var obsidianConfigured = ObsidianVaultManager.shared.isVaultConfigured
    @State private var obsidianIntegrating = false
    @State private var obsidianError: String?

    /// One-click Obsidian integration from the Integrations pill — same auto-setup
    /// the onboarding tour runs.
    private func integrateObsidian() {
        guard !obsidianIntegrating else { return }
        obsidianError = nil
        obsidianIntegrating = true
        ObsidianVaultManager.shared.createVaultInObsidian { success, message in
            DispatchQueue.main.async {
                obsidianIntegrating = false
                if success {
                    obsidianConfigured = true
                } else {
                    obsidianError = message
                }
            }
        }
    }

    /// A toggle binding that requires Touch ID before changing — in *either*
    /// direction, so a lock can't be turned off (or on) without authenticating.
    /// On Macs without biometrics, `confirmWithBiometrics` passes through.
    private func biometricGate(_ stored: Binding<Bool>, feature: String) -> Binding<Bool> {
        Binding(
            get: { stored.wrappedValue },
            set: { newValue in
                guard newValue != stored.wrappedValue else { return }
                confirmWithBiometrics(reason: "\(newValue ? "Enable" : "Disable") the Touch ID lock for \(feature)") { ok in
                    if ok { stored.wrappedValue = newValue }
                }
            }
        )
    }

    private var appearanceSection: some View {
        SettingSection(title: "Appearance") {
            ThemeAccentPicker(subtitle: "Colors buttons, highlights, and the default for new scripts.")
        }
    }

    /// Pick a new notes folder (keeps the panel open during the modal, like the
    /// editor chooser). Re-points only — existing notes stay where they are.
    private func chooseNotesFolder() {
        let delegate = AppDelegate.instance
        delegate?.isAuthenticating = true
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.canCreateDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "Use Folder"
        openPanel.message = "Choose where Oxine stores your notes"
        openPanel.directoryURL = NotesLocation.url
        if openPanel.runModal() == .OK, let url = openPanel.url {
            NotesLocation.set(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { delegate?.isAuthenticating = false }
    }

    private var tabsSection: some View {
        SettingSection(title: "Tabs") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(get: { editingTabs },
                                     set: { v in withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { editingTabs = v } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Edit tab bar").foregroundColor(.white.opacity(0.85))
                        Text("Drag to reorder, drag down to remove, drag up to add.")
                            .font(.caption2).foregroundColor(.white.opacity(0.5))
                    }
                }
                .toggleStyle(SwitchToggleStyle(tint: Color.panelAccent))

                if editingTabs {
                    TabEditor(config: tabConfig)
                } else {
                    TabBarPreview(tabs: tabConfig.enabled)
                    Text("Every tab stays reachable from the menu-bar icon's right-click menu, even when it's off the bar.")
                        .font(.caption2).foregroundColor(.white.opacity(0.4))
                }
            }
        }
    }

    private var notesSection: some View {
        SettingSection(title: "Notes") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Location")
                    .foregroundColor(.white.opacity(0.85))
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundColor(Color.panelAccent)
                    Text(NotesLocation.displayPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    if !notesFolderPath.isEmpty {
                        Button("Reset") { NotesLocation.set(nil) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.5))
                            .help("Use the default (~/Documents/Oxine Notes)")
                    }
                    Button("Change") { chooseNotesFolder() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color.panelAccent)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(Color.panelAccent.opacity(0.12)))
                        .overlay(Capsule().stroke(Color.panelAccent.opacity(0.25), lineWidth: 0.5))
                        .contentShape(Capsule())
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06), lineWidth: 0.5))
                Text("Existing notes aren't moved — Oxine just reads from the new folder.")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.45))

                Divider().opacity(0.1)

                Toggle(isOn: biometricGate($requireNotesAuth, feature: "notes")) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Require Touch ID")
                            .foregroundColor(.white.opacity(0.85))
                        Text("Lock notes behind biometrics")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                .toggleStyle(SwitchToggleStyle(tint: Color.panelAccent))
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Button(action: { showSetup = true }) {
                        HStack {
                            Image(systemName: "wand.and.stars")
                                .foregroundColor(Color.panelAccent)
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
                                .tint(Color.panelAccent)
                        }
                    }

                    SettingSection(title: "Window") {
                        PanelSizeEditor()
                    }

                    appearanceSection

                    tabsSection

                    notesSection

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

                        Toggle(isOn: biometricGate($requireClipboardAuth, feature: "clipboard history")) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Require Touch ID")
                                    .foregroundColor(.white.opacity(0.85))
                                Text("Lock clipboard history behind biometrics")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.5))
                            }
                        }
                        .toggleStyle(SwitchToggleStyle(tint: Color.panelAccent))

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
                                .tint(Color.panelAccent)
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
                                .tint(Color.panelAccent)
                                .onChange(of: focusBlurIntensity) { _, newValue in
                                    FocusModeManager.shared.blurIntensity = newValue
                                }
                        }
                    }

                    SettingSection(title: "Caffeine") {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Keep Mac awake")
                                    .foregroundColor(.white.opacity(0.9))
                                Text(caffeine.isActive
                                    ? "Active · \(caffeine.statusText) remaining"
                                    : "Starts from the footer bolt")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            Spacer()
                            Menu {
                                ForEach(CaffeineManager.presets, id: \.label) { preset in
                                    Button {
                                        caffeine.defaultDuration = preset.seconds
                                    } label: {
                                        if caffeine.defaultDuration == preset.seconds {
                                            Label(preset.label, systemImage: "checkmark")
                                        } else {
                                            Text(preset.label)
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(defaultDurationLabel)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 9))
                                }
                                .foregroundColor(Color.panelAccent)
                                .font(.caption)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }

                        Divider().opacity(0.1)

                        Toggle(isOn: Binding(
                            get: { caffeine.keepAppsActive },
                            set: { caffeine.keepAppsActive = $0 }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Keep apps active")
                                    .foregroundColor(.white.opacity(0.9))
                                Text("Nudges input when idle so Teams/Slack stay available (needs Accessibility)")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.5))
                            }
                        }
                        .toggleStyle(.switch)
                        .tint(Color.panelAccent)
                    }

                    SettingSection(title: "Integrations") {
                        VStack(alignment: .leading, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Text editor")
                                    .foregroundColor(.white.opacity(0.9))
                                Text("Opens your .md notes")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            EditorChip()

                            // Obsidian-only: vault registration for the full experience.
                            if NotesEditor.isObsidian {
                                if obsidianConfigured {
                                    HStack(spacing: 6) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(Color.panelAccent)
                                            .font(.system(size: 12))
                                        Text("Obsidian vault ready")
                                            .font(.caption2)
                                            .foregroundColor(.white.opacity(0.6))
                                    }
                                } else {
                                    HStack {
                                        Text("Set up the Obsidian vault")
                                            .font(.caption2)
                                            .foregroundColor(.white.opacity(0.5))
                                        Spacer()
                                        IntegrateButton(isLoading: obsidianIntegrating, action: integrateObsidian)
                                    }
                                }
                                if let obsidianError {
                                    Text(obsidianError)
                                        .font(.caption2)
                                        .foregroundColor(.orange.opacity(0.9))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }

                        Divider().opacity(0.1)

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("justtype")
                                    .foregroundColor(.white.opacity(0.9))
                                Text(justType.isConfigured ? "Connected" : "Recommended · not connected")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            Spacer()
                            if justType.isConfigured {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(Color.panelAccent)
                            } else {
                                IntegrateButton(isLoading: justType.isSigningIn) { justType.signIn() }
                            }
                        }

                        if justType.isConfigured {
                            Button(action: { justType.disconnect() }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "rectangle.portrait.and.arrow.right")
                                    Text("Log out of justtype")
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
                    
                    SettingSection(title: "Sous · Battery") {
                        SousSettings(sous: sous)
                    }

                    SettingSection(title: "Software Update") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle(isOn: $updater.automaticallyChecks) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Check for updates automatically")
                                        .foregroundColor(.white.opacity(0.85))
                                    Text("Updates are signed and verified, then installed in place.")
                                        .font(.caption2)
                                        .foregroundColor(.white.opacity(0.5))
                                }
                            }
                            .toggleStyle(SwitchToggleStyle(tint: Color.panelAccent))

                            Button(action: { updater.checkForUpdates() }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                    Text("Check for Updates")
                                        .fontWeight(.medium)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .foregroundColor(Color.panelAccent)
                                .font(.system(size: 12))
                                .background(Color.panelAccent.opacity(0.10))
                                .cornerRadius(8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.panelAccent.opacity(0.22), lineWidth: 0.5)
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(!updater.canCheckForUpdates)
                            .opacity(updater.canCheckForUpdates ? 1 : 0.5)
                        }
                    }

                    SettingSection(title: "About") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Version")
                                    .foregroundColor(.white.opacity(0.8))
                                Spacer()
                                Text(appVersion)
                                    .foregroundColor(.white.opacity(0.5))
                                    .font(.caption)
                            }
                            
                            HStack {
                                Text("App Name")
                                    .foregroundColor(.white.opacity(0.8))
                                Spacer()
                                Text("Oxine")
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

                    Button(action: { NSApplication.shared.terminate(nil) }) {
                        HStack(spacing: 8) {
                            Image(systemName: "power")
                            Text("Quit Oxine")
                                .fontWeight(.medium)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .foregroundColor(.white.opacity(0.7))
                        .font(.system(size: 12))
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
                .padding(8)
            }
        }
        .onAppear { obsidianConfigured = ObsidianVaultManager.shared.isVaultConfigured }
        .alert("Clear all history?", isPresented: $showClearConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                confirmWithBiometrics(reason: "Confirm clearing all clipboard history") { ok in
                    if ok { clipboardManager.clearHistory() }
                }
            }
        } message: {
            Text("This cannot be undone. You'll confirm with Touch ID.")
        }
    }
}

/// Shows the app that opens the user's `.md` notes (its icon + name) with a
/// Change button to pick any other app. Shared by onboarding and Settings.
struct EditorChip: View {
    /// Bound to the same key NotesEditor stores under, so a pick re-renders us.
    @AppStorage("notesEditorBundleID", store: UserDefaults(suiteName: "com.oxine.settings")) private var editorBundleID = ""
    private var accent: Color { .panelAccent }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = NotesEditor.appIcon() {
                    Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                } else {
                    Image(systemName: "doc.text")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 22, height: 22)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(NotesEditor.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Text(NotesEditor.selectedBundleID == nil ? "System default for .md" : "Your choice")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.45))
            }
            Spacer()
            if NotesEditor.selectedBundleID != nil {
                Button(action: {
                    NotesEditor.resetToDefault()
                    editorBundleID = ""
                }) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Use the system default")
            }
            Button("Change") {
                // Pin the panel open while the (modal) app chooser is up, else
                // resignActive/global-click dismisses it mid-selection.
                let delegate = AppDelegate.instance
                delegate?.isAuthenticating = true
                _ = NotesEditor.pickApp()
                editorBundleID = NotesEditor.selectedBundleID ?? ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    delegate?.isAuthenticating = false
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(accent.opacity(0.12)))
            .overlay(Capsule().stroke(accent.opacity(0.25), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06), lineWidth: 0.5))
    }
}

/// Compact one-click "Integrate" pill shown on an integration row that isn't set
/// up yet. Whole pill is tappable (explicit content shape).
struct IntegrateButton: View {
    var isLoading: Bool
    let action: () -> Void
    private var accent: Color { .panelAccent }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isLoading {
                    ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                } else {
                    Image(systemName: "plus.circle.fill").font(.system(size: 11, weight: .semibold))
                }
                Text(isLoading ? "Integrating…" : "Integrate")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(accent.opacity(0.12)))
            .overlay(Capsule().stroke(accent.opacity(0.25), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}

