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
        case "spacer":
            Spacer(minLength: node.number("min").map { CGFloat($0) } ?? 0)
        case "divider":
            Divider().opacity(0.15)

        // MARK: Content
        case "text":
            Text(node.string("text") ?? "")
                .font(textFont)
                .foregroundColor(.white.opacity(textOpacity))
                .fixedSize(horizontal: false, vertical: true)
        case "icon":
            Image(systemName: node.string("symbol") ?? "questionmark")
                .font(.system(size: node.number("size").map { CGFloat($0) } ?? 14))
                .foregroundColor(node.bool("accent") == true ? accent : .white.opacity(0.7))
        case "image":
            if let b64 = node.string("data"), let data = Data(base64Encoded: b64),
               let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: node.number("maxHeight").map { CGFloat($0) } ?? 120)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
            .buttonStyle(.plain)
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
            TextField(node.string("placeholder") ?? "", text: Binding(
                get: { node.string("value") ?? "" },
                set: { event("change", .string($0)) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
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
            Button(action: { event("tap") }) {
                HStack(spacing: 10) {
                    if let sym = node.string("symbol") {
                        Image(systemName: sym)
                            .font(.system(size: 13))
                            .foregroundColor(accent)
                            .frame(width: 22)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(node.string("title") ?? "")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                        if let sub = node.string("subtitle") {
                            Text(sub).font(.caption2).foregroundColor(.white.opacity(0.45))
                        }
                    }
                    Spacer()
                    if let value = node.string("value") {
                        Text(value).font(.system(size: 12)).foregroundColor(.white.opacity(0.6))
                    }
                    if node.id != nil && node.bool("chevron") != false {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.25))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(node.id == nil)
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
