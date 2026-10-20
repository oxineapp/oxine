import SwiftUI
import AppKit
import PanelKit

/// How the history lays out, picked in Settings → Clipboard: a list of rows
/// that open in place (Stack) or two columns of tiles grouped by day (Board).
enum ClipboardLayout: Int {
    case stack, board
    static let storeKey = "clipboardLayout"
}

enum ClipFilter: String, CaseIterable, Identifiable {
    case all, links, code, secrets, pinned

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:     return "All"
        case .links:   return "Links"
        case .code:    return "Code"
        case .secrets: return "Secrets"
        case .pinned:  return "Pinned"
        }
    }

    func matches(_ item: ClipboardItem) -> Bool {
        switch self {
        case .all:     return true
        case .links:   return item.kind == .link && !item.isSecret
        case .code:    return item.kind == .code && !item.isSecret
        case .secrets: return item.isSecret
        case .pinned:  return item.isPinned
        }
    }
}

/// The clipboard's pointer state: the shared hover check plus the key
/// monitors.
@MainActor final class ClipPointer: HoverPointer {
    var optionHold: DispatchWorkItem?
    var monitors: [Any] = []

    func stopMonitoring() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        optionHold?.cancel()
    }
}

struct ClipboardHistoryView: View {
    @Binding var items: [ClipboardItem]
    @ObservedObject var clipboardManager: ClipboardManager
    @ObservedObject var notesManager: QuickNotesManager
    var onSwitchToNotes: (() -> Void)? = nil

    @AppStorage(ClipboardLayout.storeKey, store: UserDefaults(suiteName: "com.oxine.settings"))
    private var layoutRaw = ClipboardLayout.stack.rawValue
    @State private var searchText = ""
    @State private var filter: ClipFilter = .all
    @FocusState private var searchFocused: Bool
    @Namespace private var chipSelection

    @State private var pointer = ClipPointer()
    /// The row under the pointer, or the one picked with the arrow keys.
    @State private var hoveredID: UUID?
    @Namespace private var hoverPlate
    /// "Deleted · Undo" is showing; bumped per delete so only the latest
    /// one's timer hides it.
    @State private var undoShown = 0
    /// The selection came from the arrow keys. The pointer takes over again
    /// once it moves.
    @State private var keyboardDriven = false
    @State private var scrollTarget: UUID?
    @State private var expandedID: UUID?
    @State private var copiedID: UUID?
    @State private var revealed: Set<UUID> = []
    /// ⌥ held on its own: every secret shows.
    @State private var showAllSecrets = false
    @StateObject private var ring = RingModel()

    nonisolated private static let space = "clipList"

    private var layout: ClipboardLayout { ClipboardLayout(rawValue: layoutRaw) ?? .stack }

    /// Pinned first, then newest first, narrowed by the chip and the search.
    private var visibleItems: [ClipboardItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let matching = items.filter { item in
            filter.matches(item) && (query.isEmpty
                || item.content.localizedCaseInsensitiveContains(query)
                || (item.sourceApp?.localizedCaseInsensitiveContains(query) ?? false))
        }
        return matching.filter(\.isPinned) + matching.filter { !$0.isPinned }
    }

    private var selectedItem: ClipboardItem? {
        hoveredID.flatMap { id in items.first { $0.id == id } }
    }

    var body: some View {
        let visible = visibleItems
        VStack(spacing: 0) {
            searchField
            chips
            if visible.isEmpty {
                emptyState
            } else {
                list(visible)
            }
        }
        .onAppear {
            startMonitoring()
            DispatchQueue.main.async { searchFocused = true }
        }
        .onDisappear {
            pointer.stopMonitoring()
            ring.stop()
            revealed = []
        }
        .onReceive(NotificationCenter.default.publisher(for: .popoverDidShow)) { _ in
            searchFocused = true
        }
        // Shown secrets veil again, and the next open starts clean.
        .onReceive(NotificationCenter.default.publisher(for: .popoverWillClose)) { _ in
            revealed = []
            ring.close()
            expandedID = nil
            searchText = ""
            showAllSecrets = false
            undoShown = 0
        }
        .onChange(of: searchText) { keyboardDriven = false; ring.close() }
        .onChange(of: filter) { keyboardDriven = false; ring.close() }
    }

    // MARK: Header

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
            TextField("", text: $searchText, prompt: Text("Type to search").foregroundColor(.white.opacity(0.42)))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.92))
                .focused($searchFocused)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private var chips: some View {
        HStack(spacing: 6) {
            ForEach(ClipFilter.allCases) { chip in
                let on = filter == chip
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { filter = chip }
                } label: {
                    Text(chip.label)
                        .font(.system(size: 12))
                        .foregroundColor(on ? Color.panelAccent : .white.opacity(0.66))
                        .padding(.horizontal, 11)
                        .frame(height: 26)
                        .background {
                            if on {
                                Capsule()
                                    .fill(Color.panelAccent.opacity(0.16))
                                    .matchedGeometryEffect(id: "chip", in: chipSelection)
                            } else {
                                Capsule().fill(Color.white.opacity(0.045))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: items.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass")
                .font(.system(size: 20))
                .foregroundColor(.white.opacity(0.15))
            Text(items.isEmpty ? "Nothing copied yet" : "No matches")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.35))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: List

    private func list(_ visible: [ClipboardItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                switch layout {
                case .stack: stack(visible)
                case .board: board(visible)
                }
            }
            // Rows report frames in the visible area, so they move as it scrolls.
            .coordinateSpace(.named(Self.space))
            .background(PointerProbe(pointer: pointer))
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, _ in
                ring.close()
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    guard location != pointer.lastHover else { return }
                    pointer.lastHover = location
                    keyboardDriven = false
                case .ended:
                    pointer.lastHover = nil
                }
                refreshHover(animated: true)
            }
            .overlay(alignment: .bottom) {
                if undoShown > 0 { undoPill }
            }
            .overlay(alignment: .topLeading) {
                if let state = ring.state {
                    ActionRing(state: state, onPick: ring.pick, onHighlight: ring.highlight,
                           onConfirm: ring.confirm, onCancelConfirm: ring.cancelConfirm)
                        .transition(.opacity.combined(with: .scale(scale: 0.7)))
                }
            }
            .onChange(of: scrollTarget) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id) }
                scrollTarget = nil
            }
        }
    }

    private func stack(_ visible: [ClipboardItem]) -> some View {
        LazyVStack(spacing: 2) {
            ForEach(visible) { item in
                ClipStackRow(
                    item: item,
                    plate: hoverPlate,
                    isHovered: hoveredID == item.id,
                    isExpanded: expandedID == item.id,
                    isCopied: copiedID == item.id,
                    isShown: showAllSecrets || revealed.contains(item.id),
                    onCopy: { copy(item) },
                    onToggleExpand: { toggleExpanded(item) },
                    onToggleReveal: { toggleReveal(item) },
                    onPin: { pin(item) },
                    onDelete: { delete(item) })
                .id(item.id)
                .hoverFrame(item.id, in: pointer, space: Self.space, onChange: queueHoverRefresh)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: visible.map(\.id))
    }

    private func board(_ visible: [ClipboardItem]) -> some View {
        ClipBoardGrid(
            items: visible,
            hoveredID: hoveredID,
            copiedID: copiedID,
            isShown: { showAllSecrets || revealed.contains($0.id) },
            space: Self.space,
            pointer: pointer,
            onFrameChange: queueHoverRefresh,
            onCopy: copy,
            onToggleReveal: toggleReveal,
            onPin: pin,
            onDelete: delete)
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: visible.map(\.id))
    }

    private var undoPill: some View {
        HStack(spacing: 10) {
            Text("Deleted")
                .foregroundColor(.white.opacity(0.85))
            Button("Undo", action: undoDelete)
                .buttonStyle(.plain)
                .foregroundColor(Color.panelAccent)
                .fontWeight(.semibold)
            Text("⌘Z")
                .foregroundColor(.white.opacity(0.4))
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .frame(height: 32)
        .glassEffect(.regular, in: Capsule())
        .padding(.bottom, 10)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: Hover

    /// Rows report their frames as they lay out and as the list scrolls. One
    /// hover check per pass covers all of them.
    private func queueHoverRefresh() {
        guard !pointer.refreshQueued else { return }
        pointer.refreshQueued = true
        DispatchQueue.main.async {
            pointer.refreshQueued = false
            refreshHover(animated: false)
        }
    }

    private func refreshHover(animated: Bool) {
        guard !keyboardDriven, ring.state == nil else { return }
        setHovered(pointer.location.flatMap { pointer.row(at: $0) }, animated: animated)
    }

    /// Pointer moves glide the highlight to the new row; rows scrolling
    /// under a still pointer hand it over quickly so it keeps up.
    private func setHovered(_ id: UUID?, animated: Bool = true) {
        guard id != hoveredID else { return }
        withAnimation(animated ? .spring(response: 0.26, dampingFraction: 0.9) : .easeOut(duration: 0.08)) {
            hoveredID = id
        }
    }

    // MARK: Actions

    private func copy(_ item: ClipboardItem) {
        clipboardManager.copyToClipboard(item)
        withAnimation(.easeOut(duration: 0.15)) { copiedID = item.id }
        let id = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            if copiedID == id { withAnimation(.easeOut(duration: 0.25)) { copiedID = nil } }
        }
    }

    private func toggleExpanded(_ item: ClipboardItem) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            expandedID = expandedID == item.id ? nil : item.id
        }
    }

    private func toggleReveal(_ item: ClipboardItem) {
        if revealed.contains(item.id) { revealed.remove(item.id) } else { revealed.insert(item.id) }
    }

    private func pin(_ item: ClipboardItem) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { clipboardManager.pinItem(item) }
    }

    private func delete(_ item: ClipboardItem) {
        if expandedID == item.id { expandedID = nil }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { clipboardManager.deleteItem(item) }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { undoShown += 1 }
        let shown = undoShown
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if undoShown == shown { withAnimation(.easeOut(duration: 0.2)) { undoShown = 0 } }
        }
    }

    private func undoDelete() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            clipboardManager.undoDelete()
            if !clipboardManager.canUndoDelete { undoShown = 0 }
        }
    }

    // MARK: Right-click ring

    private func ringChoices(for id: UUID) -> [RingChoice] {
        guard let item = items.first(where: { $0.id == id }) else { return [] }
        return [
            RingChoice(slot: .upLeft, icon: item.isPinned ? "pin.slash" : "pin", title: item.isPinned ? "Unpin" : "Pin"),
            RingChoice(slot: .upRight, icon: item.isSecret ? "eye" : "eye.slash",
                       title: item.isSecret ? "Not a secret" : "Mark as secret"),
            RingChoice(slot: .down, icon: "trash", title: "Delete", danger: true),
        ]
    }

    private func perform(_ slot: RingSlot, on id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        switch slot {
        case .upLeft:  pin(item)
        case .upRight: clipboardManager.setSecret(item, !item.isSecret)
        case .down:    delete(item)
        }
    }

    // MARK: Keys and mouse

    private func startMonitoring() {
        pointer.stopMonitoring()
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { handleKey($0) }
        let flags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { handleFlags($0) }
        pointer.monitors = [keys, flags].compactMap { $0 }

        ring.target = {
            guard let point = pointer.location, let id = pointer.row(at: point) else { return nil }
            return (id, point, pointer.viewport)
        }
        ring.choices = ringChoices
        ring.perform = perform
        ring.onOpen = { setHovered($0) }
        ring.onClose = { refreshHover(animated: true) }
        ring.start()
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard PanelVisibility.shared.isOpen, event.window?.isKeyWindow == true else { return event }
        // ⌥ typing a character (⌥2, ⌥Q) isn't the show-all hold.
        pointer.optionHold?.cancel()
        if ring.state != nil {
            if event.keyCode == 53 { ring.close(); return nil }
            return event
        }
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 125:                       // ↓
            moveSelection(1)
            return nil
        case 126:                       // ↑
            moveSelection(-1)
            return nil
        case 36, 76:                    // ↩ copies, ⌘↩ pastes into the app before
            guard let item = selectedItem ?? visibleItems.first else { return event }
            if command { clipboardManager.paste(item) } else { copy(item) }
            return nil
        case 51 where command:          // ⌘⌫, only on a row picked with the arrows
            guard keyboardDriven, let item = selectedItem else { return event }
            let list = visibleItems
            let next = list.firstIndex { $0.id == item.id }.flatMap { i in
                list.indices.contains(i + 1) ? list[i + 1] : (i > 0 ? list[i - 1] : nil)
            }
            delete(item)
            setHovered(next?.id)
            return nil
        default:
            break
        }
        guard command, let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
        // ⌘Z brings back a delete while its Undo is up; otherwise it's the
        // search field's.
        if key == "z", undoShown > 0, !event.modifierFlags.contains(.shift) {
            undoDelete()
            return nil
        }
        if key == "p", let item = selectedItem {
            pin(item)
            return nil
        }
        if let n = Int(key), (1...9).contains(n) {
            let list = visibleItems
            guard n <= list.count else { return event }
            copy(list[n - 1])
            return nil
        }
        return event
    }

    /// Holding ⌥ on its own for a moment shows every secret until it's let go.
    private func handleFlags(_ event: NSEvent) -> NSEvent? {
        guard PanelVisibility.shared.isOpen else { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        pointer.optionHold?.cancel()
        if flags == .option {
            let hold = DispatchWorkItem { showAllSecrets = true }
            pointer.optionHold = hold
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: hold)
        } else if showAllSecrets {
            showAllSecrets = false
        }
        return event
    }

    private func moveSelection(_ step: Int) {
        let list = visibleItems
        guard !list.isEmpty else { return }
        let current = hoveredID.flatMap { id in list.firstIndex { $0.id == id } }
        let next = current.map { min(max($0 + step, 0), list.count - 1) } ?? (step > 0 ? 0 : list.count - 1)
        keyboardDriven = true
        setHovered(list[next].id)
        scrollTarget = list[next].id
    }
}

// MARK: - Stack row

/// One history row: a type tile, the first line and where it came from, and
/// on the right the age. Hovering swaps the age for Pin and Delete, which
/// push the open chevron left. Click copies; the chevron opens the row.
struct ClipStackRow: View {
    let item: ClipboardItem
    /// The hover highlight is one shape shared by all rows, so it slides from
    /// row to row instead of fading out and in.
    let plate: Namespace.ID
    let isHovered: Bool
    let isExpanded: Bool
    let isCopied: Bool
    /// The secret's veil is off (its eye was clicked, or ⌥ is held).
    let isShown: Bool
    let onCopy: () -> Void
    let onToggleExpand: () -> Void
    let onToggleReveal: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void

    @State private var titleWidth: CGFloat = 0
    @State private var roomWidth: CGFloat = .infinity
    @GestureState private var peeking = false
    /// A press-and-hold peek just ended, so its mouse-up doesn't also copy.
    @State private var didPeek = false
    /// Pin and Delete take clicks only once they've finished sliding in, so a
    /// click meant for the row can't land on Delete as it appears.
    @State private var actionsArmed = false

    private static let ageSlot: CGFloat = 34
    private static let actionSlot: CGFloat = 58

    private var widened: Bool { isHovered || isCopied }
    private var shown: Bool { isShown || peeking }

    /// Worth opening: more lines, a cut-off title, or a link's hidden query.
    private var opens: Bool {
        item.lineCount > 1 || titleWidth > roomWidth + 0.5 || (item.linkParts?.hasMore ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if isExpanded {
                opened.transition(.opacity)
            }
        }
        .background {
            ZStack {
                if isHovered {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .matchedGeometryEffect(id: "hoverPlate", in: plate)
                }
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isCopied ? Color.panelAccent.opacity(0.10)
                          : isExpanded && !isHovered ? Color.white.opacity(0.055) : Color.clear)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !didPeek { onCopy() }
        }
        .simultaneousGesture(peek, including: item.isSecret ? .all : .subviews)
        .onChange(of: peeking) { _, now in
            if !now { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { didPeek = false } }
        }
        .onDrag { NSItemProvider(object: item.content as NSString) }
        .task(id: isHovered) {
            actionsArmed = false
            guard isHovered else { return }
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { actionsArmed = true }
        }
    }

    /// Press and hold a secret to see it while held.
    private var peek: some Gesture {
        LongPressGesture(minimumDuration: 0.3, maximumDistance: 6)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($peeking) { value, state, _ in
                if case .second(true, _) = value { state = true }
            }
            .onChanged { value in
                if case .second(true, _) = value, !didPeek { didPeek = true }
            }
    }

    private var row: some View {
        HStack(spacing: 10) {
            tile
            VStack(alignment: .leading, spacing: 2) {
                title
                Text(item.subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.52))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if opens { chevron }
            trailing
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(height: 46)
    }

    @ViewBuilder private var tile: some View {
        Group {
            if item.isSecret {
                Button(action: onToggleReveal) {
                    Image(systemName: shown ? "eye" : "eye.slash")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.75))
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(isShown ? 0.11 : 0.06))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isShown ? "Hide" : "Show")
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                    if let swatch = item.clipColor {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(swatch.color)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.3), lineWidth: 0.5)
                            )
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: item.kind.icon)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
                .frame(width: 28, height: 28)
            }
        }
        .overlay(alignment: .topTrailing) {
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(Color.panelAccent)
                    .frame(width: 13, height: 13)
                    .background(Circle().fill(Color.black.opacity(0.55)))
                    .offset(x: 4, y: -4)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    private var titleText: Text {
        if let link = item.linkParts {
            return Text("\(Text(link.host).foregroundColor(.white.opacity(0.92)))\(Text(link.path).foregroundColor(.white.opacity(0.5)))")
                .font(.system(size: 13))
        }
        return Text(item.firstLine)
            .font(item.kind == .code ? .system(size: 12, design: .monospaced) : .system(size: 13))
            .foregroundColor(.white.opacity(0.92))
    }

    private var title: some View {
        Group {
            if item.isSecret {
                Spoiler(isHidden: !shown, origin: .leading) {
                    titleText.lineLimit(1)
                }
            } else {
                titleText.lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The room the title has with the age showing, against what it needs
        // on one line: wider means the chevron shows.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            roomWidth = width + (widened ? Self.actionSlot - Self.ageSlot : 0)
        }
        .background(alignment: .leading) {
            titleText
                .fixedSize()
                .hidden()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { titleWidth = $0 }
        }
    }

    private var chevron: some View {
        ClipIconButton(icon: "chevron.down", help: isExpanded ? "Show less" : "Show all of it",
                       size: CGSize(width: 24, height: 24), action: onToggleExpand)
            .rotationEffect(.degrees(isExpanded ? 180 : 0))
    }

    /// The age, or Pin and Delete while hovered, or Copied. The slot widens
    /// for the buttons, which slides the chevron left.
    private var trailing: some View {
        let actions = isHovered && !isCopied
        return ZStack(alignment: .trailing) {
            Text(item.age)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
                .opacity(widened ? 0 : 1)
            HStack(spacing: 2) {
                ClipIconButton(icon: item.isPinned ? "pin.slash" : "pin", help: item.isPinned ? "Unpin" : "Pin", action: onPin)
                ClipIconButton(icon: "trash", help: "Delete", danger: true, action: onDelete)
            }
            .opacity(actions ? 1 : 0)
            .scaleEffect(actions ? 1 : 0.8, anchor: .trailing)
            .allowsHitTesting(actions && actionsArmed)
            if isCopied {
                Text("Copied")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.panelAccent)
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Capsule().fill(Color.panelAccent.opacity(0.16)))
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .trailing)))
            }
        }
        .frame(width: widened ? Self.actionSlot : Self.ageSlot, alignment: .trailing)
    }

    /// The whole thing, under the row. Very long copies stop after 60 lines.
    private var opened: some View {
        let lines = item.content.split(separator: "\n", omittingEmptySubsequences: false)
        let shownText = lines.count > 60 ? lines.prefix(60).joined(separator: "\n") : String(item.content.prefix(8000))
        let more = max(lines.count - 60, 0)
        return VStack(alignment: .leading, spacing: 6) {
            if item.isSecret {
                Spoiler(isHidden: !shown, origin: .leading) {
                    Text(shownText)
                        .font(.system(size: 11.5, design: .monospaced))
                        .lineSpacing(3)
                        .foregroundColor(.white.opacity(0.88))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                }
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.25)))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else if item.kind == .link {
                Text(item.content)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineSpacing(3)
                    .foregroundColor(.white.opacity(0.75))
            } else if item.kind == .code {
                Text(shownText)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineSpacing(3)
                    .foregroundColor(.white.opacity(0.88))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.3)))
            } else {
                Text(shownText)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .foregroundColor(.white.opacity(0.86))
            }
            if more > 0 {
                Text("\(more) more lines")
                    .font(.system(size: 10.5))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 44)
        .padding(.trailing, 10)
        .padding(.bottom, 12)
    }
}

/// A small icon button for row and tile actions.
struct ClipIconButton: View {
    let icon: String
    let help: String
    var danger = false
    var size = CGSize(width: 26, height: 24)
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(hovering && danger ? Color(red: 1, green: 0.54, blue: 0.48)
                                 : .white.opacity(hovering ? 0.92 : 0.62))
                .frame(width: size.width, height: size.height)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(hovering ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}
