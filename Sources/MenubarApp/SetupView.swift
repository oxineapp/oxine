import SwiftUI

struct SetupView: View {
    @State var currentStep = 0
    @State var isLoading = false
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<2, id: \.self) { step in
                        Capsule()
                            .fill(step <= currentStep ? Color(red: 0.4, green: 0.85, blue: 1.0) : Color.white.opacity(0.12))
                            .frame(height: 3)
                            .shadow(color: Color(red: 0.4, green: 0.85, blue: 1.0).opacity(step <= currentStep ? 0.4 : 0.0), radius: 2)
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
            .padding(20)
            .padding(.bottom, 8)

            VStack {
                if currentStep == 0 {
                    Step1Welcome()
                        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .trailing)), removal: .opacity.combined(with: .move(edge: .leading))))
                } else {
                    Step2Obsidian(isLoading: $isLoading)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .trailing)), removal: .opacity.combined(with: .move(edge: .leading))))
                }
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 12) {
                if currentStep > 0 {
                    Button(action: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            currentStep -= 1
                        }
                    }) {
                        Text("Back")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .foregroundColor(.white.opacity(0.8))
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
                        Text(currentStep < 1 ? "Next" : "Finish")
                            .font(.system(size: 13, weight: .bold))
                            .transition(.opacity)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(red: 0.4, green: 0.85, blue: 1.0).opacity(0.15))
                )
                .disabled(isLoading)
                .scaleEffect(isLoading ? 0.98 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isLoading)
            }
            .padding(20)
            .padding(.top, 8)
        }
        .background(Color(red: 0.06, green: 0.06, blue: 0.08))
        .cornerRadius(18)
    }
}

struct Step1Welcome: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "wand.and.stars")
                .font(.system(size: 56))
                .foregroundColor(Color(red: 0.4, green: 0.85, blue: 1.0))
            VStack(spacing: 12) {
                Text("Welcome to MenuBar")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                Text("Your clipboard and notes, right in the menubar")
                    .font(.body)
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(icon: "clipboard", title: "Clipboard History", desc: "Save up to 200 items")
                FeatureRow(icon: "note.text", title: "Quick Notes", desc: "Capture ideas instantly")
                FeatureRow(icon: "brain.fill", title: "Obsidian Sync", desc: "Auto-sync to your vault")
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.03)))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(LinearGradient(colors: [.white.opacity(0.12), .white.opacity(0.02)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.5)
            )
            Spacer()
        }
        .padding(20)
    }
}

struct Step2Obsidian: View {
    @Binding var isLoading: Bool
    @State var isSetup = false
    @State var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "brain.fill")
                .font(.system(size: 56))
                .foregroundColor(Color(red: 0.4, green: 0.85, blue: 1.0))
            VStack(spacing: 12) {
                Text("Obsidian Integration")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                Text("Sync your notes to Obsidian automatically")
                    .font(.body)
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.orange.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(Color.orange.opacity(0.08))
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.15), lineWidth: 0.5))
            }
            if isSetup {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Color(red: 0.3, green: 0.85, blue: 0.5))
                    Text("Obsidian vault ready!")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.green.opacity(0.08))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.green.opacity(0.2), lineWidth: 0.5))
            } else {
                Button(action: setupObsidian) {
                    HStack {
                        if isLoading { ProgressView().scaleEffect(0.7) }
                        else { Image(systemName: "checkmark.circle") }
                        Text("Auto-Setup Obsidian").fontWeight(.semibold)
                    }
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundColor(Color(red: 0.4, green: 0.85, blue: 1.0))
                    .background(Color(red: 0.4, green: 0.85, blue: 1.0).opacity(0.12))
                    .cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(red: 0.4, green: 0.85, blue: 1.0).opacity(0.25), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("What happens:")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.4))
                    .textCase(.uppercase).tracking(0.5)
                Text("✓ Creates ~/Documents/MenuBar Notes\n✓ Sets up as Obsidian vault\n✓ Opens in Obsidian\n✓ Auto-syncs your notes")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.65))
                    .lineSpacing(4)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.03))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(LinearGradient(colors: [.white.opacity(0.12), .white.opacity(0.02)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.5)
            )
            Spacer()
        }
        .padding(20)
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

struct FeatureRow: View {
    let icon: String
    let title: String
    let desc: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(Color(red: 0.4, green: 0.85, blue: 1.0))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).fontWeight(.semibold).foregroundColor(.white)
                Text(desc).font(.caption2).foregroundColor(.white.opacity(0.5))
            }
            Spacer()
        }
    }
}
