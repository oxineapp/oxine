import AppKit
import PanelKit
import SwiftUI

/// Renders an app's declared view tree with PanelKit styling. This file is the
/// `api: 1` view vocabulary — components own their look and micro-interactions
/// here, host-side; apps only send state. Unknown node types render as nothing
/// (forward compatibility). Interactions call back through the runtime as
/// protocol events (`ref` = node id).
struct AppViewRenderer: View {
    @ObservedObject var runtime: AppRuntime
    /// Which surface's tree to draw ("panelTab", "settings", "notchTab").
    let surface: String

    var body: some View {
        if let tree = runtime.trees[surface], !tree.isEmpty {
            AppNodeList(nodes: tree, surface: surface, runtime: runtime)
        } else if runtime.running {
            // The app is up but hasn't drawn this surface yet.
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "bolt.slash")
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.3))
                Text(runtime.runtimeError ?? "\(runtime.app.name) isn't running.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A vertical run of sibling nodes (position-keyed ForEach).
struct AppNodeList: View {
    let nodes: [AppNode]
    let surface: String
    let runtime: AppRuntime

    var body: some View {
        ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
            AppNodeView(node: node, surface: surface, runtime: runtime)
        }
    }
}

/// One node. The vocabulary lives in this switch; conversations (chats and
/// their parts) are drawn by `AppChatNode`, in AppChatNodes.swift.
struct AppNodeView: View {
    let node: AppNode
    let surface: String
    let runtime: AppRuntime
    private var accent: Color { .panelAccent }

    private func event(_ kind: String, _ value: JSONValue? = nil) {
        runtime.sendEvent(surface: surface, ref: node.id, kind: kind, value: value)
    }

    private var children: [AppNode] { node.children ?? [] }

    var body: some View {
        content.modifier(NodeMenu(node: node, surface: surface, runtime: runtime))
    }

    @ViewBuilder private var content: some View {
        switch node.type {
        // MARK: Layout
        case "vstack":
            VStack(alignment: .leading, spacing: node.number("spacing").map { CGFloat($0) } ?? 8) {
                AppNodeList(nodes: children, surface: surface, runtime: runtime)
            }
        case "hstack":
            HStack(spacing: node.number("spacing").map { CGFloat($0) } ?? 8) {
                AppNodeList(nodes: children, surface: surface, runtime: runtime)
            }
        case "zstack":
            ZStack { AppNodeList(nodes: children, surface: surface, runtime: runtime) }
        case "grid":
            let cols = max(Int(node.number("columns") ?? 2), 1)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: cols), spacing: 8) {
                AppNodeList(nodes: children, surface: surface, runtime: runtime)
            }
        case "scroll":
            // `maxHeight` makes it a window onto its content (four chats,
            // say) that scrolls inside, instead of growing with it.
            // `remember` keeps where it was scrolled to (per surface) for
            // when it's shown again: the notch rebuilds it every time.
            RememberedScroll(key: node.string("remember").map { "\(surface):\($0)" }, runtime: runtime) {
                VStack(alignment: .leading, spacing: node.number("spacing").map { CGFloat($0) } ?? 8) {
                    AppNodeList(nodes: children, surface: surface, runtime: runtime)
                }
            }
            .frame(maxHeight: node.number("maxHeight").map { CGFloat($0) })
        // MARK: Conversation (AppChatNodes.swift)
        case "chatLayout", "toolbar", "composer", "dateSeparator", "sectionLabel",
             "messageBubble", "replyPreview", "chatRow", "iconButton", "plainIconButton", "swatch":
            AppChatNode(node: node, surface: surface, runtime: runtime)
        case "spacer":
            Spacer(minLength: node.number("min").map { CGFloat($0) } ?? 0)
        case "divider":
            Divider().opacity(0.15)

        // MARK: Content
        case "text":
            // `maxLines` cuts it short; `minScale` lets a title shrink to fit first.
            Text(node.string("text") ?? "")
                .font(textFont)
                .foregroundColor(.white.opacity(textOpacity))
                .multilineTextAlignment(node.string("align") == "center" ? .center : .leading)
                .lineLimit(node.number("maxLines").map { Int($0) })
                .minimumScaleFactor(node.number("minScale") ?? 1)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: node.string("align") == "center" ? .infinity : nil)
        case "icon":
            Image(systemName: node.string("symbol") ?? "questionmark")
                .font(.system(size: node.number("size").map { CGFloat($0) } ?? 14))
                .foregroundColor(node.color("color") ?? (node.bool("accent") == true ? accent : .white.opacity(0.7)))
        case "image":
            if let b64 = node.string("data"), let data = Data(base64Encoded: b64),
               let img = NSImage(data: data) {
                let side = node.number("maxHeight").map { CGFloat($0) }
                if node.string("kind") == "qr" {
                    // A code to scan (pairing a phone): crisp pixels, a quiet
                    // white margin, centred.
                    Image(nsImage: img)
                        .interpolation(.none)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: side ?? 160, maxHeight: side ?? 160)
                        .padding(10)
                        .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(node.string("label") ?? "Code to scan")
                } else {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: side ?? 120)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityLabel(node.string("label") ?? "")
                }
            }
        case "card":
            VStack(alignment: .leading, spacing: 8) {
                AppNodeList(nodes: children, surface: surface, runtime: runtime)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)))
        case "emptyState":
            VStack(spacing: 8) {
                Image(systemName: node.string("symbol") ?? "tray")
                    .font(.system(size: 24))
                    .foregroundColor(.white.opacity(0.3))
                Text(node.string("title") ?? "")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                if let sub = node.string("subtitle") {
                    Text(sub).font(.system(size: 11)).foregroundColor(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                }
                // `settingsLink`: a link to the app's own settings page.
                if let link = node.string("settingsLink") {
                    Button(link) { AppDelegate.instance?.openSettings(app: runtime.app.id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(accent)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)

        // MARK: Data
        case "meter", "progress":
            VStack(alignment: .leading, spacing: 4) {
                if let label = node.string("label") {
                    HStack {
                        Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.6))
                        Spacer()
                        if let v = node.string("valueText") {
                            Text(v).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                }
                GeometryReader { geo in
                    let frac = min(max(node.number("value") ?? 0, 0), 1)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule().fill(accent).frame(width: geo.size.width * frac)
                    }
                }
                .frame(height: 5)
                .animation(.easeInOut(duration: 0.35), value: node.number("value") ?? 0)
            }
        case "gauge":
            let frac = min(max(node.number("value") ?? 0, 0), 1)
            ZStack {
                Circle().trim(from: 0, to: 0.75)
                    .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle().trim(from: 0, to: 0.75 * frac)
                    .stroke(accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .animation(.easeInOut(duration: 0.35), value: frac)
                VStack(spacing: 0) {
                    Text(node.string("valueText") ?? "\(Int(frac * 100))%")
                        .font(.system(size: 13, weight: .bold)).monospacedDigit()
                        .foregroundColor(.white.opacity(0.9))
                    if let label = node.string("label") {
                        Text(label).font(.system(size: 9)).foregroundColor(.white.opacity(0.5))
                    }
                }
            }
            .frame(width: 64, height: 64)
        case "sparkline":
            let values = node.numbers("values") ?? []
            GeometryReader { geo in
                if values.count > 1, let lo = values.min(), let hi = values.max() {
                    let span = max(hi - lo, 0.0001)
                    Path { p in
                        for (i, v) in values.enumerated() {
                            let x = geo.size.width * CGFloat(i) / CGFloat(values.count - 1)
                            let y = geo.size.height * (1 - CGFloat((v - lo) / span))
                            i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    .stroke(accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(height: node.number("height").map { CGFloat($0) } ?? 28)
        case "badge":
            Text(node.string("text") ?? "")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .foregroundColor(accent)
                .background(Capsule().fill(accent.opacity(0.12)))
        case "keyValueRow":
            HStack {
                Text(node.string("key") ?? "")
                    .font(.system(size: 12)).foregroundColor(.white.opacity(0.6))
                Spacer()
                Text(node.string("value") ?? "")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundColor(.white.opacity(0.85))
            }

        // MARK: Controls
        case "button":
            Button(action: { event("tap") }) {
                Text(node.string("title") ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .foregroundColor(node.bool("destructive") == true ? .red : accent)
                    .background(Capsule().fill((node.bool("destructive") == true ? Color.red : accent).opacity(0.12)))
                    .contentShape(Capsule())
            }
            .buttonStyle(AppPressStyle())
        case "toggle":
            Toggle(isOn: Binding(
                get: { node.bool("on") ?? false },
                set: { event("change", .bool($0)) }
            )) {
                controlLabel
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(accent)
        case "slider":
            // `step` snaps the value; `valueText` is the app's own readout
            // ("17 pt", "+0.3 s") shown trailing the label.
            let range = (node.number("min") ?? 0)...(node.number("max") ?? 1)
            let binding = Binding(
                get: { min(max(node.number("value") ?? 0, range.lowerBound), range.upperBound) },
                set: { event("change", .number($0)) }
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    controlLabel
                    Spacer()
                    if let v = node.string("valueText") {
                        Text(v).font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                if let step = node.number("step"), step > 0 {
                    Slider(value: binding, in: range, step: step)
                        .controlSize(.small)
                        .tint(accent)
                } else {
                    Slider(value: binding, in: range)
                        .controlSize(.small)
                        .tint(accent)
                }
            }
        case "stepper":
            HStack {
                controlLabel
                Spacer()
                Text(node.string("valueText") ?? "\(Int(node.number("value") ?? 0))")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundColor(.white.opacity(0.85))
                Stepper("", onIncrement: { event("change", .string("inc")) },
                        onDecrement: { event("change", .string("dec")) })
                    .labelsHidden()
                    .controlSize(.small)
            }
        case "picker":
            HStack {
                controlLabel
                Spacer()
                Picker("", selection: Binding(
                    get: { node.string("selected") ?? "" },
                    set: { event("change", .string($0)) }
                )) {
                    ForEach(node.strings("options") ?? [], id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
            }
        case "textField":
            AppTextFieldNode(node: node, focusTick: runtime.focusTicks[surface] ?? 0,
                             onChange: { event("change", .string($0)) },
                             onSubmit: { event("submit", .string($0)) })
        case "secureField":
            AppTextFieldNode(node: node, secure: true, focusTick: runtime.focusTicks[surface] ?? 0,
                             onChange: { event("change", .string($0)) },
                             onSubmit: { event("submit", .string($0)) })
        case "keyRecorder":
            KeyRecorderNode(current: node.string("value") ?? "") { combo in
                event("change", .string(combo))
            }

        // MARK: Structure
        case "section":
            SettingSection(title: node.string("header") ?? "") {
                AppNodeList(nodes: children, surface: surface, runtime: runtime)
            }
        case "row":
            AppRowNode(node: node, accent: accent) { event("tap") }
        case "list":
            VStack(spacing: 0) {
                ForEach(Array(children.enumerated()), id: \.offset) { idx, child in
                    AppNodeView(node: child, surface: surface, runtime: runtime)
                        .padding(.vertical, 6)
                    if idx < children.count - 1 { Divider().opacity(0.06) }
                }
            }

        default:
            // Unknown node type from a newer SDK: render nothing, never break.
            EmptyView()
        }
    }

    /// Shared "title" leading label for controls.
    @ViewBuilder private var controlLabel: some View {
        Text(node.string("title") ?? "")
            .font(.system(size: 12.5, weight: .medium))
            .foregroundColor(.white.opacity(0.9))
    }

    private var textFont: Font {
        switch node.string("style") {
        case "title":   return .system(size: 15, weight: .bold)
        case "chatTitle": return .system(size: 12.5, weight: .semibold)
        case "caption": return .system(size: 10.5)
        case "mono":    return .system(size: 12, design: .monospaced)
        default:        return .system(size: 12.5)
        }
    }
    private var textOpacity: Double {
        switch node.string("style") {
        case "title":   return 0.92
        case "caption": return 0.5
        default:        return 0.8
        }
    }
}

/// Any node's right-click menu, from its `menu` prop: items of `id`,
/// `title`, and optionally `symbol`, `destructive`, `checked`, or a
/// `divider`. A pick sends "menu" with the item's id as `ref` and the node's
/// own id as the value (which row, say).
private struct NodeMenu: ViewModifier {
    let node: AppNode
    let surface: String
    let runtime: AppRuntime

    private var items: [JSONValue] { node.props?["menu"]?.arrayValue ?? [] }

    func body(content: Content) -> some View {
        if items.isEmpty {
            content
        } else {
            content.contextMenu {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    if item["divider"]?.boolValue == true {
                        Divider()
                    } else if let id = item["id"]?.stringValue, let title = item["title"]?.stringValue {
                        Button(role: item["destructive"]?.boolValue == true ? .destructive : nil) {
                            runtime.sendEvent(surface: surface, ref: id, kind: "menu",
                                              value: node.id.map { .string($0) })
                        } label: {
                            if item["checked"]?.boolValue == true {
                                Label(title, systemImage: "checkmark")
                            } else if let symbol = item["symbol"]?.stringValue {
                                Label(title, systemImage: symbol)
                            } else {
                                Text(title)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// A tappable row: a symbol, a title and subtitle, a value, a chevron. It
/// lights up under the pointer. `prominent` makes it the one to press,
/// in `indicatorColor` (else the accent).
private struct AppRowNode: View {
    let node: AppNode
    let accent: Color
    let tap: () -> Void
    @State private var hovering = false

    private var prominent: Bool { node.bool("prominent") == true }
    private var tint: Color { node.color("indicatorColor") ?? accent }

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 10) {
                if let sym = node.string("symbol") {
                    Image(systemName: sym)
                        .font(.system(size: 13, weight: prominent ? .semibold : .regular))
                        .foregroundColor(tint)
                        .frame(width: 22, height: 22)
                        .background(tint.opacity(prominent ? 0.15 : 0), in: Circle())
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.string("title") ?? "")
                        .font(.system(size: 12.5, weight: prominent ? .semibold : .medium))
                        .foregroundColor(.white.opacity(0.9))
                    if let sub = node.string("subtitle") {
                        Text(sub).font(.caption2).foregroundColor(prominent ? tint.opacity(0.85) : .white.opacity(0.45))
                    }
                }
                Spacer()
                if let value = node.string("value") {
                    Text(value).font(.system(size: 12)).foregroundColor(.white.opacity(0.6))
                }
                if node.id != nil && node.bool("chevron") != false {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(hovering ? 0.5 : 0.25))
                        .offset(x: hovering ? 1.5 : 0)
                }
            }
            // The highlight reaches a little past the row without moving it.
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.white.opacity(hovering && node.id != nil ? 0.06 : 0))
                    .padding(.horizontal, -6)
                    .padding(.vertical, -3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(AppPressStyle())
        .disabled(node.id == nil)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}

/// A scroll view that, given a key, remembers where the reader left it (in
/// the runtime, which outlives the view) and goes back there when it's shown
/// again. Only a scroll the reader made moves the mark.
private struct RememberedScroll<Content: View>: View {
    let key: String?
    let runtime: AppRuntime
    @ViewBuilder let content: () -> Content
    @State private var position = ScrollPosition(idType: String.self)

    var body: some View {
        ScrollView { content() }
            .scrollPosition($position)
            .onAppear {
                guard let key, let saved = runtime.readingPosition(key) else { return }
                DispatchQueue.main.async { position.scrollTo(y: saved) }
            }
            .onScrollPhaseChange { old, new, context in
                guard let key, new == .idle, old != .animating, old != .idle else { return }
                runtime.keepReadingPosition(context.geometry.contentOffset.y, for: key)
            }
    }
}

/// A text field that keeps what's typed on this side, so typing never waits
/// on the app: each change is sent, and the app's value only replaces the
/// text when the field isn't being typed in (or the app clears it, after a
/// send). `kind` "composer" sits bare inside a `composer` node (which draws
/// the capsule) and takes the keyboard when the person clicks the notch to
/// type; "search" gets a clear button. `focused: true` also takes it, and
/// again whenever the app bumps `focusRequest`.
struct AppTextFieldNode: View {
    let node: AppNode
    var secure = false
    let focusTick: Int
    let onChange: (String) -> Void
    let onSubmit: (String) -> Void
    @State private var text: String
    @FocusState private var focused: Bool

    init(node: AppNode, secure: Bool = false, focusTick: Int,
         onChange: @escaping (String) -> Void, onSubmit: @escaping (String) -> Void) {
        self.node = node
        self.secure = secure
        self.focusTick = focusTick
        self.onChange = onChange
        self.onSubmit = onSubmit
        _text = State(initialValue: node.string("value") ?? "")
    }

    private var value: String { node.string("value") ?? "" }
    private var kind: String { node.string("kind") ?? "default" }
    private var bare: Bool { kind == "composer" }
    /// Takes the keyboard when the person clicks to type on this surface.
    private var isFocusTarget: Bool { bare || node.bool("focused") == true }

    var body: some View {
        HStack(spacing: 6) {
            if let symbol = node.string("symbol") {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
            }
            Group {
                if secure {
                    SecureField(node.string("placeholder") ?? "", text: $text)
                } else {
                    TextField(node.string("placeholder") ?? "", text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.white)
            .focused($focused)
            .onSubmit { onSubmit(text) }
            .onExitCommand { focused = false }
            if kind == "search", !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, bare ? 0 : 9)
        .padding(.vertical, bare ? 0 : 6)
        .background {
            if !bare {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.white.opacity(focused ? 0.1 : 0.06))
            }
        }
        .preference(key: FieldFocusKey.self, value: focused)
        .onChange(of: text) { _, new in if new != value { onChange(new) } }
        .onChange(of: value) { _, new in if !focused || new.isEmpty { text = new } }
        .onChange(of: focusTick) { _, _ in if isFocusTarget { focused = true } }
        .onChange(of: node.number("focusRequest") ?? 0) { _, _ in
            if node.bool("focused") == true { focused = true }
        }
        .onAppear { if node.bool("focused") == true { focused = true } }
    }
}

/// A field inside reports its focus up, so its capsule can light up.
struct FieldFocusKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// Presses sink a little, like the notch's own buttons.
struct AppPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? 0.08 : 0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension AppNode {
    /// A "#RRGGBB" prop as a color, or nil (anything else is ignored).
    func color(_ key: String) -> Color? {
        guard let hex = string(key), AppRuntime.isHexColor(hex) else { return nil }
        return Color(hex: hex)
    }
}

/// Minimal key-combo recorder: click, press a combo, done. Records via a local
/// NSEvent monitor so it works without focus plumbing.
private struct KeyRecorderNode: View {
    let current: String
    let onRecord: (String) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggle) {
            Text(recording ? "Press keys…" : (current.isEmpty ? "Record shortcut" : current))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(recording ? Color.panelAccent : .white.opacity(0.8))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(recording ? 0.1 : 0.05)))
        }
        .buttonStyle(.plain)
        .onDisappear { stopMonitor() }
    }

    private func toggle() {
        recording ? stopMonitor() : startMonitor()
    }

    private func startMonitor() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            var parts: [String] = []
            let f = ev.modifierFlags
            if f.contains(.command) { parts.append("cmd") }
            if f.contains(.option) { parts.append("opt") }
            if f.contains(.control) { parts.append("ctrl") }
            if f.contains(.shift) { parts.append("shift") }
            if let chars = ev.charactersIgnoringModifiers, !chars.isEmpty {
                parts.append(chars.lowercased())
            }
            onRecord(parts.joined(separator: "+"))
            stopMonitor()
            return nil
        }
    }

    private func stopMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = false
    }
}
