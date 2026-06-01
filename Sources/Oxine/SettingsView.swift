import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Binding var showSetup: Bool
    @ObservedObject var clipboardManager: ClipboardManager
    
    @AppStorage("launchAtLogin", store: UserDefaults(suiteName: "com.menubar.settings")) var launchAtLogin = true
    @AppStorage("showPreview", store: UserDefaults(suiteName: "com.menubar.settings")) var showPreview = true
    @AppStorage("maxItems", store: UserDefaults(suiteName: "com.menubar.settings")) var maxItems = 50
    @AppStorage("glassOpacity", store: UserDefaults(suiteName: "com.menubar.settings")) var glassOpacity = 0.7
    @AppStorage("panelSizePreset", store: UserDefaults(suiteName: "com.menubar.settings")) var panelSizePreset = OxinePanelSize.standard.rawValue
    @AppStorage("panelCustomWidth", store: UserDefaults(suiteName: "com.menubar.settings")) var panelCustomWidth = 380.0
    @AppStorage("panelCustomHeight", store: UserDefaults(suiteName: "com.menubar.settings")) var panelCustomHeight = 560.0
    @AppStorage("panelCustomLocked", store: UserDefaults(suiteName: "com.menubar.settings")) var panelCustomLocked = false
    @AppStorage("requireBiometricsForClipboard", store: UserDefaults(suiteName: "com.menubar.settings")) var requireClipboardAuth = false
    @AppStorage("requireBiometricsForNotes", store: UserDefaults(suiteName: "com.menubar.settings")) var requireNotesAuth = false
    @AppStorage("notesEditorBundleID", store: UserDefaults(suiteName: "com.menubar.settings")) var notesEditorBundleID = ""

    @StateObject private var justType = JustTypeSyncManager()
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var updater = UpdaterManager.shared

    /// Single source of truth for the displayed version — reads the bundle so it
    /// can never drift from what ships (and what Sparkle compares against).
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    @State var showClearConfirm = false
    @State var focusDimLevel = FocusModeManager.shared.overlayOpacity
    @State var focusBlurIntensity = FocusModeManager.shared.blurIntensity
    @State private var obsidianConfigured = ObsidianVaultManager.shared.isVaultConfigured
    @State private var obsidianIntegrating = false
    @State private var obsidianError: String?

    /// Selecting a preset switches to it. Re-clicking the already-active Custom
    /// toggles its lock (lock icon shown); a fresh switch to Custom starts unlocked.
    private func selectPanelSize(_ size: OxinePanelSize) {
        if size == .custom {
            if panelSizePreset == OxinePanelSize.custom.rawValue {
                panelCustomLocked.toggle()
            } else {
                panelSizePreset = OxinePanelSize.custom.rawValue
                panelCustomLocked = false
            }
        } else {
            panelSizePreset = size.rawValue
        }
        NotificationCenter.default.post(name: .panelSizeChanged, object: nil)
    }

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
            VStack(alignment: .leading, spacing: 10) {
                Text("Accent tint")
                    .foregroundColor(.white.opacity(0.85))
                Text("Colors buttons, highlights, and the default for new plugins.")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.5))

                HStack(spacing: 10) {
                    // Auto chip — follows the macOS system accent, live.
                    Button(action: { theme.setMode(ThemeManager.systemSentinel) }) {
                        ZStack {
                            Circle().fill(Color(nsColor: .controlAccentColor))
                            Image(systemName: "a.circle")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white.opacity(0.9))
                        }
                        .frame(width: 24, height: 24)
                        .overlay(Circle().stroke(.white, lineWidth: theme.isSystem ? 2 : 0))
                        .help("Match macOS accent color")
                    }
                    .buttonStyle(.plain)

                    Rectangle().fill(.white.opacity(0.1)).frame(width: 1, height: 20)

                    ForEach(PluginPalette.swatches, id: \.self) { hex in
                        Button(action: { theme.setMode(hex) }) {
                            Circle().fill(Color(hex: hex)).frame(width: 24, height: 24)
                                .overlay(Circle().stroke(.white, lineWidth: (!theme.isSystem && theme.mode == hex) ? 2 : 0))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var notesSection: some View {
        SettingSection(title: "Notes") {
            Toggle(isOn: biometricGate($requireNotesAuth, feature: "notes")) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Require Touch ID")
                        .foregroundColor(.white.opacity(0.85))
                    Text("Lock notes behind biometrics")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: Color.oxineAccent))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Button(action: { showSetup = true }) {
                        HStack {
                            Image(systemName: "wand.and.stars")
                                .foregroundColor(Color.oxineAccent)
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
                                .tint(Color.oxineAccent)
                        }
                    }

                    SettingSection(title: "Window") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Size")
                                .foregroundColor(.white.opacity(0.8))

                            HStack(spacing: 4) {
                                ForEach(OxinePanelSize.allCases) { size in
                                    let isActive = panelSizePreset == size.rawValue
                                    Button(action: { selectPanelSize(size) }) {
                                        HStack(spacing: 4) {
                                            Text(size.label)
                                                .font(.system(size: 11, weight: .medium))
                                            if size == .custom && isActive {
                                                Image(systemName: panelCustomLocked ? "lock.fill" : "lock.open")
                                                    .font(.system(size: 9))
                                            }
                                        }
                                        .foregroundColor(.white.opacity(isActive ? 0.9 : 0.4))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .fill(isActive
                                                      ? Color.oxineAccent.opacity(0.14)
                                                      : Color.white.opacity(0.04))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .stroke(.white.opacity(isActive ? 0.10 : 0.05), lineWidth: 0.5)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            if panelSizePreset == OxinePanelSize.custom.rawValue {
                                HStack(spacing: 6) {
                                    Image(systemName: panelCustomLocked ? "lock.fill" : "arrow.up.left.and.arrow.down.right")
                                        .font(.system(size: 10))
                                        .foregroundColor(.white.opacity(0.45))
                                    Text(panelCustomLocked
                                         ? "Locked. Click Custom again to unlock and resize."
                                         : "Drag the panel edges to resize, then click Custom to lock it.")
                                        .font(.system(size: 10))
                                        .foregroundColor(.white.opacity(0.4))
                                    Spacer()
                                    Text("\(Int(panelCustomWidth))×\(Int(panelCustomHeight))")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.35))
                                }
                                .fixedSize(horizontal: false, vertical: true)
                                .transition(.opacity)
                            }
                        }
                    }

appearanceSection

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
                        .toggleStyle(SwitchToggleStyle(tint: Color.oxineAccent))

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
                                .tint(Color.oxineAccent)
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
                                .tint(Color.oxineAccent)
                                .onChange(of: focusBlurIntensity) { _, newValue in
                                    FocusModeManager.shared.blurIntensity = newValue
                                }
                        }
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
                                            .foregroundColor(Color.oxineAccent)
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
                                    .foregroundColor(Color.oxineAccent)
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
                            .toggleStyle(SwitchToggleStyle(tint: Color.oxineAccent))

                            Button(action: { updater.checkForUpdates() }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                    Text("Check for Updates")
                                        .fontWeight(.medium)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .foregroundColor(Color.oxineAccent)
                                .font(.system(size: 12))
                                .background(Color.oxineAccent.opacity(0.10))
                                .cornerRadius(8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.oxineAccent.opacity(0.22), lineWidth: 0.5)
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
    @AppStorage("notesEditorBundleID", store: UserDefaults(suiteName: "com.menubar.settings")) private var editorBundleID = ""
    private var accent: Color { .oxineAccent }

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
    private var accent: Color { .oxineAccent }

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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                    )
            )
            .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}
