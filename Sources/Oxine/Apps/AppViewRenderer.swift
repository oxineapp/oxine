import AppKit
import AppScrollCore
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
private struct AppNodeList: View {
    let nodes: [AppNode]
    let surface: String
    let runtime: AppRuntime

    var body: some View {
        ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
            AppNodeView(node: node, surface: surface, runtime: runtime)
        }
    }
}

/// One node. The whole vocabulary lives in this switch.
private struct AppNodeView: View {
    let node: AppNode
    let surface: String
    let runtime: AppRuntime
    private var accent: Color { .panelAccent }

    private func event(_ kind: String, _ value: JSONValue? = nil) {
        runtime.sendEvent(surface: surface, ref: node.id, kind: kind, value: value)
    }

    private var children: [AppNode] { node.children ?? [] }

    var body: some View {
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
        case "toolbar":
            HStack(spacing: node.number("spacing").map { CGFloat($0) } ?? 8) {
                AppNodeList(nodes: children, surface: surface, runtime: runtime)
            }
            .padding(.horizontal, node.bool("flat") == true ? 2 : 7)
            .padding(.vertical, node.bool("flat") == true ? 4 : 6)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(node.bool("flat") == true ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.thinMaterial))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color.white.opacity(node.bool("flat") == true ? 0 : 0.075), lineWidth: 0.5))
            )
        case "composer":
            HStack(spacing: node.number("spacing").map { CGFloat($0) } ?? 8) {
                AppNodeList(nodes: children, surface: surface, runtime: runtime)
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(Color.white.opacity(0.018))
            )
        case "zstack":
            ZStack { AppNodeList(nodes: children, surface: surface, runtime: runtime) }
        case "grid":
            let cols = max(Int(node.number("columns") ?? 2), 1)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: cols), spacing: 8) {
                AppNodeList(nodes: children, surface: surface, runtime: runtime)
            }
        case "scroll":
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    AppNodeList(nodes: children, surface: surface, runtime: runtime)
                }
            }
        case "chatLayout":
            VStack(alignment: .leading, spacing: node.number("spacing").map { CGFloat($0) } ?? 8) {
                if let header = children.first {
                    AppNodeView(node: header, surface: surface, runtime: runtime)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if children.count > 1 {
                    ChatMessagesScrollView(
                        content: children[1],
                        scrollKey: node.string("scrollKey"),
                        scrollContext: node.string("scrollContext") ?? "default",
                        surface: surface,
                        runtime: runtime
                    )
                    .id("\(surface):\(node.string("scrollContext") ?? "default")")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if children.count > 2 {
                    Divider().opacity(0.08)
                    AppNodeView(node: children[2], surface: surface, runtime: runtime)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case "dateSeparator":
            HStack(spacing: 8) {
                Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
                Text(node.string("text") ?? "")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .fixedSize()
                Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 7)
        case "sectionLabel":
            Text(node.string("text") ?? "")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.35)
                .padding(.leading, 10)
                .padding(.top, 5)
                .padding(.bottom, 1)
        case "spacer":
            Spacer(minLength: node.number("min").map { CGFloat($0) } ?? 0)
        case "divider":
            Divider().opacity(0.15)

        // MARK: Content
        case "text":
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
                .foregroundColor(node.string("color").map(Color.init(hex:))
                    ?? (node.bool("accent") == true ? accent : .white.opacity(0.7)))
        case "image":
            if let b64 = node.string("data"), let data = Data(base64Encoded: b64),
               let img = NSImage(data: data) {
                if node.string("kind") == "qr" {
                    Image(nsImage: img)
                        .interpolation(.none)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: node.number("maxHeight").map { CGFloat($0) } ?? 160,
                               maxHeight: node.number("maxHeight").map { CGFloat($0) } ?? 160)
                        .padding(9)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .shadow(color: .black.opacity(0.22), radius: 9, y: 3)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("WhatsApp pairing QR code")
                } else {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: node.number("maxHeight").map { CGFloat($0) } ?? 120)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        case "messageBubble":
            MessageBubbleNode(
                text: node.string("text") ?? "",
                sender: node.string("sender") ?? "",
                time: node.string("time") ?? "",
                imageData: node.string("imageData"),
                mediaType: node.string("mediaType") ?? "",
                imageMaxHeight: node.number("imageMaxHeight").map { CGFloat($0) } ?? 180,
                maxWidth: node.number("maxWidth").map { CGFloat($0) } ?? 330,
                outgoing: node.bool("outgoing") == true,
                blurred: node.bool("blurred") == true,
                dimmed: node.bool("dimmed") == true,
                reactions: node.strings("reactions") ?? [],
                groupPosition: node.string("groupPosition") ?? "single",
                pending: node.bool("pending") == true,
                reactionEnabled: node.bool("reactionEnabled") == true,
                onReact: { event("react", .string($0)) },
                onReply: { event("reply") },
                accent: node.string("tint").map(Color.init(hex:)) ?? accent)
        case "replyPreview":
            ReplyPreviewNode(
                sender: node.string("sender") ?? "",
                text: node.string("text") ?? "",
                accent: node.string("tint").map(Color.init(hex:)) ?? accent,
                onCancel: { event("tap") })
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
            .buttonStyle(AppPressButtonStyle())
        case "iconButton":
            let buttonTint = node.string("tint").map(Color.init(hex:)) ?? accent
            Button(action: { event("tap") }) {
                Image(systemName: node.string("symbol") ?? "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.black.opacity(0.82))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(buttonTint)
                        .shadow(color: buttonTint.opacity(0.28), radius: 5, y: 2))
                    .contentShape(Circle())
            }
            .buttonStyle(AppPressButtonStyle())
            .disabled(node.bool("disabled") == true)
            .opacity(node.bool("disabled") == true ? 0.35 : 1)
            .help(node.string("label") ?? "")
        case "plainIconButton":
            let buttonTint = node.string("tint").map(Color.init(hex:)) ?? .white
            Button(action: { event("tap") }) {
                Image(systemName: node.string("symbol") ?? "ellipsis")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(buttonTint.opacity(node.bool("active") == true ? 1 : 0.72))
                    .frame(width: 28, height: 28)
                    .background(
                        Circle().fill(node.bool("active") == true
                            ? buttonTint.opacity(0.16) : Color.white.opacity(0.055))
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(AppPressButtonStyle())
            .disabled(node.bool("disabled") == true)
            .opacity(node.bool("disabled") == true ? 0.35 : 1)
            .help(node.string("label") ?? "")
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
            AppTextFieldNode(
                value: node.string("value") ?? "",
                placeholder: node.string("placeholder") ?? "",
                symbol: node.string("symbol"),
                kind: node.string("kind") ?? "default",
                wantsFocus: node.bool("focused") == true,
                focusRequest: Int(node.number("focusRequest") ?? 0),
                onChange: { event("change", .string($0)) },
                onSubmit: { event("submit") })
        case "secureField":
            AppSecureFieldNode(
                value: node.string("value") ?? "",
                placeholder: node.string("placeholder") ?? "",
                onChange: { event("change", .string($0)) })
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
        case "chatRow":
            ChatRowNode(node: node, accent: accent) { event("tap") }
        case "list":
            VStack(spacing: 0) {
                ForEach(Array(children.enumerated()), id: \.offset) { idx, child in
                    AppNodeView(node: child, surface: surface, runtime: runtime)
                        .padding(.vertical, 2)
                    if idx < children.count - 1 { Divider().opacity(0.045).padding(.leading, 40) }
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.028)))

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

/// A chat's reading position belongs to the app runtime, not the expanded
/// notch view: that view is transient and disappears whenever the notch closes.
private struct ChatMessagesScrollView: View {
    let content: AppNode
    let scrollKey: String?
    let scrollContext: String
    let surface: String
    let runtime: AppRuntime
    @State private var position = ScrollPosition(idType: String.self)
    @State private var metrics = ChatScrollMetrics.zero
    @State private var persistencePolicy = ChatScrollPersistencePolicy()
    @State private var restored = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var positionKey: String { "\(surface):\(scrollContext)" }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                AppNodeView(node: content, surface: surface, runtime: runtime)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(height: 1).id("chat-bottom")
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: ChatScrollMetrics.self) { geometry in
                ChatScrollMetrics(
                    offsetY: geometry.contentOffset.y,
                    visibleBottom: geometry.visibleRect.maxY,
                    contentHeight: geometry.contentSize.height
                )
            } action: { _, newValue in
                metrics = newValue
                // Save only while the user is actually manipulating the scroll
                // view. Notch collapse changes its geometry too, but must never be
                // allowed to overwrite the reading position.
                if persistencePolicy.shouldCaptureGeometry {
                    runtime.saveChatScrollOffset(newValue.offsetY, for: positionKey)
                }
            }
            .onScrollPhaseChange { _, newPhase, context in
                if persistencePolicy.transition(to: newPhase) {
                    runtime.saveChatScrollOffset(context.geometry.contentOffset.y, for: positionKey)
                }
            }
            .onAppear {
                guard !restored else { return }
                restored = true
                // Wait one run-loop turn so the scroll view has its final expanded
                // dimensions before applying the coordinate.
                DispatchQueue.main.async {
                    if let saved = runtime.chatScrollOffset(for: positionKey) {
                        position.scrollTo(y: saved)
                    } else if scrollKey != nil {
                        position.scrollTo(edge: .bottom)
                    }
                }
            }
            .onChange(of: scrollKey) { oldValue, newValue in
                guard oldValue != newValue else { return }
                // New content follows only when the reader was already at the end.
                // It must not yank someone away from an older message they are reading.
                if metrics.isNearBottom {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9)) {
                        position.scrollTo(edge: .bottom)
                    }
                }
            }

            if metrics.hasScrollableContent && !metrics.isNearBottom {
                Button {
                    let viewportHeight = max(metrics.visibleBottom - metrics.offsetY, 0)
                    let bottomOffset = max(metrics.contentHeight - viewportHeight, 0)
                    runtime.saveChatScrollOffset(bottomOffset, for: positionKey)
                    withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.88)) {
                        position.scrollTo(edge: .bottom)
                    }
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 27, height: 27)
                        .background(Circle().fill(.regularMaterial))
                        .overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.24), radius: 6, y: 2)
                }
                .buttonStyle(AppPressButtonStyle())
                .help("Jump to Latest Message")
                .padding(.trailing, 5)
                .padding(.bottom, 5)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: metrics.isNearBottom)
    }
}

private struct ChatScrollMetrics: Equatable {
    let offsetY: CGFloat
    let visibleBottom: CGFloat
    let contentHeight: CGFloat

    static let zero = ChatScrollMetrics(offsetY: 0, visibleBottom: 0, contentHeight: 0)
    var isNearBottom: Bool {
        ChatScrollPersistencePolicy.shouldFollowNewContent(
            visibleBottom: visibleBottom,
            contentHeight: contentHeight)
    }
    var hasScrollableContent: Bool {
        contentHeight - max(visibleBottom - offsetY, 0) > 18
    }
}

private struct MessageBubbleNode: View {
    let text: String
    let sender: String
    let time: String
    let imageData: String?
    let mediaType: String
    let imageMaxHeight: CGFloat
    let maxWidth: CGFloat
    let outgoing: Bool
    let blurred: Bool
    let dimmed: Bool
    let reactions: [String]
    let groupPosition: String
    let pending: Bool
    let reactionEnabled: Bool
    let onReact: (String) -> Void
    let onReply: () -> Void
    let accent: Color
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var topLeadingRadius: CGFloat {
        guard !outgoing else { return 16 }
        return groupPosition == "middle" || groupPosition == "last" ? 5 : 16
    }
    private var bottomLeadingRadius: CGFloat {
        guard !outgoing else { return 16 }
        return groupPosition == "middle" || groupPosition == "first" ? 5 : 16
    }
    private var topTrailingRadius: CGFloat {
        guard outgoing else { return 16 }
        return groupPosition == "middle" || groupPosition == "last" ? 5 : 16
    }
    private var bottomTrailingRadius: CGFloat {
        guard outgoing else { return 16 }
        return groupPosition == "middle" || groupPosition == "first" ? 5 : 16
    }

    private var bubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: topLeadingRadius,
            bottomLeadingRadius: bottomLeadingRadius,
            bottomTrailingRadius: bottomTrailingRadius,
            topTrailingRadius: topTrailingRadius,
            style: .continuous)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if outgoing { Spacer(minLength: 72) }
            VStack(alignment: outgoing ? .trailing : .leading, spacing: 2) {
                if !outgoing, !sender.isEmpty {
                    Text(sender)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 5)
                        .padding(.bottom, 1)
                }
                VStack(alignment: outgoing ? .trailing : .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                    if let imageData, !imageData.isEmpty,
                       let data = Data(base64Encoded: imageData), let image = NSImage(data: data) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: maxWidth - 14, maxHeight: imageMaxHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .blur(radius: blurred && !hovering ? 9 : 0)
                    } else if mediaType.lowercased().contains("image") {
                        VStack(spacing: 6) {
                            Image(systemName: "photo")
                                .font(.system(size: 20, weight: .light))
                            Text("Preview unavailable")
                                .font(.system(size: 9.5, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .frame(width: min(maxWidth - 14, 190), height: 86)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color.white.opacity(0.045)))
                        .blur(radius: blurred && !hovering ? 7 : 0)
                    }
                    Text(text)
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundColor(.white.opacity(dimmed ? 0.34 : 0.92))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .blur(radius: blurred && !hovering ? 5 : 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        bubbleShape
                            .fill(outgoing ? accent.opacity(dimmed ? 0.14 : 0.72)
                                  : Color.white.opacity(dimmed ? 0.035 : (hovering ? 0.14 : 0.095)))
                            .overlay(bubbleShape.stroke(Color.white.opacity(outgoing ? 0.035 : 0.055), lineWidth: 0.5))
                    )
                    .shadow(color: Color.black.opacity(hovering ? 0.16 : 0.06), radius: hovering ? 5 : 2, y: 1)
                    if !reactions.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(reactions, id: \.self) { reaction in
                                Text(reaction)
                                    .font(.system(size: 9.5, weight: .medium))
                                    .padding(.horizontal, 6).padding(.vertical, 2.5)
                                    .background(Capsule().fill(.thinMaterial))
                                    .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.5))
                            }
                        }
                        .blur(radius: blurred && !hovering ? 4 : 0)
                        .padding(outgoing ? .trailing : .leading, 7)
                        .offset(y: -4)
                    }
                    if !time.isEmpty || pending {
                        HStack(spacing: 3) {
                            if pending {
                                Image(systemName: "clock")
                                    .font(.system(size: 7.5, weight: .medium))
                            }
                            if !time.isEmpty { Text(time) }
                        }
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.white.opacity(dimmed ? 0.2 : (hovering ? 0.46 : 0.28)))
                        .padding(.horizontal, 5)
                        .opacity(hovering || pending ? 1 : 0.72)
                    }
                }
                .scaleEffect(hovering && !reduceMotion ? 1.006 : 1, anchor: outgoing ? .trailing : .leading)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovering)
                .overlay(alignment: outgoing ? .topLeading : .topTrailing) {
                    if hovering && reactionEnabled {
                        HStack(spacing: 2) {
                            ForEach(["❤️", "👍", "😂"], id: \.self) { emoji in
                                MessageActionButton(label: "React \(emoji)") {
                                    Text(emoji).font(.system(size: 10))
                                } action: {
                                    onReact(emoji)
                                }
                            }
                            MessageActionButton(label: "Reply") {
                                Image(systemName: "arrowshape.turn.up.left.fill")
                                    .font(.system(size: 8.5, weight: .semibold))
                            } action: {
                                onReply()
                            }
                        }
                        .padding(3)
                        .background(Capsule().fill(.regularMaterial))
                        .overlay(Capsule().stroke(Color.white.opacity(0.11), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                        .offset(x: outgoing ? -88 : 88, y: 1)
                        .transition(.scale(scale: 0.88).combined(with: .opacity))
                        .onHover { if $0 { hovering = true } }
                    }
                }
                .contextMenu {
                    if reactionEnabled {
                        Button("Reply", systemImage: "arrowshape.turn.up.left") { onReply() }
                        Divider()
                    }
                    if !text.isEmpty {
                        Button("Copy Message") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                    }
                    if reactionEnabled {
                        if !text.isEmpty { Divider() }
                        ForEach(["❤️", "👍", "😂", "😮", "😢", "🙏"], id: \.self) { emoji in
                            Button(emoji) { onReact(emoji) }
                        }
                        Divider()
                        Button("Remove Reaction") { onReact("") }
                    }
                }
            }
            if !outgoing { Spacer(minLength: 72) }
        }
        .frame(maxWidth: .infinity, alignment: outgoing ? .trailing : .leading)
        .padding(.top, groupPosition == "first" || groupPosition == "single" ? 3 : 0)
        .accessibilityElement(children: .combine)
        .accessibilityHint(blurred ? "Hover to reveal private content" : "")
    }
}

private struct MessageActionButton<Label: View>: View {
    let label: String
    let content: Label
    let action: () -> Void

    init(label: String, @ViewBuilder content: () -> Label, action: @escaping () -> Void) {
        self.label = label
        self.content = content()
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            content
                .foregroundStyle(.primary)
                .frame(width: 20, height: 20)
                .contentShape(Circle())
        }
        .buttonStyle(AppPressButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct ReplyPreviewNode: View {
    let sender: String
    let text: String
    let accent: Color
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Capsule().fill(accent).frame(width: 3, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to \(sender)")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(accent.opacity(0.9))
                    .lineLimit(1)
                Text(text)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Cancel Reply")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(0.035)))
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }
}

private struct ChatRowNode: View {
    let node: AppNode
    let accent: Color
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var indicator: Color {
        node.string("indicatorColor").map(Color.init(hex:)) ?? accent
    }
    private var unreadCount: Int { Int(node.number("unread") ?? 0) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(
                        LinearGradient(
                            colors: [indicator.opacity(0.34), indicator.opacity(0.16)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                    if node.bool("protected") == true {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10, weight: .semibold))
                    } else {
                        Text(node.string("avatarText") ?? "?")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                }
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 30, height: 30)
                .overlay(alignment: .bottomTrailing) {
                    if node.bool("watched") == true {
                        Circle().fill(indicator).frame(width: 7, height: 7)
                            .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(node.string("title") ?? "")
                            .font(.system(size: 12, weight: unreadCount > 0 ? .semibold : .medium))
                            .foregroundColor(.white.opacity(0.92))
                            .lineLimit(1)
                        if node.bool("pinned") == true {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 7.5, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 5)
                        if let timestamp = node.string("timestamp"), !timestamp.isEmpty {
                            Text(timestamp)
                                .font(.system(size: 8.5, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                    }
                    HStack(spacing: 6) {
                        if let subtitle = node.string("subtitle"), !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if unreadCount > 0 {
                            Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                                .foregroundColor(.black.opacity(0.82))
                                .padding(.horizontal, 5).frame(minHeight: 16)
                                .background(Capsule().fill(indicator))
                                .contentTransition(.numericText())
                        }
                    }
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .frame(minHeight: 43)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.075 : 0.001)))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(AppPressButtonStyle())
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.88), value: unreadCount)
        .accessibilityLabel(node.string("title") ?? "Chat")
        .accessibilityValue(unreadCount > 0 ? "\(unreadCount) unread" : "")
    }
}

private struct AppPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .brightness(configuration.isPressed ? 0.08 : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.78),
                       value: configuration.isPressed)
    }
}

private struct AppRowNode: View {
    let node: AppNode
    let accent: Color
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var indicator: Color {
        node.string("indicatorColor").map(Color.init(hex:)) ?? accent
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let sym = node.string("symbol") {
                    Image(systemName: sym)
                        .font(.system(size: 13, weight: node.bool("prominent") == true ? .semibold : .regular))
                        .foregroundColor(node.bool("prominent") == true ? indicator : .white.opacity(0.58))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(indicator.opacity(node.bool("prominent") == true ? 0.13 : 0)))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.string("title") ?? "")
                        .font(.system(size: node.number("titleSize").map { CGFloat($0) } ?? 12.5,
                                      weight: node.bool("prominent") == true ? .semibold : .medium))
                        .foregroundColor(.white.opacity(node.bool("prominent") == true ? 0.96 : 0.86))
                        .lineLimit(1)
                    if let sub = node.string("subtitle") {
                        Text(sub)
                            .font(.system(size: 10.5, weight: node.bool("prominent") == true ? .medium : .regular))
                            .foregroundColor(node.bool("prominent") == true ? indicator.opacity(0.85) : .white.opacity(0.42))
                    }
                }
                Spacer()
                if let value = node.string("value") {
                    Text(value)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.58))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.055)))
                }
                if node.id != nil && node.bool("chevron") != false {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(.white.opacity(hovering ? 0.55 : 0.22))
                        .offset(x: hovering && !reduceMotion ? 1.5 : 0)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.065 : 0.001)))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(AppPressButtonStyle())
        .disabled(node.id == nil)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovering)
    }
}

/// Keeps editing state in-process instead of waiting for an app protocol
/// round-trip after every key. The native commit callback makes Return reliable.
private struct AppTextFieldNode: View {
    let value: String
    let placeholder: String
    let symbol: String?
    let kind: String
    let wantsFocus: Bool
    let focusRequest: Int
    let onChange: (String) -> Void
    let onSubmit: () -> Void
    @State private var text: String
    @FocusState private var focused: Bool

    init(value: String, placeholder: String, symbol: String?, kind: String, wantsFocus: Bool, focusRequest: Int,
         onChange: @escaping (String) -> Void, onSubmit: @escaping () -> Void) {
        self.value = value
        self.placeholder = placeholder
        self.symbol = symbol
        self.kind = kind
        self.wantsFocus = wantsFocus
        self.focusRequest = focusRequest
        self.onChange = onChange
        self.onSubmit = onSubmit
        _text = State(initialValue: value)
    }

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.35))
            }
            TextField(placeholder, text: $text, onCommit: onSubmit)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
            if kind == "search", !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear Search")
            }
        }
        .padding(.horizontal, kind == "composer" ? 10 : 8)
        .padding(.vertical, kind == "composer" ? 7 : 6)
        .background(
            RoundedRectangle(cornerRadius: kind == "composer" ? 15 : 9, style: .continuous)
                .fill(Color.white.opacity(focused ? 0.085 : 0.055))
                .overlay(
                    RoundedRectangle(cornerRadius: kind == "composer" ? 15 : 9, style: .continuous)
                        .stroke(Color.white.opacity(focused ? 0.14 : 0.055), lineWidth: 0.5)
                )
        )
        .onChange(of: text) { _, newValue in
            if newValue != value { onChange(newValue) }
        }
        .onChange(of: value) { _, newValue in
            if text != newValue { text = newValue }
        }
        .onAppear {
            if wantsFocus { DispatchQueue.main.async { focused = true } }
        }
        .onChange(of: focusRequest) { _, _ in
            if wantsFocus { DispatchQueue.main.async { focused = true } }
        }
    }
}

private struct AppSecureFieldNode: View {
    let value: String
    let placeholder: String
    let onChange: (String) -> Void
    @State private var text: String

    init(value: String, placeholder: String, onChange: @escaping (String) -> Void) {
        self.value = value
        self.placeholder = placeholder
        self.onChange = onChange
        _text = State(initialValue: value)
    }

    var body: some View {
        SecureField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
            .onChange(of: text) { _, newValue in
                if newValue != value { onChange(newValue) }
            }
            .onChange(of: value) { _, newValue in
                if text != newValue { text = newValue }
            }
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
