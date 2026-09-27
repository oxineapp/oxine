import AppKit
import NoticeBridge
import SwiftUI
import UniformTypeIdentifiers

/// Notice Playground: a developer app for trying Oxine's notch notices. It
/// talks to a running Oxine (see `NoticeBridge`); it isn't part of Oxine.
@main
struct PlaygroundApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }

    var body: some Scene {
        WindowGroup("Notice Playground") {
            PlaygroundView()
                .frame(minWidth: 640, minHeight: 720)
        }
        .windowResizability(.contentMinSize)
    }
}

struct PlaygroundView: View {
    @ObservedObject private var client = BridgeClient.shared

    // The notice being built.
    @State private var title = "Hello from the notch"
    @State private var subtitle = ""
    @State private var detail = ""
    @State private var icon = "sparkles"
    @State private var tint: Color = .purple
    @State private var motion = "bounce"
    @State private var picture: Picture = .symbol
    @State private var appID = "com.spotify.client"
    @State private var imagePNG: Data?
    @State private var placement = "automatic"
    @State private var whenOpen = "automatic"
    @State private var urgent = false
    @State private var showProgress = false
    @State private var progress = 0.4
    @State private var fillProgress = false
    @State private var duration = 6.0
    @State private var sticky = false
    @State private var group = ""
    @State private var sound = "None"
    @State private var haptic = false
    @State private var actions: [DraftAction] = [DraftAction(title: "Nice", role: "primary")]
    @State private var look = "standard"
    @State private var shape = "automatic"
    @State private var entrance = "automatic"
    @State private var hero = ""
    @State private var emoji = ""
    @State private var personName = ""
    @State private var reactions = false
    @State private var reply = false
    @State private var edits: [String: Double] = [:]

    private enum Picture: String, CaseIterable, Identifiable {
        case symbol = "Symbol", image = "Image", nowPlaying = "Now playing", appIcon = "App icon"
        var id: String { rawValue }
    }

    private struct DraftAction: Identifiable {
        let id = UUID()
        var title: String
        var role = "normal"
        var hold = false
    }

    private static let placements = [("automatic", "Smart"), ("notch", "On the notch"), ("below", "Under the notch"), ("left", "Left of the notch"),
                                     ("right", "Right of the notch"), ("floating", "Floating below it")]
    private static let openBehaviors = [("automatic", "Smart"), ("attach", "Stay under the notch"),
                                        ("float", "Float below it"), ("wait", "Wait until it closes")]
    private static let motions = ["none", "bounce", "pulse", "wiggle", "breathe", "rotate", "waves"]
    private static let styles = [("automatic", "Smart"), ("notch", "On the notch"), ("floating", "Floating")]
    private static let looks = [("standard", "Standard"), ("message", "Message"), ("hero", "Big value"), ("media", "Big picture")]
    private static let shapes = [("automatic", "Smart"), ("circle", "Circle"), ("pill", "Pill")]
    private static let entrances = ["automatic", "drop", "pop", "shake", "knock", "ring", "bounce", "celebrate"]
    private static let roles = ["normal", "primary", "destructive"]
    private static let sounds = ["None", "Glass", "Ping", "Pop", "Purr", "Tink", "Hero", "Funk",
                                 "Blow", "Bottle", "Frog", "Morse", "Submarine", "Sosumi", "Basso"]
    private static let symbols = ["sparkles", "bell.fill", "star.fill", "heart.fill", "bolt.fill",
                                  "flame.fill", "leaf.fill", "moon.fill", "paperplane.fill", "gift.fill"]

    /// The whole-number fields among `tunables`.
    private static let integers: Set<String> = ["smartSideMaxCharacters", "sideMaxActions", "listMax"]

    /// Sizes and timing: (field, label, range, unit).
    private static let tunables: [(String, String, ClosedRange<Double>, String)] = [
        ("belowFont", "Short text", 9...16, "pt"), ("sideFont", "Side text", 9...16, "pt"),
        ("sideMaxWidth", "Side width", 80...260, "pt"), ("peekTitleFont", "Full title", 10...18, "pt"),
        ("peekDetailFont", "Full detail", 9...15, "pt"), ("peekMinWidth", "Full min width", 0...400, "pt"),
        ("peekWidth", "Floating width", 220...420, "pt"), ("duration", "Stays for", 1...20, "s"),
        ("lingerAfterPeek", "After pointing", 0.5...8, "s"), ("springResponse", "Spring speed", 0.15...0.9, "s"),
        ("springDamping", "Spring bounce", 0.4...1, ""), ("smartSideMaxCharacters", "Ear title limit", 8...40, "chars"),
        ("sideButtonFont", "Ear button text", 8...13, "pt"), ("sideMaxActions", "Ear buttons", 1...3, "count"),
        ("floatingGap", "Floating gap", 0...24, "pt"), ("listRowHeight", "List row height", 40...70, "pt"),
        ("listMax", "List keeps", 5...50, "count"),
    ]

    var body: some View {
        Form {
            connection
            examples
            builder
            showing
            tuning
        }
        .formStyle(.grouped)
    }

    // MARK: connection

    private var connection: some View {
        Section {
            HStack(spacing: 10) {
                Circle().fill(client.connected ? .green : (client.bridgeOn ? .orange : .secondary))
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(client.connected ? "Connected to Oxine" : client.bridgeOn ? "Waiting for Oxine…" : "Not connected")
                    Text(client.bridgeOn
                         ? (client.connected ? "Notices you send here show on the notch." : "Make sure Oxine is running with the notch on.")
                         : "Oxine ignores outside apps until you let this one in. Only turn it on on your own Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Let the playground in", isOn: Binding(get: { client.bridgeOn }, set: { client.setBridge($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            Picker("Oxine's style", selection: Binding(get: { client.style }, set: { client.style = $0 })) {
                ForEach(Self.styles, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented)
            .disabled(!client.bridgeOn)
        } footer: {
            Text("The same as Settings → Notch → Notifications in Oxine. Floating keeps everything on glass under the notch.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: examples

    private var examples: some View {
        ForEach(Examples.groups) { group in
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                    ForEach(group.examples) { example in
                        Button(action: example.run) {
                            Label(example.name, systemImage: example.icon)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .controlSize(.large)
                    }
                }
                .disabled(!client.bridgeOn)
            } header: {
                Text(group.name)
            } footer: {
                Text(group.note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: builder

    private var builder: some View {
        Section("Build your own") {
            TextField("Title", text: $title)
            TextField("Subtitle", text: $subtitle, prompt: Text("Optional"))
            TextField("Detail", text: $detail, prompt: Text("Optional. With detail, Smart puts it under the notch"), axis: .vertical)
                .lineLimit(1...4)
            Picker("Picture", selection: $picture) { ForEach(Picture.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)
            switch picture {
            case .symbol:
                LabeledContent("Symbol") {
                    HStack(spacing: 6) {
                        TextField("", text: $icon).frame(width: 150)
                        ForEach(Self.symbols, id: \.self) { name in
                            Button { icon = name } label: { Image(systemName: name).foregroundStyle(icon == name ? tint : .secondary) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            case .image:
                LabeledContent("Image") {
                    HStack {
                        if let imagePNG, let image = NSImage(data: imagePNG) {
                            Image(nsImage: image).resizable().frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        Button("Choose…") { chooseImage() }
                    }
                }
            case .nowPlaying:
                Text("Oxine fills in the cover of what the notch is playing. Leave the title empty to use the song's.")
                    .font(.caption).foregroundStyle(.secondary)
            case .appIcon:
                TextField("App bundle id", text: $appID)
            }
            LabeledContent("Color and motion") {
                HStack {
                    ColorPicker("", selection: $tint).labelsHidden()
                    Picker("", selection: $motion) { ForEach(Self.motions, id: \.self) { Text($0.capitalized).tag($0) } }
                        .labelsHidden().frame(width: 120)
                }
            }
            Picker("Look", selection: $look) { ForEach(Self.looks, id: \.0) { Text($0.1).tag($0.0) } }
                .pickerStyle(.segmented)
            switch look {
            case "message":
                TextField("From", text: $personName, prompt: Text("A name: their initials on a color of their own"))
                Toggle("Emoji reactions", isOn: $reactions)
                Toggle("Reply field (floating)", isOn: $reply)
            case "hero":
                TextField("Big value", text: $hero, prompt: Text("4:59, 2 – 1, 10%"))
            default:
                EmptyView()
            }
            LabeledContent("Floating") {
                HStack {
                    Picker("", selection: $shape) { ForEach(Self.shapes, id: \.0) { Text($0.1).tag($0.0) } }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 190)
                    Picker("", selection: $entrance) { ForEach(Self.entrances, id: \.self) { Text($0.capitalized).tag($0) } }
                        .labelsHidden().frame(width: 120)
                }
            }
            TextField("Emoji", text: $emoji, prompt: Text("Optional, in place of the picture"))
            Picker("Where", selection: $placement) { ForEach(Self.placements, id: \.0) { Text($0.1).tag($0.0) } }
            Picker("While the notch is open", selection: $whenOpen) {
                ForEach(Self.openBehaviors, id: \.0) { Text($0.1).tag($0.0) }
            }
            Text("These are the app's wish. Your choice in Oxine's settings, overall or for this app, wins over them; Smart uses them first.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Urgent (glows, stays until dismissed)", isOn: $urgent)
            Toggle("Progress", isOn: $showProgress)
            if showProgress {
                Slider(value: $progress, in: 0...1) { Text("Amount") }
                Toggle("Fill it live", isOn: $fillProgress)
            }
            Toggle("Stay until dismissed", isOn: $sticky)
            if !sticky {
                Slider(value: $duration, in: 1...30, step: 1) { Text("Stays for \(Int(duration)) s") }
            }
            TextField("Group", text: $group, prompt: Text("Same group replaces instead of queueing"))
            Picker("Sound", selection: $sound) { ForEach(Self.sounds, id: \.self) { Text($0).tag($0) } }
            Toggle("Tap the trackpad", isOn: $haptic)
            ForEach($actions) { $action in
                HStack {
                    TextField("Button", text: $action.title)
                    Picker("", selection: $action.role) { ForEach(Self.roles, id: \.self) { Text($0.capitalized).tag($0) } }
                        .labelsHidden().frame(width: 120)
                    Toggle("Hold", isOn: $action.hold).toggleStyle(.checkbox)
                    Button { actions.removeAll { $0.id == action.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            if actions.count < 3 {
                Button { actions.append(DraftAction(title: "Button \(actions.count + 1)")) } label: {
                    Label("Add a button", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
            }
            HStack {
                Button("Send") { send() }.keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent)
                Button("Send three") { for _ in 0..<3 { send() } }
                Spacer()
                Button("Random example") { Examples.random() }
            }
            .disabled(!client.bridgeOn)
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        // Small is plenty for a notch icon, and keeps the message light.
        let side: CGFloat = 96
        let small = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
        guard let tiff = small.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        imagePNG = rep.representation(using: .png, properties: [:])
    }

    private func send() {
        var p = NoticePayload(
            icon: icon.isEmpty ? "sparkles" : icon, tint: .init(tint), title: title,
            subtitle: subtitle.isEmpty ? nil : subtitle, detail: detail.isEmpty ? nil : detail,
            imagePNG: picture == .image ? imagePNG : nil, useNowPlayingArt: picture == .nowPlaying,
            appIcon: picture == .appIcon && !appID.isEmpty ? appID : nil, iconMotion: motion,
            progress: showProgress ? (fillProgress ? 0 : progress) : nil,
            actions: actions.enumerated().map { i, a in
                .init(id: "button\(i + 1)", title: a.title.isEmpty ? "Button \(i + 1)" : a.title, role: a.role,
                      hold: a.hold ? true : nil)
            },
            placement: placement, whenOpen: whenOpen, emphasis: urgent ? "urgent" : "normal",
            duration: duration, sticky: sticky || (showProgress && fillProgress), group: group.isEmpty ? nil : group,
            sound: sound == "None" ? nil : sound, haptic: haptic)
        if picture != .nowPlaying, p.title.isEmpty { p.title = "Untitled" }
        p.look = look
        p.shape = shape
        p.entrance = entrance
        p.emoji = emoji.isEmpty ? nil : emoji
        if look == "hero", !hero.isEmpty { p.hero = hero }
        if look == "message" {
            p.personName = personName.isEmpty ? (title.isEmpty ? nil : title) : personName
            if reactions { p.reactions = ["❤️", "👍", "😂", "😮"] }
            if reply { p.reply = "Reply" }
        }
        client.post(p, name: p.title.isEmpty ? "Now playing" : p.title)
        guard showProgress, fillProgress else { return }
        let stays = sticky
        Task { @MainActor in
            for step in 1...30 {
                try? await Task.sleep(for: .milliseconds(150))
                guard client.stillShowing(p.id) else { return }
                p.progress = Double(step) / 30
                client.post(p)
            }
            p.sticky = stays
            client.post(p)
        }
    }

    // MARK: showing now

    private var showing: some View {
        Section {
            if let notices = client.state?.notices, !notices.isEmpty {
                ForEach(notices) { notice in
                    HStack {
                        Image(systemName: notice.icon).foregroundStyle(notice.tint.color).frame(width: 18)
                        Text(notice.title).lineLimit(1)
                        Spacer()
                        Text(notice.spot).foregroundStyle(.secondary)
                        Button { client.dismiss(notice.id) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Nothing on the notch or in the list.").foregroundStyle(.secondary)
            }
            if !client.log.isEmpty {
                DisclosureGroup("Pressed") {
                    ForEach(Array(client.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption, design: .monospaced))
                    }
                }
            }
        } header: {
            HStack {
                Text("Showing now")
                Spacer()
                Button("Clear all") { client.dismissAll() }.buttonStyle(.borderless).disabled(!client.connected)
            }
        }
    }

    // MARK: tuning

    private var tuning: some View {
        Section {
            ForEach(Self.tunables, id: \.0) { key, label, range, unit in
                let value = edits[key] ?? client.state?.metrics[key] ?? range.lowerBound
                LabeledContent(label) {
                    HStack {
                        Slider(value: Binding(get: { value }, set: { edits[key] = $0 }), in: range,
                               onEditingChanged: { editing in if !editing { sendMetrics() } })
                        Text(Self.integers.contains(key) ? "\(Int(value.rounded()))"
                             : String(format: value < 3 ? "%.2f %@" : "%.0f %@", value, unit))
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                    }
                }
            }
            Toggle("Full version matches the notch's width", isOn: Binding(
                get: { (edits["peekMatchesNotch"] ?? client.state?.metrics["peekMatchesNotch"] ?? 1) != 0 },
                set: { edits["peekMatchesNotch"] = $0 ? 1 : 0; sendMetrics() }))
        } header: {
            HStack {
                Text("Sizes and timing")
                Spacer()
                Button("Reset") {
                    edits = [:]
                    client.setMetrics(NoticeMetricsChange())
                }
                .buttonStyle(.borderless)
            }
        } footer: {
            Text("Live for every notice. Oxine saves only what you change.").font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!client.connected)
    }

    private func sendMetrics() {
        var change = NoticeMetricsChange()
        for (key, value) in edits {
            switch key {
            case "peekMatchesNotch": change.flags[key] = value != 0
            case _ where Self.integers.contains(key): change.integers[key] = Int(value.rounded())
            default: change.numbers[key] = value
            }
        }
        client.setMetrics(change)
    }
}
