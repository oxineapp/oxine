import SwiftUI
import AppKit
import PanelKit

/// The Notes tab: a writer on top that grows as you type, then your notes as
/// cards: pinned ones in a row of small tiles, the rest in two columns. A
/// card opens into a full editor that fills the tab.
struct NotesView: View {
    @ObservedObject var notesManager: QuickNotesManager
    /// What's in the writer, kept across panel closes and relaunches.
    @AppStorage("notesDraft", store: UserDefaults(suiteName: "com.oxine.settings")) private var draft = ""
    @State private var searching = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var writerFocus = 0
    /// The note open in the editor.
    @State private var openID: UUID?
    @State private var pointer = HoverPointer()
    @State private var hoveredID: UUID?
    @StateObject private var ring = RingModel()
    /// "Moved to Trash · Undo" is showing; bumped per delete so only the
    /// latest one's timer hides it.
    @State private var undoShown = 0
    @Namespace private var hero

    nonisolated private static let space = "notesBoard"

    private var visible: [QuickNote] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return notesManager.notes }
        return notesManager.notes.filter { $0.content.localizedCaseInsensitiveContains(q) }
    }

    private var openNote: QuickNote? {
        openID.flatMap { id in notesManager.notes.first { $0.id == id } }
    }

    var body: some View {
        let notes = visible
        ZStack {
            VStack(spacing: 0) {
                header
                if notes.isEmpty {
                    emptyState
                } else {
                    board(notes)
                }
            }
            if let note = openNote {
                NoteEditorView(
                    note: note,
                    notesManager: notesManager,
                    onClose: closeEditor,
                    onDelete: {
                        closeEditor()
                        delete(note)
                    })
                .matchedGeometryEffect(id: note.id, in: hero)
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 4)
                .zIndex(1)
            }
        }
        .overlay(alignment: .bottom) {
            if undoShown > 0 { undoPill }
        }
        .onAppear {
            writerFocus += 1
            startRing()
            // Esc closes the ring or the open note before it closes the panel.
            AppDelegate.escapeHandler = {
                if ring.state != nil { ring.close(); return true }
                if openID != nil { closeEditor(); return true }
                return false
            }
        }
        .onDisappear {
            ring.stop()
            AppDelegate.escapeHandler = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .popoverDidShow)) { _ in
            if openID == nil && !searching { writerFocus += 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: .popoverWillClose)) { _ in ring.close() }
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        Group {
            if searching {
                searchBar
            } else {
                NoteWriter(text: $draft, focusRequest: writerFocus, onSave: save, onSearch: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { searching = true }
                    DispatchQueue.main.async { searchFocused = true }
                })
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
            TextField("", text: $query, prompt: Text("Search notes").foregroundColor(.white.opacity(0.42)))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.92))
                .focused($searchFocused)
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                    query = ""
                    searching = false
                }
                writerFocus += 1
            } label: {
                Text("Done")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color.panelAccent)
            }
            .buttonStyle(.plain)
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
        .transition(.opacity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: query.isEmpty ? "square.and.pencil" : "magnifyingglass")
                .font(.system(size: 20))
                .foregroundColor(.white.opacity(0.15))
            Text(query.isEmpty ? "No notes yet" : "No matches")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.4))
            if query.isEmpty {
                Text("Write one above. ⌘↩ saves it.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.28))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Board

    private func board(_ notes: [QuickNote]) -> some View {
        let pinned = notes.filter(\.isPinned)
        let recent = notes.filter { !$0.isPinned }
        let (left, right) = Self.columns(recent)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !pinned.isEmpty {
                    sectionTitle("Pinned")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(pinned) { note in item(note, compact: true) }
                    }
                }
                if !recent.isEmpty {
                    sectionTitle("Recent")
                    HStack(alignment: .top, spacing: 8) {
                        LazyVStack(spacing: 8) { ForEach(left) { item($0) } }
                        LazyVStack(spacing: 8) { ForEach(right) { item($0) } }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
            .animation(.spring(response: 0.36, dampingFraction: 0.86), value: notes.map(\.id))
        }
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
            case .ended:
                pointer.lastHover = nil
            }
            refreshHover(animated: true)
        }
        .overlay(alignment: .topLeading) {
            if let state = ring.state {
                ActionRing(state: state, onPick: ring.pick, onHighlight: ring.highlight,
                           onConfirm: ring.confirm, onCancelConfirm: ring.cancelConfirm)
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white.opacity(0.55))
            .padding(.leading, 2)
            .padding(.top, 12)
            .padding(.bottom, 7)
    }

    /// A card or pinned tile. While its note is open the card keeps its place
    /// but hides; the editor grows out of it and shrinks back into it.
    @ViewBuilder private func item(_ note: QuickNote, compact: Bool = false) -> some View {
        let isOpen = openID == note.id
        let face = NoteCard(
            note: note,
            compact: compact,
            isHovered: hoveredID == note.id && !isOpen && ring.state == nil,
            onOpen: { open(note) },
            onToggle: { notesManager.toggleCheck(note, line: $0) },
            onPin: { pin(note) },
            onDelete: { delete(note) })
        Group {
            if isOpen {
                face.hidden()
            } else {
                face.matchedGeometryEffect(id: note.id, in: hero)
            }
        }
        .hoverFrame(note.id, in: pointer, space: Self.space, onChange: queueHoverRefresh)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    /// Deals cards into two columns, each to the shorter one so far, by a
    /// rough height for its text.
    private static func columns(_ notes: [QuickNote]) -> ([QuickNote], [QuickNote]) {
        var left: [QuickNote] = [], right: [QuickNote] = []
        var leftHeight: CGFloat = 0, rightHeight: CGFloat = 0
        for note in notes {
            let height = estimatedHeight(note) + 8
            if leftHeight <= rightHeight {
                left.append(note); leftHeight += height
            } else {
                right.append(note); rightHeight += height
            }
        }
        return (left, right)
    }

    private static func estimatedHeight(_ note: QuickNote) -> CGFloat {
        let doc = note.document
        var height: CGFloat = 44 + (doc.title == nil ? 0 : 20)
        for block in doc.blocks.prefix(NoteCard.maxBlocks) {
            switch block {
            case .text(let s): height += 17 * CGFloat(min(4, max(1, s.count / 32 + 1)))
            default: height += 22
            }
        }
        return height
    }

    private var undoPill: some View {
        HStack(spacing: 10) {
            Text("Moved to Trash")
                .foregroundColor(.white.opacity(0.85))
            Button("Undo", action: undoDelete)
                .buttonStyle(.plain)
                .foregroundColor(Color.panelAccent)
                .fontWeight(.semibold)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .frame(height: 32)
        .glassEffect(.regular, in: Capsule())
        .padding(.bottom, 10)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: Hover

    private func queueHoverRefresh() {
        guard !pointer.refreshQueued else { return }
        pointer.refreshQueued = true
        DispatchQueue.main.async {
            pointer.refreshQueued = false
            refreshHover(animated: false)
        }
    }

    private func refreshHover(animated: Bool) {
        guard ring.state == nil else { return }
        let id = pointer.location.flatMap { pointer.row(at: $0, slop: 0) }
        guard id != hoveredID else { return }
        withAnimation(animated ? .easeOut(duration: 0.15) : .easeOut(duration: 0.08)) { hoveredID = id }
    }

    // MARK: Right-click ring

    private func startRing() {
        ring.target = {
            guard let point = pointer.location, let id = pointer.row(at: point, slop: 0) else { return nil }
            return (id, point, pointer.viewport)
        }
        ring.choices = { id in
            guard let note = notesManager.notes.first(where: { $0.id == id }) else { return [] }
            return [
                RingChoice(slot: .upLeft, icon: note.isPinned ? "pin.slash" : "pin", title: note.isPinned ? "Unpin" : "Pin"),
                RingChoice(slot: .upRight, icon: "arrow.up.forward.app", title: "Open in \(NotesEditor.displayName)"),
                RingChoice(slot: .down, icon: "trash", title: "Move to Trash", danger: true),
            ]
        }
        ring.perform = { slot, id in
            guard let note = notesManager.notes.first(where: { $0.id == id }) else { return }
            switch slot {
            case .upLeft:  pin(note)
            case .upRight: NoteOpener.open(note, notesManager: notesManager)
            case .down:    delete(note)
            }
        }
        ring.onClose = { refreshHover(animated: true) }
        ring.start()
    }

    // MARK: Actions

    private func save() {
        guard notesManager.addNote(draft) != nil else { return }
        draft = ""
    }

    private func open(_ note: QuickNote) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { openID = note.id }
    }

    private func closeEditor() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) { openID = nil }
        writerFocus += 1
    }

    private func pin(_ note: QuickNote) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { notesManager.pinNote(note) }
    }

    private func delete(_ note: QuickNote) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { notesManager.deleteNote(note) }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { undoShown += 1 }
        let shown = undoShown
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if undoShown == shown { withAnimation(.easeOut(duration: 0.2)) { undoShown = 0 } }
        }
    }

    private func undoDelete() {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
            notesManager.undoDelete()
            if !notesManager.canUndoDelete { undoShown = 0 }
        }
    }
}

// MARK: - Writer

/// The writer at the top of the tab. One line until you click it or start
/// typing; then it opens up and keeps growing with the text, up to a limit
/// where it scrolls. Return is a new line; ⌘↩ or the Save button saves.
struct NoteWriter: View {
    @Binding var text: String
    var focusRequest: Int
    var onSave: () -> Void
    var onSearch: () -> Void

    @State private var focused = false
    /// Clicked into or typed in. Being focused when the panel opens isn't
    /// enough to open it up.
    @State private var engaged = false
    @State private var textHeight: CGFloat = 34

    private static let closedHeight: CGFloat = 34
    private static let openMinimum: CGFloat = 60
    private static let maximum: CGFloat = 220

    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var isOpen: Bool { engaged || !text.isEmpty }
    private var editorHeight: CGFloat {
        isOpen ? min(max(textHeight, Self.openMinimum), Self.maximum) : Self.closedHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                MarkdownEditor(
                    text: $text,
                    placeholder: "Write a note…",
                    onHeight: { textHeight = $0 },
                    onFocus: { now in
                        focused = now
                        if !now && text.isEmpty { engaged = false }
                    },
                    onClick: { engaged = true },
                    onSubmit: save,
                    focusRequest: focusRequest)
                .frame(height: editorHeight)
                if !isOpen {
                    Button(action: onSearch) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                            .frame(width: 34, height: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Search notes")
                    .transition(.opacity)
                }
            }
            if isOpen {
                HStack {
                    Spacer()
                    saveButton
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .transition(.opacity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: isOpen ? 14 : 11, style: .continuous)
                .fill(Color.white.opacity(focused && isOpen ? 0.065 : 0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: isOpen ? 14 : 11, style: .continuous)
                        .strokeBorder(Color.white.opacity(focused && isOpen ? 0.13 : 0.08), lineWidth: 0.5)
                )
        )
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: isOpen)
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: editorHeight)
        .onChange(of: text) { _, now in
            if !now.isEmpty { engaged = true }
        }
    }

    /// Save, with its shortcut written on it so ⌘↩ gets found.
    private var saveButton: some View {
        let ink = Color.inkOnAccent
        return Button(action: save) {
            HStack(spacing: 7) {
                Text("Save")
                    .font(.system(size: 12, weight: .semibold))
                Text("⌘↩")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 5)
                    .frame(height: 17)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill((hasText ? ink : Color.white).opacity(0.14))
                    )
            }
            .foregroundColor(hasText ? ink : .white.opacity(0.4))
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(height: 27)
            .background(Capsule().fill(hasText ? Color.panelAccent : Color.white.opacity(0.07)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!hasText)
        .help("Save the note (⌘↩)")
    }

    private func save() {
        guard hasText else { return }
        onSave()
        engaged = false
    }
}

// MARK: - Cards

/// A note on the board: its title, the first few lines rendered (checklist
/// boxes tick right there), and its date. Pin and Move to Trash float in the
/// corner on hover. Click opens it. `compact` is the pinned tile.
struct NoteCard: View {
    let note: QuickNote
    var compact = false
    let isHovered: Bool
    let onOpen: () -> Void
    let onToggle: (Int) -> Void
    let onPin: () -> Void
    let onDelete: () -> Void

    static let maxBlocks = 6

    /// The corner buttons take clicks only once they've faded in, so a click
    /// meant to open the card can't land on Move to Trash.
    @State private var cornerArmed = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 13, style: .continuous) }

    var body: some View {
        Group {
            if compact { tile } else { card }
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, minHeight: compact ? 74 : nil, maxHeight: compact ? 74 : nil, alignment: .topLeading)
        .background(shape.fill(Color.white.opacity(isHovered ? 0.075 : 0.05)))
        .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        .overlay(alignment: .topTrailing) { corner }
        .contentShape(shape)
        .onTapGesture(perform: onOpen)
        .task(id: isHovered) {
            cornerArmed = false
            guard isHovered else { return }
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { cornerArmed = true }
        }
    }

    private var card: some View {
        let doc = note.document
        return VStack(alignment: .leading, spacing: 6) {
            if let title = doc.title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.94))
                    .lineLimit(2)
            }
            ForEach(Array(doc.blocks.prefix(Self.maxBlocks).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
            if doc.blocks.count > Self.maxBlocks {
                Text("\(doc.blocks.count - Self.maxBlocks) more")
                    .font(.system(size: 10.5))
                    .foregroundColor(.white.opacity(0.4))
            }
            Text(note.dateLabel)
                .font(.system(size: 10.5))
                .foregroundColor(.white.opacity(0.5))
        }
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tileTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.94))
                .lineLimit(2)
            Spacer(minLength: 4)
            Text(tileSummary)
                .font(.system(size: 10.5))
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(1)
        }
    }

    private var tileTitle: String {
        if let title = note.document.title { return title }
        switch note.document.blocks.first {
        case .text(let s), .heading(let s), .bullet(let s), .quote(let s), .code(let s): return NoteDocument.plain(s)
        case .check(_, let s, _): return NoteDocument.plain(s)
        case nil: return "Note"
        }
    }

    /// "2 of 4 done" for a checklist, "14 items" for a list, else the first line.
    private var tileSummary: String {
        let doc = note.document
        if let list = doc.checklist { return "\(list.done) of \(list.total) done" }
        let bullets = doc.blocks.filter { if case .bullet = $0 { return true } else { return false } }.count
        if bullets > 1 { return "\(bullets) items" }
        for block in doc.blocks.dropFirst(doc.title == nil ? 1 : 0) {
            if case .text(let s) = block { return NoteDocument.plain(s) }
        }
        return note.dateLabel
    }

    @ViewBuilder private func blockView(_ block: NoteDocument.Block) -> some View {
        switch block {
        case .text(let s):
            Text(NoteDocument.inline(s))
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.75))
                .lineSpacing(2)
                .lineLimit(4)
        case .heading(let s):
            Text(NoteDocument.plain(s))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
        case .bullet(let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundColor(Color.panelAccent)
                Text(NoteDocument.inline(s))
                    .foregroundColor(.white.opacity(0.78))
                    .lineLimit(2)
            }
            .font(.system(size: 12))
        case .check(let done, let s, let line):
            NoteCheckRow(done: done, text: s, onToggle: { onToggle(line) })
        case .quote(let s):
            HStack(spacing: 7) {
                Capsule().fill(Color.panelAccent.opacity(0.6)).frame(width: 2)
                Text(NoteDocument.inline(s))
                    .font(.system(size: 12))
                    .italic()
                    .foregroundColor(.white.opacity(0.62))
                    .lineLimit(3)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let s):
            Text(s)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)
        }
    }

    private var corner: some View {
        HStack(spacing: 1) {
            ClipIconButton(icon: note.isPinned ? "pin.slash" : "pin", help: note.isPinned ? "Unpin" : "Pin",
                           size: CGSize(width: 24, height: 22), action: onPin)
            ClipIconButton(icon: "trash", help: "Move to Trash", danger: true,
                           size: CGSize(width: 24, height: 22), action: onDelete)
        }
        .padding(2)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(6)
        .opacity(isHovered ? 1 : 0)
        .scaleEffect(isHovered ? 1 : 0.9, anchor: .topTrailing)
        .allowsHitTesting(isHovered && cornerArmed)
    }
}

/// A checklist item on a card. The box ticks the item in the note's file.
struct NoteCheckRow: View {
    let done: Bool
    let text: String
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onToggle) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(done ? Color.panelAccent : Color.clear)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.white.opacity(done ? 0 : 0.4), lineWidth: 1.2)
                    if done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 7.5, weight: .heavy))
                            .foregroundColor(.inkOnAccent)
                    }
                }
                .frame(width: 13, height: 13)
                .padding(.top, 1.5)
                .contentShape(Rectangle().inset(by: -4))
            }
            .buttonStyle(.plain)
            .help(done ? "Untick" : "Tick")
            Text(NoteDocument.inline(text))
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(done ? 0.45 : 0.85))
                .strikethrough(done, color: .white.opacity(0.45))
                .lineLimit(2)
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: done)
    }
}

// MARK: - Editor

/// A note open in the tab, edited in place and saved as you type. It grows
/// out of the card and shrinks back into it on close (Esc, ⌘↩ or Notes).
struct NoteEditorView: View {
    let note: QuickNote
    @ObservedObject var notesManager: QuickNotesManager
    let onClose: () -> Void
    let onDelete: () -> Void

    @State private var text: String
    /// What the file holds as far as this editor knows. Only text typed here
    /// since then gets written, so a change made in another app isn't saved
    /// over with an old copy.
    @State private var saved: String
    @State private var focus = 1
    @State private var pendingSave: DispatchWorkItem?

    init(note: QuickNote, notesManager: QuickNotesManager, onClose: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.note = note
        self.notesManager = notesManager
        self.onClose = onClose
        self.onDelete = onDelete
        _text = State(initialValue: note.content)
        _saved = State(initialValue: note.content)
    }

    private var current: QuickNote? { notesManager.notes.first { $0.id == note.id } }
    private var isPinned: Bool { current?.isPinned ?? note.isPinned }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Button(action: close) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Notes")
                            .font(.system(size: 12.5))
                    }
                    .foregroundColor(.white.opacity(0.75))
                    .padding(.horizontal, 6)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back to notes (Esc)")
                Spacer()
                ClipIconButton(icon: isPinned ? "pin.slash" : "pin", help: isPinned ? "Unpin" : "Pin") {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { notesManager.pinNote(note) }
                }
                ClipIconButton(icon: "doc.on.doc", help: "Copy") {
                    flush()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                openInButton
                ClipIconButton(icon: "trash", help: "Move to Trash", danger: true) {
                    pendingSave?.cancel()
                    onDelete()
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            MarkdownEditor(
                text: $text,
                placeholder: "Write…",
                fontSize: 13.5,
                inset: NSSize(width: 16, height: 10),
                onSubmit: close,
                focusRequest: focus)
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.3)))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onChange(of: text) { scheduleSave() }
        // Edited in another app: show it, unless something's been typed here
        // since the last save.
        .onChange(of: current?.content) { _, newer in
            guard let newer, newer != saved else { return }
            if text == saved { text = newer }
            saved = newer
        }
        .onDisappear(perform: flush)
        .onReceive(NotificationCenter.default.publisher(for: .popoverWillClose)) { _ in flush() }
    }

    private var openInButton: some View {
        Button {
            flush()
            NoteOpener.open(note, notesManager: notesManager)
        } label: {
            HStack(spacing: 5) {
                if let icon = NotesEditor.appIcon() {
                    Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                }
                Text("Open in \(NotesEditor.displayName)")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(0.07)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 2)
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        guard text != saved else { return }
        let save = DispatchWorkItem { commit() }
        pendingSave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: save)
    }

    /// Saves now. An emptied note is left as it was rather than written blank.
    private func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        commit()
    }

    private func commit() {
        guard text != saved, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        notesManager.updateNote(note.id, content: text)
        saved = text
    }

    private func close() {
        flush()
        onClose()
    }
}

/// Opens a note in the user's chosen editor (see `NotesEditor`). Obsidian gets
/// the `obsidian://` deep link so it opens inside the vault; any other app just
/// opens the `.md` file directly.
enum NoteOpener {
    static func open(_ note: QuickNote, notesManager: QuickNotesManager) {
        let fileName = note.filename.isEmpty ? note.id.uuidString : note.filename
        guard let fileURL = notesManager.noteFileURL(filename: fileName) else { return }
        // Obsidian: open by absolute path. The `path` form lets Obsidian resolve
        // which registered vault owns the file, avoiding the "Vault not found"
        // failure you get when the vault name in the URL isn't registered.
        if NotesEditor.isObsidian, obsidianInstalled,
           let encodedPath = fileURL.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: "obsidian://open?path=\(encodedPath)") {
            // Make sure the vault is registered so Obsidian can resolve the path.
            ObsidianVaultManager.shared.registerVaultInConfig()
            NSWorkspace.shared.open(url)
            return
        }
        if let appURL = NotesEditor.resolvedAppURL() {
            NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        } else {
            // No resolvable app — let macOS open it with whatever handles .md.
            NSWorkspace.shared.open(fileURL)
        }
    }

    static var obsidianInstalled: Bool {
        guard let scheme = URL(string: "obsidian://open") else { return false }
        return NSWorkspace.shared.urlForApplication(toOpen: scheme) != nil
    }
}

extension Color {
    /// Text on an accent fill: dark on a light accent, white on a dark one.
    @MainActor static var inkOnAccent: Color {
        let luminance = NSColor(Color.panelAccent).usingColorSpace(.sRGB).map {
            ClipColor.luminance($0.redComponent, $0.greenComponent, $0.blueComponent)
        } ?? 0.6
        return luminance > 0.4 ? Color(red: 0.03, green: 0.11, blue: 0.15) : .white
    }
}
