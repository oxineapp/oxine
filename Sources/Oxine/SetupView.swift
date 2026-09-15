import SwiftUI
import PanelKit
import SousKit
import TemperKit

struct SetupView: View {
    @State var currentStep = 0
    @State var isLoading = false
    /// Tracks nav direction so Back slides opposite to Next.
    @State private var goingForward = true
    var onComplete: () -> Void

    /// Welcome, Editor, justtype, Sous, Temper, [Notch], Apps, Tabs. The Notch
    /// step is inserted only on Macs that have a hardware notch (for now).
    static let baseStepCount = 7
    /// Only offer the notch on Macs that physically have one.
    private var hasNotch: Bool { NSScreen.screens.contains { $0.safeAreaInsets.top > 0 } }
    private var stepCount: Int { hasNotch ? SetupView.baseStepCount + 1 : SetupView.baseStepCount }
    private var lastStep: Int { stepCount - 1 }

    /// Steps slide along the nav direction: Next enters from the right, Back from the left.
    private var stepTransition: AnyTransition {
        goingForward
            ? .asymmetric(insertion: .opacity.combined(with: .move(edge: .trailing)),
                          removal: .opacity.combined(with: .move(edge: .leading)))
            : .asymmetric(insertion: .opacity.combined(with: .move(edge: .leading)),
                          removal: .opacity.combined(with: .move(edge: .trailing)))
    }

    /// True on the final step, where the tour card shrinks to the bottom and the
    /// real editable tab bar leaks through on the glass panel above it.
    private var leaking: Bool { currentStep == lastStep }

    var body: some View {
        Group {
            if leaking { tabLeakLayout } else { standardLayout }
        }
        // Solid for the normal steps; clear on the last step so the panel's glass
        // (and the editable bar laid on it) shows through above the shrunken card.
        .background(leaking ? Color.clear : Color(red: 0.06, green: 0.06, blue: 0.08))
        .animation(.spring(response: 0.42, dampingFraction: 0.84), value: leaking)
    }

    // MARK: layouts

    private var standardLayout: some View {
        VStack(spacing: 0) {
            HStack {
                progressDots
                Spacer()
                skipButton
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            VStack {
                if currentStep == 0 {
                    Step1Welcome().transition(stepTransition)
                } else if currentStep == 1 {
                    Step2Obsidian(isLoading: $isLoading).transition(stepTransition)
                } else if currentStep == 2 {
                    Step3JustType().transition(stepTransition)
                } else if currentStep == 3 {
                    Step4Sous().transition(stepTransition)
                } else if currentStep == 4 {
                    Step5Temper().transition(stepTransition)
                } else if currentStep == 5, hasNotch {
                    // Notch Macs only: enable or disable the notch companion.
                    Step6Notch().transition(stepTransition)
                } else {
                    // The installable extras (ScreenLyrics, FnGestures); the
                    // leak/Tabs step follows as the last one.
                    Step7Apps(hasNotch: hasNotch).transition(stepTransition)
                }
            }
            .frame(maxHeight: .infinity)

            navButtons
                .padding(20)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
    }

    private var tabLeakLayout: some View {
        ZStack(alignment: .bottom) {
            // The editable bar sits at the TRUE top of the panel — where the tab
            // bar actually lives — with the tray in the revealed space below it.
            // This is the panel leaking through, not a widget boxed in a card.
            VStack(spacing: 0) {
                TabEditor()
                    .padding(.horizontal, 14)
                    .padding(.top, 16)
                Spacer(minLength: 0)
            }
            .transition(.opacity)

            // The tour card, shrunk to the bottom and fading in at its top edge so
            // the panel above shows through — the "decrease in height + leak" look.
            VStack(spacing: 12) {
                Text("Make it yours")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                progressDots
                navButtons
            }
            .padding(.horizontal, 22)
            .padding(.top, 44)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
            .background(
                Color(red: 0.06, green: 0.06, blue: 0.08).mask(
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .black, location: 0.5),
                            .init(color: .black, location: 1.0)]),
                        startPoint: .top, endPoint: .bottom)
                )
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: shared pieces

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<stepCount, id: \.self) { step in
                Capsule()
                    .fill(step <= currentStep ? Color.panelAccent : Color.white.opacity(0.12))
                    .frame(height: 3)
                    .shadow(color: Color.panelAccent.opacity(step <= currentStep ? 0.4 : 0.0), radius: 2)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: currentStep)
            }
        }
    }

    private var skipButton: some View {
        Button(action: {
            SetupManager.shared.markSetupComplete()
            onComplete()
        }) {
            Text("Skip").font(.caption).foregroundColor(.white.opacity(0.5))
        }
        .buttonStyle(.plain)
    }

    private var navButtons: some View {
        HStack(spacing: 12) {
            if currentStep > 0 {
                Button(action: {
                    goingForward = false
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { currentStep -= 1 }
                }) {
                    Text("Back")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundColor(.white.opacity(0.8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.08), lineWidth: 0.5))
                .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .leading)), removal: .opacity))
            }

            Button(action: {
                if currentStep < lastStep {
                    goingForward = true
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { currentStep += 1 }
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        SetupManager.shared.markSetupComplete()
                        onComplete()
                    }
                }
            }) {
                HStack(spacing: 6) {
                    if isLoading {
                        ProgressView().scaleEffect(0.7).transition(.scale.combined(with: .opacity))
                    }
                    Text(currentStep < lastStep ? "Next" : "Finish")
                        .font(.system(size: 13, weight: .bold))
                        .transition(.opacity)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.panelAccent.opacity(0.15)))
            .disabled(isLoading)
            .scaleEffect(isLoading ? 0.98 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isLoading)
        }
    }
}

struct Step1Welcome: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 38))
                .foregroundColor(Color.panelAccent)
            VStack(spacing: 6) {
                Text("Welcome to Oxine")
                    .font(.system(size: 20, weight: .bold))
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                Text("Clipboard, notes, 2FA codes, and battery care, right in your menu bar")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 9) {
                FeatureRow(icon: "clipboard", title: "Clipboard History", desc: "Save up to 200 items")
                FeatureRow(icon: "note.text", title: "Notes", desc: "Quick + Markdown, in any editor")
                FeatureRow(icon: "lock.shield", title: "2FA Codes", desc: "Your authenticator, built in")
                FeatureRow(icon: "terminal", title: "Scripts", desc: "One-tap actions and shortcuts")
                FeatureRow(icon: "heart.badge.bolt", title: "Battery Care", desc: "Cap charging to extend its life")
                FeatureRow(icon: "fanblades.fill", title: "Temper", desc: "Temps, throttling, and fan control")
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.03)))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(LinearGradient(colors: [.white.opacity(0.12), .white.opacity(0.02)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.5)
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }
}

struct Step2Obsidian: View {
    @Binding var isLoading: Bool
    @State var isSetup = false
    @State var errorMessage: String?
    /// Re-read NotesEditor when the choice changes (Obsidian section appears/disappears).
    @AppStorage("notesEditorBundleID", store: UserDefaults(suiteName: "com.oxine.settings")) private var editorBundleID = ""
    /// Bumped on .notesEditorChanged to force this header (icon/name/"what
    /// happens" text, all read from NotesEditor) to re-render after a pick.
    @State private var editorTick = 0
    private var accent: Color { .panelAccent }

    var body: some View {
        VStack(spacing: 12) {
            Group {
                if let icon = NotesEditor.appIcon() {
                    Image(nsImage: icon).resizable().frame(width: 40, height: 40)
                } else {
                    Image(systemName: "doc.text").font(.system(size: 36)).foregroundColor(accent)
                }
            }
            VStack(spacing: 6) {
                Text("Your Editor")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(.white)
                Text("Notes are plain Markdown — open them in any app you like.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }

            EditorChip()

            HStack(spacing: 5) {
                Image(systemName: "sparkles").font(.system(size: 9))
                Text("Obsidian has extended support — vault, tags & deep links.")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(accent.opacity(0.85))
            .multilineTextAlignment(.center)

            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.orange.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(Color.orange.opacity(0.08))
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.15), lineWidth: 0.5))
            }

            // Obsidian gets the extra vault treatment; other editors need nothing.
            if NotesEditor.isObsidian {
                if isSetup {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Color(red: 0.3, green: 0.85, blue: 0.5))
                        Text("Obsidian vault ready!")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Color.green.opacity(0.08))
                    .cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.green.opacity(0.2), lineWidth: 0.5))
                } else {
                    Button(action: setupObsidian) {
                        HStack {
                            if isLoading { ProgressView().scaleEffect(0.7) }
                            else { Image(systemName: "checkmark.circle") }
                            Text("Auto-Setup Obsidian Vault").fontWeight(.semibold)
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .foregroundColor(accent)
                        .background(accent.opacity(0.12))
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(0.25), lineWidth: 0.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("What happens:")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.4))
                    .textCase(.uppercase).tracking(0.5)
                Text(NotesEditor.isObsidian
                     ? "Notes live in \(NotesLocation.displayPath), opened as an Obsidian vault with tags and metadata."
                     : "Notes live in \(NotesLocation.displayPath) as clean .md files, opened in \(NotesEditor.displayName).")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.65))
                    .lineSpacing(4)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.03))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(LinearGradient(colors: [.white.opacity(0.12), .white.opacity(0.02)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.5)
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .id(editorTick)
        .onReceive(NotificationCenter.default.publisher(for: .notesEditorChanged)) { _ in
            editorTick &+= 1
        }
    }

    private func setupObsidian() {
        errorMessage = nil
        isLoading = true
        ObsidianVaultManager.shared.createVaultInObsidian { success, message in
            DispatchQueue.main.async {
                isLoading = false
                if success {
                    isSetup = true
                } else {
                    errorMessage = message
                }
            }
        }
    }
}

struct Step3JustType: View {
    @StateObject var sync = JustTypeSyncManager()

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "cloud.fill")
                .font(.system(size: 36))
                .foregroundColor(Color.panelAccent)
            VStack(spacing: 6) {
                Text("justtype Sync")
                    .font(.system(size: 19, weight: .bold))
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                Text("Sync local Markdown notes with private justtype slates.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                Text("RECOMMENDED")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundColor(Color.panelAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.panelAccent.opacity(0.15)))
                    .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Recommended grant")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.4))
                    .textCase(.uppercase)
                    .tracking(0.5)
                Text("Allow full private slate access when justtype asks. The read-private grant is also what lets this app edit delegated private slates.")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(Color.white.opacity(0.035))
            .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 10))

            VStack(spacing: 7) {
                Button(action: { sync.signIn() }) {
                    Text(sync.isSigningIn ? "Connecting..." : (sync.isConfigured ? "Connected" : "Connect justtype"))
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundColor(Color.panelAccent)
                        .background(Color.panelAccent.opacity(0.1))
                        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(sync.isSigningIn || sync.isConfigured)

                Text(sync.status)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.35))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
    }
}

/// Battery health setup — installs the privileged Sous helper (one admin
/// prompt) so charging can be capped. Mirrors the setup flow in `SousView`, and
/// degrades gracefully on Intel / battery-less Macs where Sous can't run.
struct Step4Sous: View {
    @ObservedObject private var sous = SousManager.shared
    private var accent: Color { .panelAccent }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "heart.badge.bolt")
                .font(.system(size: 36))
                .foregroundColor(accent)
            VStack(spacing: 6) {
                Text("Sous · Battery Health")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(.white)
                Text("Cap how far your battery charges to slow long-term wear and keep it healthy.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                Text("OPTIONAL")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .padding(.top, 2)
            }

            switch sous.helper.installState {
            case .unsupported:
                infoCard(text: BatteryReader.isAppleSilicon
                         ? "No battery detected — Sous needs a MacBook battery to manage. You can skip this."
                         : "Sous controls charging through Apple Silicon hardware and isn’t available on Intel Macs. You can skip this.")

            case .installed:
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Color(red: 0.3, green: 0.85, blue: 0.5))
                    Text("Battery helper ready!")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Color.green.opacity(0.08))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.green.opacity(0.2), lineWidth: 0.5))
                infoCard(text: "Open the Sous tab any time to set your charge limit, sailing range and heat protection.")

            case .installing:
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Enter your Mac password in the prompt to install the helper. This happens once.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(11)
                .background(Color.white.opacity(0.035))
                .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 10))

            case .notInstalled, .failed:
                infoCard(text: "Sous installs a small background helper that controls charging — macOS will ask for your password once to allow it.")
                if case .failed(let msg) = sous.helper.installState {
                    Text(msg)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.orange.opacity(0.9))
                        .multilineTextAlignment(.center)
                }
                Button(action: { Task { await sous.helper.install(); sous.refreshNow() } }) {
                    Text("Install battery helper")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .foregroundColor(accent)
                        .background(accent.opacity(0.12))
                        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .onAppear { sous.refreshNow() }
    }

    private func infoCard(text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white.opacity(0.65))
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(Color.white.opacity(0.035))
            .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Thermal + fans. Monitoring works on every Mac with no helper, so this step
/// always shows the live state; installing the privileged Temper helper (one
/// admin prompt) is what unlocks fan control, and only where the hardware has
/// controllable fans. Mirrors the install flow in `TemperView`.
struct Step5Temper: View {
    @ObservedObject private var temper = TemperManager.shared
    private var accent: Color { .panelAccent }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "fanblades.fill")
                .font(.system(size: 36))
                .foregroundColor(accent)
            VStack(spacing: 6) {
                Text("Temper · Thermal & Fans")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(.white)
                Text("Watch temperatures, CPU load, and thermal pressure on any Mac. Install the fan helper to take control where the hardware allows.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                Text("OPTIONAL")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .padding(.top, 2)
            }

            if !temper.fansPresent {
                // Fanless Mac (an Air, say): nothing to control, so it runs purely
                // as a thermal + performance dashboard - no helper, no prompt.
                infoCard(text: "This Mac has no user-controllable fans, so Temper runs as a thermal and performance dashboard. No helper needed - just open the Temper tab.")
            } else {
                switch temper.helper.installState {
                case .installed:
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Color(red: 0.3, green: 0.85, blue: 0.5))
                        Text("Fan helper ready!")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Color.green.opacity(0.08))
                    .cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.green.opacity(0.2), lineWidth: 0.5))
                    infoCard(text: "Open the Temper tab any time to set fans to Manual, an adaptive Smart mode, or a custom curve.")

                case .installing:
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Enter your Mac password in the prompt to install the helper. This happens once.")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(11)
                    .background(Color.white.opacity(0.035))
                    .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 10))

                case .notInstalled, .failed:
                    infoCard(text: "Fan control installs a small background helper - macOS will ask for your password once to allow it. You can skip this and still see every reading.")
                    if case .failed(let msg) = temper.helper.installState {
                        Text(msg)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(.orange.opacity(0.9))
                            .multilineTextAlignment(.center)
                    }
                    Button(action: { Task { await temper.helper.install(); temper.refreshNow() } }) {
                        Text("Install fan helper")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .foregroundColor(accent)
                            .background(accent.opacity(0.12))
                            .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .onAppear { temper.setViewActive(true); temper.refreshNow() }
        .onDisappear { temper.setViewActive(false) }
    }

    private func infoCard(text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white.opacity(0.65))
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(Color.white.opacity(0.035))
            .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Final tour step: compose the tab bar. A live preview sits above the same
/// add / remove / reorder editor used in Settings, so the last thing you do in
/// setup is make the bar yours. Re-runnable from Settings → Tabs.
struct Step5Tabs: View {
    private var accent: Color { .panelAccent }
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 34))
                .foregroundColor(accent)
            VStack(spacing: 6) {
                Text("Make it yours")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(.white)
                Text("Pick the tabs you want on the bar and set their order. You can change this any time in Settings.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            // No ScrollView — the drag gesture shouldn't fight a scroll view, and
            // the composer fits the step.
            TabEditor().padding(.top, 4)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
    }
}

/// Notch companion step (notch Macs only): a single enable/disable choice for
/// the media + mirror + shelf surface at the top of the screen.
struct Step6Notch: View {
    @AppStorage("notchEnabled", store: UserDefaults(suiteName: "com.oxine.settings")) private var notchEnabled = true
    private var accent: Color { .panelAccent }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "macbook.gen2")
                .font(.system(size: 34))
                .foregroundColor(accent)
            VStack(spacing: 6) {
                Text("The Notch")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(.white)
                Text("A companion at your Mac's notch: now playing, a webcam mirror, and a drop shelf, all on hover.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                Text("OPTIONAL")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .padding(.top, 2)
            }

            Toggle(isOn: $notchEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(notchEnabled ? "Notch enabled" : "Notch disabled")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Text("You can change this any time in Settings › Notch.")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: accent))
            .padding(12)
            .background(Color.white.opacity(0.035))
            .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 10))
            .onChange(of: notchEnabled) { _, _ in
                NotificationCenter.default.post(name: .notchSettingsChanged, object: nil)
            }

            FeatureRow(icon: "music.note", title: "Now Playing", desc: "Artwork, scrubber, transport")
            FeatureRow(icon: "camera", title: "Mirror", desc: "A quick webcam self-view")
            FeatureRow(icon: "tray.and.arrow.down", title: "Shelf", desc: "Drag files in, AirDrop out")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
    }
}

/// Apps step. A row of app icons with names, like a launcher: Sous, Temper,
/// ScreenLyrics, FnGestures, then dashed slots for the curated shelf. Hovering
/// an icon fills a fixed-height card underneath with what it is, who made it,
/// and its install state — the step never changes size.
struct Step7Apps: View {
    var hasNotch: Bool
    @ObservedObject private var manager = AppsManager.shared
    @State private var selected: String = "oxine.sous"
    private var accent: Color { .panelAccent }

    /// What the grid shows, in order: built-ins first, then installables.
    private var entries: [Entry] {
        var out: [Entry] = []
        for id in ["oxine.sous", "oxine.temper"] {
            if let a = manager.app(id) { out.append(Entry(id: id, manifest: a.manifest, builtin: true)) }
        }
        for id in (hasNotch ? ["oxine.screenlyrics", "oxine.fngestures"] : ["oxine.fngestures"]) {
            if let e = BundledApps.entry(id) { out.append(Entry(id: id, manifest: e.manifest, builtin: false)) }
        }
        return out
    }
    private struct Entry: Identifiable { let id: String; let manifest: AppManifest; let builtin: Bool }
    private static let soonID = "__soon"

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 34))
                .foregroundColor(accent)
            VStack(spacing: 6) {
                Text("Apps")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(.white)
                Text("Add-ons you install and remove in Settings → Apps. Each has its own page and only the access it declares.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("OPTIONAL")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .padding(.top, 2)
            }

            HStack(alignment: .top, spacing: 6) {
                ForEach(entries) { e in
                    iconCell(id: e.id, symbol: e.manifest.icon ?? "shippingbox", name: e.manifest.name)
                }
                ForEach(0..<2, id: \.self) { i in
                    iconCell(id: Self.soonID + "\(i)", symbol: "plus", name: "Soon", placeholder: true)
                }
            }
            .padding(.top, 4)

            detailCard
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .onAppear { if manager.featured == nil { Task { await manager.fetchFeatured() } } }
    }

    // MARK: Icons

    private func iconCell(id: String, symbol: String, name: String, placeholder: Bool = false) -> some View {
        let isSelected = selected == id
        return VStack(spacing: 6) {
            ZStack {
                if placeholder {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(isSelected ? 0.3 : 0.14),
                                      style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.25))
                } else {
                    AppIconTile(symbol: symbol, size: 50)
                }
            }
            .frame(width: 50, height: 50)
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(accent.opacity(isSelected && !placeholder ? 0.9 : 0), lineWidth: 1.5)
                .padding(-3))
            .scaleEffect(isSelected ? 1.06 : 1)
            Text(name)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(.white.opacity(placeholder ? 0.35 : (isSelected ? 0.95 : 0.7)))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { selected = id } }
        }
        .onTapGesture { withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { selected = id } }
    }

    // MARK: Detail

    /// Fixed height so hovering between icons never moves the buttons below.
    private var detailCard: some View {
        ZStack(alignment: .topLeading) {
            if selected.hasPrefix(Self.soonID) {
                soonDetail
            } else if let e = entries.first(where: { $0.id == selected }) {
                appDetail(e)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 112)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(accent.opacity(0.25), lineWidth: 0.5))
        .animation(.easeInOut(duration: 0.18), value: selected)
    }

    private func appDetail(_ e: Entry) -> some View {
        let installed = e.builtin || manager.app(e.id) != nil
        let needsAccess = e.id == "oxine.fngestures" && installed && !FnGestureEngine.accessibilityGranted
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(e.manifest.name).font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                if let author = e.manifest.author {
                    Text("by \(author)").font(.system(size: 10.5, weight: .medium)).foregroundColor(accent.opacity(0.9))
                }
                Spacer()
                if needsAccess {
                    smallButton("Grant Accessibility", tint: .orange) { FnGestureEngine.requestAccessibility() }
                } else if e.builtin {
                    Text("Built in").font(.system(size: 10, weight: .semibold)).foregroundColor(.white.opacity(0.4))
                } else if installed {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill"); Text("Installed")
                    }
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(Color(red: 0.3, green: 0.85, blue: 0.5))
                } else if let entry = BundledApps.entry(e.id) {
                    smallButton("Install", tint: accent, filled: true) {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { manager.installBundled(entry) }
                    }
                }
            }
            Text(e.manifest.description ?? e.manifest.tagline ?? "")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.65))
                .lineSpacing(3)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .transition(.opacity)
        .id(e.id)
    }

    private var soonDetail: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Curated").font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                Text("coming soon").font(.system(size: 10.5, weight: .medium)).foregroundColor(.white.opacity(0.4))
            }
            Text("Apps picked by the Oxine team will sit here. Anything on GitHub tagged oxine-app installs from Settings → Apps too, after you see what it asks for.")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.65))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .transition(.opacity)
        .id("soon")
    }

    private func smallButton(_ title: String, tint: Color, filled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundColor(filled ? .white : tint)
                .background(Capsule().fill(filled ? tint.opacity(0.9) : tint.opacity(0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let desc: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundColor(Color.panelAccent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                Text(desc).font(.system(size: 10, weight: .medium)).foregroundColor(.white.opacity(0.5))
            }
            Spacer()
        }
    }
}
