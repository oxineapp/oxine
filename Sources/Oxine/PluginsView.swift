import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The "Plugins" hub: a smart icon grid of installed plugins plus an action bar
/// to create, install, edit, and run them. Tapping an instant plugin runs it;
/// an argument plugin reveals an inline text field first. A plugin can also
/// declare a one-key shortcut that fires while this tab is focused.
struct PluginsView: View {
    @StateObject private var manager = PluginManager()
    @ObservedObject var clipboardManager: ClipboardManager
    @ObservedObject var notesManager: QuickNotesManager

    @State private var argumentFor: Plugin?
    @State private var argumentText = ""
    @State private var inspecting: Plugin?
    @State private var editing: PluginDraft?
    @State private var bannerDismiss: Task<Void, Never>?
    @State private var editMode = false
    @State private var draggingID: String?
    @FocusState private var gridFocused: Bool

    private var accent: Color { .oxineAccent }
    private let columns = [GridItem(.adaptive(minimum: 86, maximum: 120), spacing: 12)]

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                actionBar
                if manager.plugins.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }

            // Floating: argument input + result banner.
            VStack(spacing: 0) {
                Spacer()
                if let plugin = argumentFor { argumentBar(for: plugin) }
                if let result = manager.lastResult { banner(result) }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if let plugin = inspecting {
                PluginDetailCard(
                    plugin: plugin, accent: tint(for: plugin),
                    onEdit: { beginEdit(plugin) },
                    onDelete: { manager.delete(plugin); inspecting = nil },
                    onReveal: { manager.revealInFinder() },
                    onClose: { inspecting = nil }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            if let draft = editing {
                PluginEditorView(
                    draft: draft, accent: accent,
                    onSave: { saveDraft($0) },
                    onCancel: { editing = nil }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: inspecting)
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: editing?.existingFolder)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: argumentFor)
        .onChange(of: manager.lastResult?.id) { _, _ in scheduleBannerDismiss() }
        .focusable()
        .focusEffectDisabled()
        .focused($gridFocused)
        .onAppear { gridFocused = true }
        .onKeyPress(phases: .down) { handleKey($0) }
    }

    // MARK: - Sections

    private var actionBar: some View {
        HStack(spacing: 8) {
            if editMode {
                Text("Drag to rearrange")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                barButton(icon: "checkmark", label: "Done") {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { editMode = false }
                }
            } else {
                barButton(icon: "plus", label: "New") { editing = newDraft() }
                barButton(icon: "square.and.arrow.down", label: "Install") { manager.installViaPanel() }
                Spacer()
                barButton(icon: "folder", label: nil) { manager.revealInFinder() }
                    .help("Open plugins folder")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(manager.plugins) { plugin in
                    PluginTile(
                        plugin: plugin,
                        tint: tint(for: plugin),
                        running: manager.running.contains(plugin.id),
                        editMode: editMode,
                        onRun: { trigger(plugin) },
                        onInspect: { inspecting = plugin },
                        onBeginEdit: { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { editMode = true } }
                    )
                    .opacity(draggingID == plugin.id ? 0.35 : 1)
                    .modifier(Reorderable(enabled: editMode, plugin: plugin, manager: manager, draggingID: $draggingID))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 70)
        }
    }

    private func barButton(icon: String, label: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                if let label { Text(label).font(.system(size: 11, weight: .semibold)) }
            }
            .foregroundColor(accent)
            .padding(.horizontal, label == nil ? 8 : 11)
            .padding(.vertical, 6)
            .background(Capsule().fill(accent.opacity(0.12)))
            .overlay(Capsule().stroke(accent.opacity(0.22), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func tint(for plugin: Plugin) -> Color {
        plugin.manifest.color.map { Color(hex: $0) } ?? accent
    }

    private func trigger(_ plugin: Plugin) {
        if plugin.manifest.mode == .argument {
            argumentText = ""
            argumentFor = plugin
            return
        }
        runPlugin(plugin, argument: nil)
    }

    private func runArgument() {
        guard let plugin = argumentFor else { return }
        let text = argumentText
        argumentFor = nil
        runPlugin(plugin, argument: text)
    }

    private func runPlugin(_ plugin: Plugin, argument: String?) {
        Task { await manager.run(plugin, argument: argument, clipboard: clipboardManager, notes: notesManager) }
    }

    /// A fresh draft pre-tinted with the app's current accent, so new plugins
    /// inherit the global tint (existing plugins keep their own stored colour).
    private func newDraft() -> PluginDraft {
        var d = PluginDraft()
        d.colorHex = ThemeManager.shared.resolvedHex
        return d
    }

    private func beginEdit(_ plugin: Plugin) {
        let draft = PluginDraft(from: plugin, script: manager.scriptContents(for: plugin))
        inspecting = nil
        editing = draft
    }

    private func saveDraft(_ draft: PluginDraft) {
        if let err = manager.save(draft) {
            manager.lastResult = PluginRunResult(pluginName: "Save", ok: false, message: err)
        } else {
            editing = nil
        }
    }

    /// Run a plugin by its declared one-key shortcut (no modifiers), as long as
    /// no overlay/argument field is competing for the keystroke.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard editing == nil, inspecting == nil, argumentFor == nil,
              press.modifiers.isEmpty, !press.characters.isEmpty else { return .ignored }
        if let plugin = manager.plugin(forKeybind: press.characters) {
            trigger(plugin)
            return .handled
        }
        return .ignored
    }

    private func scheduleBannerDismiss() {
        bannerDismiss?.cancel()
        bannerDismiss = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.25)) { manager.lastResult = nil }
            }
        }
    }

    // MARK: - Pieces

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 34))
                .foregroundColor(accent.opacity(0.8))
            VStack(spacing: 6) {
                Text("No Plugins Yet")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                Text("Create one in seconds, or install a folder someone shared.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: { editing = newDraft() }) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("New Plugin").fontWeight(.semibold)
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 16).padding(.vertical, 9)
                .foregroundColor(accent)
                .background(Capsule().fill(accent.opacity(0.12)))
                .overlay(Capsule().stroke(accent.opacity(0.25), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }

    private func argumentBar(for plugin: Plugin) -> some View {
        HStack(spacing: 8) {
            Image(systemName: plugin.manifest.resolvedSymbol)
                .font(.system(size: 12))
                .foregroundColor(tint(for: plugin))
            TextField("Input for \(plugin.displayName)…", text: $argumentText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .onSubmit(runArgument)
            Button(action: runArgument) {
                Image(systemName: "return").font(.system(size: 11, weight: .bold)).foregroundColor(accent)
            }.buttonStyle(.plain)
            Button(action: { argumentFor = nil }) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundColor(.white.opacity(0.4))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Capsule().fill(.white.opacity(0.08)))
        .overlay(Capsule().stroke(accent.opacity(0.3), lineWidth: 0.5))
        .padding(.bottom, 6)
    }

    private func banner(_ result: PluginRunResult) -> some View {
        HStack(spacing: 8) {
            Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(result.ok ? accent : .orange)
            Text(result.message)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke((result.ok ? accent : .orange).opacity(0.25), lineWidth: 0.5))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// A single grid tile: tinted icon, name, an advisory permission dot, an
/// optional keybind badge, and a spinner while it runs. The tile is the run
/// button; a small ⓘ opens detail.
struct PluginTile: View {
    let plugin: Plugin
    let tint: Color
    let running: Bool
    var editMode: Bool = false
    let onRun: () -> Void
    let onInspect: () -> Void
    var onBeginEdit: () -> Void = {}

    @State private var hovering = false
    @State private var wiggle = false
    /// Desync the jiggle so the tiles don't wobble in lockstep.
    private let wigglePhase = Double.random(in: 0...0.12)

    private var hasPermissions: Bool { !plugin.manifest.permissions.isEmpty }

    var body: some View {
        Button(action: { editMode ? () : onRun() }) {
            VStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(tint.opacity(hovering ? 0.22 : 0.12))
                    icon
                    if running { ProgressView().scaleEffect(0.6) }
                }
                .frame(width: 54, height: 54)
                // Permission cue: an orange outline that fades in on hover
                // (replaces the old static dot). Animated for a fluid reveal.
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.orange, lineWidth: 2)
                        .opacity(hasPermissions && hovering && !editMode ? 1 : 0)
                )
                .overlay(alignment: .bottomTrailing) { keybindBadge }
                .help(hasPermissions ? "Declares: " + plugin.manifest.permissions.map(\.rawValue).joined(separator: ", ") : "")

                Text(plugin.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topLeading) {
            if hovering && !editMode {
                Button(action: onInspect) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.55))
                        .padding(2)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        // iOS-home-screen jiggle while rearranging.
        .rotationEffect(.degrees(editMode ? (wiggle ? 1.4 : -1.4) : 0))
        .animation(
            editMode
                ? .easeInOut(duration: 0.13).repeatForever(autoreverses: true).delay(wigglePhase)
                : .spring(response: 0.3, dampingFraction: 0.7),
            value: wiggle
        )
        .onChange(of: editMode) { _, on in wiggle = on }
        .onAppear { wiggle = editMode }
        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hovering = h } }
        .onLongPressGesture(minimumDuration: 0.45) { if !editMode { onBeginEdit() } }
        .contextMenu {
            Button("Run") { onRun() }
            Button("Edit…") { onInspect() }
            Button(editMode ? "Done Rearranging" : "Rearrange") { onBeginEdit() }
        }
    }

    @ViewBuilder private var icon: some View {
        if let url = plugin.customIconURL, let img = NSImage(contentsOf: url) {
            Image(nsImage: img).resizable().scaledToFit().frame(width: 28, height: 28)
                .opacity(running ? 0.3 : 1)
        } else {
            Image(systemName: plugin.manifest.resolvedSymbol)
                .font(.system(size: 22))
                .foregroundColor(tint)
                .opacity(running ? 0.3 : 1)
        }
    }

    @ViewBuilder private var keybindBadge: some View {
        if let key = plugin.manifest.keybind, !key.isEmpty {
            Text(key.uppercased())
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 14, height: 14)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.black.opacity(0.45)))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(.white.opacity(0.2), lineWidth: 0.5))
                .padding(3)
                .help("Press \(key.uppercased()) to run")
        }
    }
}

/// Detail card: what the plugin does + edit / delete / show-files.
struct PluginDetailCard: View {
    let plugin: Plugin
    let accent: Color
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onReveal: () -> Void
    let onClose: () -> Void

    @State private var confirmingDelete = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture(perform: onClose)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: plugin.manifest.resolvedSymbol)
                        .font(.system(size: 20)).foregroundColor(accent)
                    Text(plugin.displayName)
                        .font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundColor(.white.opacity(0.4))
                    }.buttonStyle(.plain)
                }

                if let desc = plugin.manifest.description {
                    Text(desc).font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    detailRow("Input", plugin.manifest.input.rawValue)
                    detailRow("Output", plugin.manifest.output.rawValue)
                    detailRow("Trigger", plugin.manifest.mode.rawValue)
                    if let k = plugin.manifest.keybind, !k.isEmpty { detailRow("Keybind", k.uppercased()) }
                    detailRow("Declares", plugin.manifest.permissions.isEmpty ? "nothing"
                              : plugin.manifest.permissions.map(\.rawValue).joined(separator: ", "))
                }

                if !plugin.manifest.permissions.isEmpty {
                    Text("Permissions are advisory — Oxine doesn't sandbox plugins. Only run scripts you trust.")
                        .font(.system(size: 10, weight: .medium)).foregroundColor(.orange.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    pillButton("Edit", icon: "pencil", color: accent, action: onEdit)
                    pillButton("Files", icon: "folder", color: accent, action: onReveal)
                    Spacer()
                    pillButton(confirmingDelete ? "Sure?" : "Delete", icon: "trash",
                               color: .red, action: {
                        if confirmingDelete { onDelete() } else { confirmingDelete = true }
                    })
                }
            }
            .padding(16)
            .frame(maxWidth: 300)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(red: 0.08, green: 0.08, blue: 0.1)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
            .padding(20)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.4))
                .frame(width: 64, alignment: .leading)
            Text(value).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundColor(.white.opacity(0.8))
            Spacer(minLength: 0)
        }
    }

    private func pillButton(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon); Text(title).fontWeight(.semibold)
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 11).padding(.vertical, 7)
            .foregroundColor(color)
            .background(Capsule().fill(color.opacity(0.12)))
        }.buttonStyle(.plain)
    }
}

/// Makes a tile draggable + a drop target while in rearrange mode. Disabled
/// otherwise so a normal tap still runs the plugin.
struct Reorderable: ViewModifier {
    let enabled: Bool
    let plugin: Plugin
    let manager: PluginManager
    @Binding var draggingID: String?

    func body(content: Content) -> some View {
        if enabled {
            content
                .onDrag {
                    draggingID = plugin.id
                    return NSItemProvider(object: plugin.id as NSString)
                }
                .onDrop(of: [UTType.text], delegate: PluginDropDelegate(
                    target: plugin, manager: manager, draggingID: $draggingID))
        } else {
            content
        }
    }
}

/// Live reorder: as the dragged tile passes over another, the array reflows
/// (iOS-home-screen feel). Reorder happens on the main actor.
struct PluginDropDelegate: DropDelegate {
    let target: Plugin
    let manager: PluginManager
    @Binding var draggingID: String?

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingID, dragging != target.id else { return }
        MainActor.assumeIsolated {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                manager.move(dragging, before: target.id)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}

