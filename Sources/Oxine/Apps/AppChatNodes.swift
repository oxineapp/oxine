import AppKit
import NotchKit
import SwiftUI

/// The conversation part of the `api: 1` view vocabulary: a chat (header,
/// messages, composer), its bubbles, the list of chats, and the small
/// controls around them. People look the way they do in notch notices
/// (`PersonAvatar`), bubbles take the notice's bubble shape, reactions pop
/// the way a notice's do (`ReactionPicker`), and the composer is the notice's
/// reply capsule. A contact's `tint` / `indicatorColor` is the color their
/// notices and the notch's attention glow use too.
struct AppChatNode: View {
    let node: AppNode
    let surface: String
    let runtime: AppRuntime

    private func event(_ kind: String, _ value: JSONValue? = nil) {
        runtime.sendEvent(surface: surface, ref: node.id, kind: kind, value: value)
    }

    private var children: [AppNode] { node.children ?? [] }
    private var spacing: CGFloat { node.number("spacing").map { CGFloat($0) } ?? 8 }

    /// A button taps, or with `pick` ("file" or "image") asks the person for
    /// files first and sends their paths as "pick": only what they chose.
    private func press() {
        guard let kind = node.string("pick") else { event("tap"); return }
        pickFiles(images: kind == "image") { paths in event("pick", .array(paths.map { .string($0) })) }
    }
    private var tint: Color { node.color("tint") ?? .panelAccent }

    var body: some View {
        switch node.type {
        case "chatLayout":
            ChatLayout(node: node, surface: surface, runtime: runtime)
        case "toolbar":
            HStack(spacing: spacing) {
                AppNodeList(nodes: children, surface: surface, runtime: runtime)
            }
            .padding(.horizontal, node.bool("flat") == true ? 0 : 6)
            .padding(.vertical, node.bool("flat") == true ? 0 : 5)
            .background {
                if node.bool("flat") != true {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.06))
                }
            }
        case "composer":
            ChatComposer(spacing: spacing) {
                AppNodeList(nodes: children, surface: surface, runtime: runtime)
            }
        case "dateSeparator":
            Text(node.string("text") ?? "")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(.white.opacity(0.06), in: Capsule())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        case "sectionLabel":
            Text((node.string("text") ?? "").uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.white.opacity(0.4))
                .padding(.leading, 8)
                .padding(.top, 6)
        case "messageBubble":
            MessageBubble(node: node, tint: tint, react: { event("react", .string($0)) }, reply: { event("reply") })
        case "replyPreview":
            ReplyPreview(sender: node.string("sender") ?? "", text: node.string("text") ?? "", tint: tint) {
                event("tap")
            }
        case "chatRow":
            ChatRow(node: node) { event("tap") }
        case "iconButton":
            ChatIconButton(symbol: node.string("symbol") ?? "arrow.up", tint: tint, filled: true,
                           active: true, disabled: node.bool("disabled") == true,
                           label: node.string("label"), action: press)
        case "swatch":
            ColorSwatch(color: node.color("color"), selected: node.bool("selected") == true,
                        label: node.string("label")) { event("tap") }
        case "plainIconButton":
            ChatIconButton(symbol: node.string("symbol") ?? "ellipsis", tint: node.color("tint") ?? .white,
                           filled: false, active: node.bool("active") == true,
                           disabled: node.bool("disabled") == true,
                           label: node.string("label"), action: press)
        default:
            EmptyView()
        }
    }
}

// MARK: - The chat

/// A header that stays, the messages scrolling under it, and the composer
/// at the bottom. Children by position: header, messages, composer.
///
/// The messages remember where the reader left them (per conversation, in the
/// runtime, since the notch rebuilds its views every time it opens): only a
/// scroll the reader made moves the mark, never a resize or a jump. A new
/// message (`scrollKey` changed) scrolls into view only for a reader already
/// at the end; one reading back further gets a button to jump down instead.
private struct ChatLayout: View {
    let node: AppNode
    let surface: String
    let runtime: AppRuntime
    @State private var position = ScrollPosition(idType: String.self)
    @State private var awayFromEnd = false
    @State private var dropTarget = false

    private func receiveDrop(_ providers: [NSItemProvider]) {
        Task { @MainActor in
            var paths: [String] = []
            for provider in providers {
                if let url = await Self.fileURL(in: provider) { paths.append(url.path) }
            }
            guard !paths.isEmpty else { return }
            runtime.sendEvent(surface: surface, ref: node.id, kind: "drop", value: .array(paths.map { .string($0) }))
        }
    }

    /// The file a dropped item stands for, if it's a file.
    @MainActor private static func fileURL(in provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { (done: CheckedContinuation<URL?, Never>) in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                done.resume(returning: url?.isFileURL == true ? url : nil)
            }
        }
    }

    private var children: [AppNode] { node.children ?? [] }
    private var place: String { "\(surface):\(node.string("scrollContext") ?? "default")" }
    /// Closer to the end than this counts as at the end.
    private static let endSlack: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: node.number("spacing").map { CGFloat($0) } ?? 8) {
            if let header = children.first {
                AppNodeView(node: header, surface: surface, runtime: runtime)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if children.count > 1 {
                messages(children[1])
                    // Another conversation is another scroll view, with its own mark.
                    .id(place)
                    // Files dropped on the messages go to the app as "drop" (their paths).
                    .onDrop(of: [.fileURL], isTargeted: node.id == nil ? nil : $dropTarget) { providers in
                        guard node.id != nil else { return false }
                        receiveDrop(providers)
                        return true
                    }
                    .overlay {
                        if dropTarget {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.panelAccent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                                .background(Color.panelAccent.opacity(0.08),
                                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .allowsHitTesting(false)
                        }
                    }
            }
            if children.count > 2 {
                AppNodeView(node: children[2], surface: surface, runtime: runtime)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // A chat wants all the room it's given: in a tab that fits its
        // content, that's the tab's whole height.
        .frame(maxWidth: .infinity, idealHeight: 10_000, maxHeight: .infinity, alignment: .topLeading)
    }

    private func messages(_ content: AppNode) -> some View {
        let saved = runtime.readingPosition(place)
        return ScrollView {
            AppNodeView(node: content, surface: surface, runtime: runtime)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 2)
        }
        .scrollPosition($position)
        // A chat opens at its newest message unless the reader left it elsewhere.
        .defaultScrollAnchor(saved == nil ? .bottom : .top, for: .initialOffset)
        .onAppear {
            guard let saved else { return }
            DispatchQueue.main.async { position.scrollTo(y: saved) }
        }
        .onScrollGeometryChange(for: Bool.self) { g in
            g.contentSize.height - g.visibleRect.maxY > Self.endSlack
        } action: { _, away in
            withAnimation(.easeOut(duration: 0.16)) { awayFromEnd = away }
        }
        .onScrollPhaseChange { old, new, context in
            // The reader's own scroll just ended (a jump or a resize animates,
            // and doesn't count). At the end means "follow the newest".
            guard new == .idle, old != .animating, old != .idle else { return }
            let g = context.geometry
            let atEnd = g.contentSize.height - g.visibleRect.maxY <= Self.endSlack
            runtime.keepReadingPosition(atEnd ? nil : g.contentOffset.y, for: place)
        }
        .onChange(of: node.string("scrollKey")) { _, _ in
            // Something new: follow it if the reader was at the end, and
            // always when it's their own (they just sent it). After this
            // update's layout, or it stops short of the newest bubble.
            guard !awayFromEnd || endsWithOwnMessage(content) else { return }
            runtime.keepReadingPosition(nil, for: place)
            DispatchQueue.main.async {
                withAnimation(.smooth(duration: 0.3)) { position.scrollTo(edge: .bottom) }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if awayFromEnd {
                Button {
                    runtime.keepReadingPosition(nil, for: place)
                    withAnimation(.smooth(duration: 0.3)) { position.scrollTo(edge: .bottom) }
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(AppPressStyle())
                .glassEffect(.regular.interactive(), in: Circle())
                .help("Newest message")
                .padding(6)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
    }
}

/// Asks the person for files (photos and videos only, for `images`), and
/// hands over the paths they chose. Oxine comes forward for the panel.
@MainActor func pickFiles(images: Bool, _ chosen: @escaping ([String]) -> Void) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    if images { panel.allowedContentTypes = [.image, .movie] }
    // The notch stays open behind the panel, so the chat is still there after.
    NotchCoordinator.shared.holdOpen(true)
    NSApp.activate()
    panel.begin { response in
        NotchCoordinator.shared.holdOpen(false)
        guard response == .OK else { return }
        chosen(panel.urls.map(\.path))
    }
}

/// The newest bubble is one the person sent.
private func endsWithOwnMessage(_ content: AppNode) -> Bool {
    let last = (content.children ?? []).last { $0.type == "messageBubble" }
    return last?.bool("outgoing") == true
}

/// The notice's reply capsule, holding the app's field and send button. It
/// brightens while the field inside has the keyboard.
private struct ChatComposer<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content
    @State private var focused = false

    var body: some View {
        HStack(spacing: spacing) { content() }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .frame(minHeight: 32)
            .background(.white.opacity(focused ? 0.12 : 0.08), in: Capsule())
            .onPreferenceChange(FieldFocusKey.self) { focused = $0 }
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

// MARK: - A message

/// One message. Incoming ones are glass-grey on the left, outgoing ones in
/// the chat's tint on the right; consecutive messages from the same person
/// (`groupPosition`: single, first, middle, last) join at tight corners, like
/// a notice's bubble joins its avatar. Under the pointer it offers quick
/// reactions and Reply beside it; right-click has them all, and Copy.
/// `blurred` hides it until pointed at; `dimmed` is a deleted or faded one;
/// `pending` is still sending.
private struct MessageBubble: View {
    let node: AppNode
    let tint: Color
    let react: (String) -> Void
    let reply: () -> Void
    @State private var hovering = false
    /// A quick reaction was picked: the row steps away (one send per pick)
    /// until the pointer comes back.
    @State private var reacted = false

    private var text: String { node.string("text") ?? "" }
    private var outgoing: Bool { node.bool("outgoing") == true }
    private var blurred: Bool { node.bool("blurred") == true && !hovering }
    private var dimmed: Bool { node.bool("dimmed") == true }
    private var reactable: Bool { node.bool("reactionEnabled") == true }
    private var group: String { node.string("groupPosition") ?? "single" }
    private var reactions: [String] { node.strings("reactions") ?? [] }
    private var sticker: Bool { node.bool("sticker") == true }
    /// The app's quick reactions (the person can choose them there), else these.
    private var quick: [String] { node.strings("quickReactions").map { Array($0.prefix(6)) } ?? Self.quick }
    private var all: [String] {
        var seen = Set<String>()
        return (quick + Self.more).filter { seen.insert($0).inserted }
    }

    static let quick = ["❤️", "👍", "😂"]
    static let more = ["❤️", "👍", "😂", "😮", "😢", "🙏", "🔥", "🎉"]

    /// Round where it's free, tight where it joins the one above or below.
    private var shape: UnevenRoundedRectangle {
        let joinsAbove = group == "middle" || group == "last"
        let joinsBelow = group == "middle" || group == "first"
        let round: CGFloat = 14, tight: CGFloat = 4
        return UnevenRoundedRectangle(
            topLeadingRadius: !outgoing && joinsAbove ? tight : round,
            bottomLeadingRadius: !outgoing && joinsBelow ? tight : round,
            bottomTrailingRadius: outgoing && joinsBelow ? tight : round,
            topTrailingRadius: outgoing && joinsAbove ? tight : round,
            style: .continuous)
    }

    var body: some View {
        HStack(spacing: 0) {
            if outgoing { Spacer(minLength: 56) }
            VStack(alignment: outgoing ? .trailing : .leading, spacing: 2) {
                if !outgoing, let sender = node.string("sender"), !sender.isEmpty,
                   group == "single" || group == "first" {
                    Text(sender)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tint.opacity(0.9))
                        .padding(.horizontal, 6)
                }
                bubble
                    .overlay(alignment: outgoing ? .bottomTrailing : .bottomLeading) { reactionChips }
                    .overlay(alignment: outgoing ? .leading : .trailing) { quickActions }
                    .padding(.bottom, reactions.isEmpty ? 0 : 10)
                meta
            }
            .frame(maxWidth: node.number("maxWidth").map { CGFloat($0) } ?? 330,
                   alignment: outgoing ? .trailing : .leading)
            if !outgoing { Spacer(minLength: 56) }
        }
        .padding(.top, group == "single" || group == "first" ? 4 : 0)
        .contentShape(Rectangle())
        .onHover { h in
            withAnimation(.easeOut(duration: 0.15)) {
                hovering = h
                if !h { reacted = false }
            }
        }
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityHint(node.bool("blurred") == true ? "Point at it to read" : "")
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 5) {
            quote
            picture
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(dimmed ? 0.4 : 0.95))
                    .italic(dimmed)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .blur(radius: blurred ? 6 : 0)
        .padding(.horizontal, sticker ? 0 : 10)
        .padding(.vertical, sticker ? 0 : 7)
        // A sticker stands on its own, small, with no bubble behind it.
        .background(sticker ? AnyShapeStyle(.clear)
                            : outgoing ? AnyShapeStyle(tint.opacity(dimmed ? 0.2 : 0.75))
                                       : AnyShapeStyle(.white.opacity(hovering ? 0.13 : 0.09)),
                    in: shape)
    }

    /// The message it replies to (`quoteSender`, `quoteText`, `quoteTint`):
    /// a bar in their color, their name, and their words, cut short.
    @ViewBuilder private var quote: some View {
        if let words = node.string("quoteText") {
            let tint = node.color("quoteTint") ?? .white
            HStack(spacing: 7) {
                Capsule().fill(outgoing ? Color.white.opacity(0.85) : tint).frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    if let sender = node.string("quoteSender") {
                        Text(sender)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(outgoing ? Color.white : tint)
                    }
                    Text(words)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 5)
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .background((outgoing ? Color.black.opacity(0.18) : Color.white.opacity(0.07)),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .frame(minWidth: 120, alignment: .leading)
            .blur(radius: blurred ? 5 : 0)
        }
    }

    @ViewBuilder private var picture: some View {
        let maxWidth = sticker ? 110 : (node.number("maxWidth").map { CGFloat($0) } ?? 330) - 20
        let maxHeight = sticker ? 110 : node.number("imageMaxHeight").map { CGFloat($0) } ?? 180
        if let b64 = node.string("imageData"), let data = Data(base64Encoded: b64), let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else if (node.string("mediaType") ?? "").lowercased().contains("image") {
            // A photo that hasn't come down yet.
            VStack(spacing: 5) {
                Image(systemName: "photo").font(.system(size: 18, weight: .light))
                Text("Photo").font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.5))
            .frame(width: min(maxWidth, 180), height: 90)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    /// Reactions sit on the bubble's lower edge.
    @ViewBuilder private var reactionChips: some View {
        if !reactions.isEmpty {
            HStack(spacing: 2) {
                ForEach(reactions, id: \.self) { Text($0).font(.system(size: 10)) }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .glassEffect(.regular, in: Capsule())
            .blur(radius: blurred ? 4 : 0)
            .offset(x: outgoing ? -8 : 8, y: 12)
            .transition(.scale(scale: 0.5).combined(with: .opacity))
        }
    }

    /// Beside the bubble under the pointer: quick reactions and Reply.
    @ViewBuilder private var quickActions: some View {
        if hovering && reactable && !reacted {
            HStack(spacing: 4) {
                ReactionPicker(emojis: quick, size: 22) { emoji in
                    react(emoji)
                    withAnimation(.easeOut(duration: 0.2)) { reacted = true }
                }
                ChatIconButton(symbol: "arrowshape.turn.up.left.fill", tint: .white, filled: false, active: false,
                               disabled: false, label: "Reply", size: 22, action: reply)
            }
            .fixedSize()
            .padding(outgoing ? .trailing : .leading, 6)
            // Just outside the bubble, on its free side: pinned to the
            // bubble's edge by a zero-width frame, spilling away from it.
            .frame(width: 0, alignment: outgoing ? .trailing : .leading)
            .transition(.scale(scale: 0.85, anchor: outgoing ? .trailing : .leading).combined(with: .opacity))
        }
    }

    @ViewBuilder private var meta: some View {
        let time = node.string("time") ?? ""
        let pending = node.bool("pending") == true
        let status = outgoing ? node.string("status") : nil
        if !time.isEmpty || pending || status != nil {
            HStack(spacing: 3) {
                if pending { Image(systemName: "clock").font(.system(size: 7.5, weight: .semibold)) }
                if !time.isEmpty { Text(time).monospacedDigit() }
                if !pending, let status { Ticks(status: status) }
            }
            .font(.system(size: 8.5, weight: .medium))
            .foregroundStyle(.white.opacity(hovering || pending ? 0.45 : 0.28))
            .padding(.horizontal, 6)
        }
    }

    @ViewBuilder private var menu: some View {
        if reactable {
            Button("Reply", systemImage: "arrowshape.turn.up.left", action: reply)
            Divider()
        }
        if !text.isEmpty {
            Button("Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
        if reactable {
            Divider()
            ForEach(all, id: \.self) { emoji in Button(emoji) { react(emoji) } }
            if !reactions.isEmpty {
                Divider()
                Button("Remove Reaction") { react("") }
            }
        }
    }
}

/// How far a sent message got: one grey tick (sent), two grey (delivered),
/// two blue (read).
private struct Ticks: View {
    let status: String

    var body: some View {
        let double = status == "delivered" || status == "read"
        HStack(spacing: -5) {
            Image(systemName: "checkmark")
            if double { Image(systemName: "checkmark") }
        }
        .font(.system(size: 8, weight: .bold))
        .foregroundStyle(status == "read" ? Color(red: 0.33, green: 0.72, blue: 1) : .white.opacity(0.4))
        .accessibilityLabel(status == "read" ? "Read" : double ? "Delivered" : "Sent")
    }
}

/// Above the composer while replying: who and what, and × to stop.
private struct ReplyPreview: View {
    let sender: String
    let text: String
    let tint: Color
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Capsule().fill(tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to \(sender)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                Text(text)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            ChatIconButton(symbol: "xmark", tint: .white, filled: false, active: false, disabled: false,
                           label: "Don't reply", size: 20, action: cancel)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - The list of chats

/// A chat in the list: the person (their initials on their color, a lock
/// when it's protected, a dot when it's watched), the last message, when,
/// and how many are unread, in their color.
private struct ChatRow: View {
    let node: AppNode
    let tap: () -> Void
    @State private var hovering = false

    private var title: String { node.string("title") ?? "" }
    private var color: Color? { node.color("indicatorColor") }
    private var unread: Int { Int(node.number("unread") ?? 0) }

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 10) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(title)
                            .font(.system(size: 12, weight: unread > 0 ? .semibold : .medium))
                            .foregroundStyle(.white.opacity(0.92))
                        if node.bool("starred") == true {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(Color(red: 0.97, green: 0.79, blue: 0.28))
                        }
                        if node.bool("pinned") == true {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 7.5))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                        Spacer(minLength: 6)
                        if let time = node.string("timestamp"), !time.isEmpty {
                            Text(time)
                                .font(.system(size: 9, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(unread > 0 ? AnyShapeStyle(color ?? .panelAccent)
                                                            : AnyShapeStyle(.white.opacity(0.35)))
                        }
                    }
                    HStack(spacing: 6) {
                        Text(node.string("subtitle") ?? "")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(unread > 0 ? 0.7 : 0.45))
                        Spacer(minLength: 4)
                        if unread > 0 {
                            Text(unread > 99 ? "99+" : "\(unread)")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .contentTransition(.numericText())
                                .padding(.horizontal, 5)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(color ?? .panelAccent, in: Capsule())
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
                .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .background(.white.opacity(hovering ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(AppPressStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .animation(.smooth(duration: 0.25), value: unread)
        .accessibilityLabel(title)
        .accessibilityValue(unread > 0 ? "\(unread) unread" : "")
    }

    /// Their profile picture (`avatarImage`, base64), when the app has it.
    private var picture: NSImage? {
        node.string("avatarImage").flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:))
    }

    private var avatar: some View {
        PersonAvatar(name: title, image: picture, initials: node.string("avatarText"), color: color, size: 32)
            .overlay {
                if node.bool("protected") == true {
                    Circle().fill(.black.opacity(0.45))
                    Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if node.bool("watched") == true {
                    Circle().fill(color ?? .panelAccent)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(.black, lineWidth: 1.5))
                }
            }
    }
}

// MARK: - Small controls

/// One color to pick (a contact's color). Without a color it's "automatic":
/// a dashed ring. The picked one wears a white ring and a check.
private struct ColorSwatch: View {
    let color: Color?
    let selected: Bool
    let label: String?
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            ZStack {
                if let color {
                    Circle().fill(color)
                } else {
                    Circle().strokeBorder(.white.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2.5]))
                    Text("A").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.6))
                }
                if selected {
                    Circle().strokeBorder(.white, lineWidth: 2).padding(-3)
                    if color != nil {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                    }
                }
            }
            .frame(width: 22, height: 22)
            .padding(3)
            .contentShape(Circle())
        }
        .buttonStyle(AppPressStyle())
        .help(label ?? "")
        .accessibilityLabel(label ?? "Color")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A round button. Filled: the one thing to do (send), in the tint.
/// Plain: glass, its glyph in the tint while `active`.
private struct ChatIconButton: View {
    let symbol: String
    let tint: Color
    let filled: Bool
    let active: Bool
    let disabled: Bool
    let label: String?
    var size: CGFloat = 26
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(filled || !active ? Color.white.opacity(filled ? 1 : 0.75) : tint)
                .frame(width: size, height: size)
                .background {
                    if filled { Circle().fill(disabled ? Color.white.opacity(0.15) : tint) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(AppPressStyle())
        .disabled(disabled)
        .help(label ?? "")
        .accessibilityLabel(label ?? symbol)
        if filled {
            button
        } else {
            button.glassEffect(active ? .regular.tint(tint.opacity(0.3)).interactive() : .regular.interactive(),
                               in: Circle())
        }
    }
}
