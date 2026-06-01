import SwiftUI

struct SetupView: View {
    @State var currentStep = 0
    @State var isLoading = false
    /// Tracks nav direction so Back slides opposite to Next.
    @State private var goingForward = true
    var onComplete: () -> Void

    /// Steps slide along the nav direction: Next enters from the right, Back from the left.
    private var stepTransition: AnyTransition {
        goingForward
            ? .asymmetric(insertion: .opacity.combined(with: .move(edge: .trailing)),
                          removal: .opacity.combined(with: .move(edge: .leading)))
            : .asymmetric(insertion: .opacity.combined(with: .move(edge: .leading)),
                          removal: .opacity.combined(with: .move(edge: .trailing)))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { step in
                        Capsule()
                            .fill(step <= currentStep ? Color.oxineAccent : Color.white.opacity(0.12))
                            .frame(height: 3)
                            .shadow(color: Color.oxineAccent.opacity(step <= currentStep ? 0.4 : 0.0), radius: 2)
                            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: currentStep)
                    }
                }
                Spacer()
                Button(action: {
                    SetupManager.shared.markSetupComplete()
                    onComplete()
                }) {
                    Text("Skip")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            VStack {
                if currentStep == 0 {
                    Step1Welcome()
                        .transition(stepTransition)
                } else if currentStep == 1 {
                    Step2Obsidian(isLoading: $isLoading)
                        .transition(stepTransition)
                } else {
                    Step3JustType()
                        .transition(stepTransition)
                }
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 12) {
                if currentStep > 0 {
                    Button(action: {
                        goingForward = false
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            currentStep -= 1
                        }
                    }) {
                        Text("Back")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .foregroundColor(.white.opacity(0.8))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(.white.opacity(0.08), lineWidth: 0.5)
                    )
                    .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .leading)), removal: .opacity))
                }

                Button(action: {
                    if currentStep < 2 {
                        goingForward = true
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            currentStep += 1
                        }
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            SetupManager.shared.markSetupComplete()
                            onComplete()
                        }
                    }
                }) {
                    HStack(spacing: 6) {
                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.7)
                                .transition(.scale.combined(with: .opacity))
                        }
                        Text(currentStep < 2 ? "Next" : "Finish")
                            .font(.system(size: 13, weight: .bold))
                            .transition(.opacity)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.oxineAccent.opacity(0.15))
                )
                .disabled(isLoading)
                .scaleEffect(isLoading ? 0.98 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isLoading)
            }
            .padding(20)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(Color(red: 0.06, green: 0.06, blue: 0.08))
    }
}

struct Step1Welcome: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 38))
                .foregroundColor(Color.oxineAccent)
            VStack(spacing: 6) {
                Text("Welcome to MenuBar")
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
    private var accent: Color { .oxineAccent }

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
                     ? "Notes live in ~/Documents/MenuBar Notes, opened as an Obsidian vault with tags and metadata."
                     : "Notes live in ~/Documents/MenuBar Notes as clean .md files, opened in \(NotesEditor.displayName).")
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
                .foregroundColor(Color.oxineAccent)
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
                    .foregroundColor(Color.oxineAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.oxineAccent.opacity(0.15)))
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
                        .foregroundColor(Color.oxineAccent)
                        .background(Color.oxineAccent.opacity(0.1))
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

struct FeatureRow: View {
    let icon: String
    let title: String
    let desc: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundColor(Color.oxineAccent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                Text(desc).font(.system(size: 10, weight: .medium)).foregroundColor(.white.opacity(0.5))
            }
            Spacer()
        }
    }
}
