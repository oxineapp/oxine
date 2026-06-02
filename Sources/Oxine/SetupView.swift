import SwiftUI
import PanelKit
import SousKit

struct SetupView: View {
    @State var currentStep = 0
    @State var isLoading = false
    /// Tracks nav direction so Back slides opposite to Next.
    @State private var goingForward = true
    var onComplete: () -> Void

    /// Welcome, Editor, justtype, Sous, Tabs. Last index = stepCount − 1.
    static let stepCount = 5
    private var lastStep: Int { SetupView.stepCount - 1 }

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
                } else {
                    Step4Sous().transition(stepTransition)
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
            ForEach(0..<SetupView.stepCount, id: \.self) { step in
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
                Text("Your clipboard and notes, right in the menubar")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 9) {
                FeatureRow(icon: "clipboard", title: "Clipboard History", desc: "Save up to 200 items")
                FeatureRow(icon: "note.text", title: "Quick Notes", desc: "Capture ideas instantly")
                FeatureRow(icon: "doc.text", title: "Markdown Notes", desc: "Open in any editor you like")
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
