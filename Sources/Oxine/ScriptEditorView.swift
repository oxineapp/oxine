import SwiftUI
import PanelKit

/// Create / edit a script without leaving the panel. A compact form over the
/// grid: identity (name, icon, color), behaviour (input / output / trigger),
/// advisory permissions, an optional one-key shortcut, and the script itself.
struct ScriptEditorView: View {
    @State var draft: ScriptDraft
    let accent: Color
    let onSave: (ScriptDraft) -> Void
    let onCancel: () -> Void

    private var isEditing: Bool { draft.existingFolder != nil }
    private var tint: Color { Color(hex: draft.colorHex) }
    private var canSave: Bool { !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea().onTapGesture(perform: onCancel)

            VStack(spacing: 0) {
                header
                Divider().overlay(.white.opacity(0.08))
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        identitySection
                        behaviourSection
                        permissionsSection
                        scriptSection
                    }
                    .padding(16)
                }
                Divider().overlay(.white.opacity(0.08))
                footer
            }
            .frame(maxWidth: 340, maxHeight: 520)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(red: 0.08, green: 0.08, blue: 0.1)))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
            .padding(16)
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.18)).frame(width: 34, height: 34)
                Image(systemName: draft.symbol.isEmpty ? "puzzlepiece.extension.fill" : draft.symbol)
                    .font(.system(size: 16)).foregroundColor(tint)
            }
            Text(isEditing ? "Edit Script" : "New Script")
                .font(.system(size: 15, weight: .bold)).foregroundColor(.white)
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundColor(.white.opacity(0.4))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button(action: onCancel) {
                Text("Cancel").font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 14).padding(.vertical, 8)
            }.buttonStyle(.plain)
            Button(action: { onSave(draft) }) {
                Text(isEditing ? "Save" : "Create")
                    .font(.system(size: 12, weight: .bold)).foregroundColor(canSave ? .black : .white.opacity(0.3))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Capsule().fill(canSave ? accent : .white.opacity(0.08)))
            }.buttonStyle(.plain).disabled(!canSave)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: - Sections

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Identity")
            field("Name") { textField("My Script", text: $draft.name) }
            field("Icon") {
                textField("SF Symbol, e.g. wand.and.stars", text: $draft.symbol)
            }
            field("Color") {
                HStack(spacing: 8) {
                    ForEach(ScriptPalette.swatches, id: \.self) { hex in
                        Circle().fill(Color(hex: hex)).frame(width: 20, height: 20)
                            .overlay(Circle().stroke(.white, lineWidth: draft.colorHex == hex ? 2 : 0))
                            .onTapGesture { draft.colorHex = hex }
                    }
                }
            }
            field("Description") { textField("What does it do?", text: $draft.details) }
        }
    }

    private var behaviourSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Behaviour")
            field("Input") {
                menuPicker(selection: $draft.input, options: [(.clipboard, "Clipboard"), (.note, "Latest note"), (.none, "Nothing")])
            }
            field("Output") {
                menuPicker(selection: $draft.output, options: [(.copy, "Copy result"), (.append, "Save as note"), (.show, "Show result"), (.notify, "Notify"), (.none, "Ignore")])
            }
            field("Trigger") {
                menuPicker(selection: $draft.mode, options: [(.instant, "Run on tap"), (.argument, "Ask for text first")])
            }
            field("Keybind") {
                HStack(spacing: 8) {
                    TextField("—", text: Binding(
                        get: { draft.keybind },
                        set: { draft.keybind = String($0.prefix(1)) }
                    ))
                    .textFieldStyle(.plain).frame(width: 28)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.08)))
                    Text("press this key (while on the Scripts tab) to run")
                        .font(.system(size: 10)).foregroundColor(.white.opacity(0.4))
                }
            }
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Declares (advisory)")
            HStack(spacing: 8) {
                permChip("Network", icon: "network", on: $draft.network)
                permChip("Files", icon: "folder", on: $draft.files)
            }
        }
    }

    private var scriptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Script")
            Text("stdin = your input · stdout = the result")
                .font(.system(size: 10)).foregroundColor(.white.opacity(0.4))
            TextEditor(text: $draft.script)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))
                .scrollContentBackground(.hidden)
                .frame(height: 120)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 0.5))
        }
    }

    // MARK: - Bits

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold)).foregroundColor(.white.opacity(0.35)).kerning(0.5)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.5))
                .frame(width: 74, alignment: .leading).padding(.top, 4)
            content()
            Spacer(minLength: 0)
        }
    }

    private func textField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundColor(.white)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.08)))
    }

    private func menuPicker<T: Hashable>(selection: Binding<T>, options: [(T, String)]) -> some View {
        Menu {
            ForEach(options, id: \.0) { value, title in
                Button(title) { selection.wrappedValue = value }
            }
        } label: {
            HStack(spacing: 5) {
                Text(options.first { $0.0 == selection.wrappedValue }?.1 ?? "—")
                    .font(.system(size: 12)).foregroundColor(.white)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8)).foregroundColor(.white.opacity(0.4))
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.08)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func permChip(_ title: String, icon: String, on: Binding<Bool>) -> some View {
        Button(action: { on.wrappedValue.toggle() }) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(on.wrappedValue ? .orange : .white.opacity(0.4))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(on.wrappedValue ? Color.orange.opacity(0.15) : .white.opacity(0.06)))
            .overlay(Capsule().stroke(on.wrappedValue ? Color.orange.opacity(0.4) : .white.opacity(0.1), lineWidth: 0.5))
        }.buttonStyle(.plain)
    }
}
