import SwiftUI

struct NotesView: View {
    @ObservedObject var notesManager: QuickNotesManager
    @StateObject var justTypeSync = JustTypeSyncManager()
    @State var noteText = ""
    @FocusState var isFocused: Bool

    var sortedNotes: [QuickNote] {
        notesManager.notes.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.timestamp > b.timestamp
        }
    }

    // Notes tracked by justtype live in the justtype section, not the normal list.
    var visibleNotes: [QuickNote] {
        let tracked = justTypeSync.trackedLocalNoteIds
        return sortedNotes.filter { !tracked.contains($0.id.uuidString) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                writingCard
                savedNotesList
                JustTypeNotesSection(sync: justTypeSync, notesManager: notesManager)
            }
            .padding(10)
        }
        .onAppear { justTypeSync.bind(notesManager: notesManager) }
        .onReceive(NotificationCenter.default.publisher(for: .popoverDidShow)) { _ in
            isFocused = true
        }
    }

    var writingCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("", text: $noteText, prompt: Text("Write a note\u{2026}").foregroundColor(.white.opacity(0.3)))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.9))
                .focused($isFocused)
                .onAppear { DispatchQueue.main.async { isFocused = true } }
                .frame(minHeight: 30)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.07))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                        )
                )
                .onSubmit {
                    guard !noteText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    notesManager.addNote(noteText)
                    noteText = ""
                    isFocused = true
                }

            HStack(spacing: 6) {
                Button(action: {
                    guard !noteText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    notesManager.addNote(noteText)
                    noteText = ""
                    isFocused = true
                }) {
                    Text("Save")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(noteText.isEmpty ? 0.25 : 0.7))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(noteText.isEmpty ? 0 : 0.06))
                        )
                }
                .buttonStyle(.plain)
                .disabled(noteText.trimmingCharacters(in: .whitespaces).isEmpty)

                Spacer()
            }
            .frame(height: 20)
        }
        .padding(8)
    }

    var savedNotesList: some View {
        VStack(spacing: 4) {
            if visibleNotes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.12))
                    Text("No notes yet")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.25))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ForEach(visibleNotes) { note in
                    NoteItemRow(note: note, onDelete: {
                        notesManager.deleteNote(note)
                    }, onPin: {
                        notesManager.pinNote(note)
                    }, onOpenInObsidian: {
                        NoteOpener.open(note, notesManager: notesManager)
                    })
                    .contextMenu {
                        Button("Open") { NoteOpener.open(note, notesManager: notesManager) }
                        if justTypeSync.isConfigured {
                            Button("Add to justtype") {
                                Task { await justTypeSync.addToJustType(note: note) }
                            }
                        }
                        Divider()
                        Button("Delete", role: .destructive) { notesManager.deleteNote(note) }
                    }
                }
            }
        }
    }
}

struct JustTypeNotesSection: View {
    @ObservedObject var sync: JustTypeSyncManager
    @ObservedObject var notesManager: QuickNotesManager
    @State private var showConnect = false
    @State private var clientId = ""
    @State private var privateKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "cloud")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.35))
                Text("justtype")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.45))
                Spacer()
                if sync.isSyncing {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 14, height: 14)
                }
                Button(sync.isConfigured ? "Sync" : "Connect") {
                    if sync.isConfigured {
                        Task { await sync.syncNow() }
                    } else {
                        showConnect = true
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color(red: 0.4, green: 0.85, blue: 1.0).opacity(0.9))
                .disabled(sync.isSyncing)
            }

            if !sync.status.isEmpty {
                Text(sync.status)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.28))
                    .lineLimit(2)
            }

            if sync.isConfigured {
                if sync.items.isEmpty {
                    Text("Right-click a note \u{2192} \u{201C}Add to justtype\u{201D}, or Sync to pull notes you\u{2019}ve shared with this app.")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.22))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 4) {
                        ForEach(sync.items) { item in
                            JustTypeItemRow(item: item, sync: sync)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.035))
        )
        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 10))
        .sheet(isPresented: $showConnect) {
            JustTypeConnectView(sync: sync, isPresented: $showConnect, clientId: $clientId, privateKey: $privateKey)
        }
        .onAppear { sync.bind(notesManager: notesManager) }
        .task {
            sync.bind(notesManager: notesManager)
            if sync.isConfigured { await sync.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .notesDidChange)) { _ in
            // A local edit landed; push tracked notes (don't re-pull the whole list).
            guard sync.isConfigured, !sync.isSyncing else { return }
            Task { await sync.pushEdits() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .popoverDidShow)) { _ in
            // Auto-sync with justtype every time the panel opens (pull list + remote edits, push local).
            guard sync.isConfigured, !sync.isSyncing else { return }
            Task { await sync.syncNow() }
        }
    }
}

/// A single row in the justtype subsection. Tap to open (fetch + decrypt on first open);
/// right-click for Open / Unsync.
struct JustTypeItemRow: View {
    let item: JustTypeTrackedSlate
    @ObservedObject var sync: JustTypeSyncManager
    @State private var isHovered = false

    private var icon: String {
        item.origin == .pushed ? "arrow.up.circle" : "tray.and.arrow.down"
    }

    private var badge: String {
        if item.origin == .shared && item.localNoteId == nil { return "Tap to open" }
        return "Synced"
    }

    var body: some View {
        Button {
            Task { await sync.open(item) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.4))
                Text(item.title.isEmpty ? "Untitled" : item.title)
                    .lineLimit(1)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
                Text(badge)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.white.opacity(0.3))
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(isHovered ? 0.08 : 0.03))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Open")
        .contextMenu {
            Button("Open") { Task { await sync.open(item) } }
            if item.origin == .pushed {
                Button("Unsync from justtype", role: .destructive) {
                    Task { await sync.unsync(item) }
                }
            }
        }
    }
}

/// Opens a note in Obsidian when it's installed, otherwise falls back to TextEdit on the .md file.
enum NoteOpener {
    static func open(_ note: QuickNote, notesManager: QuickNotesManager) {
        let vaultName = "MenuBar Notes"
        let fileName = note.filename.isEmpty ? note.id.uuidString : note.filename
        if obsidianInstalled,
           let encodedVault = vaultName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let encodedFile = fileName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: "obsidian://open?vault=\(encodedVault)&file=\(encodedFile)") {
            NSWorkspace.shared.open(url)
            return
        }
        guard let fileURL = notesManager.noteFileURL(filename: note.filename) else { return }
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        if FileManager.default.fileExists(atPath: textEdit.path) {
            NSWorkspace.shared.open([fileURL], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(fileURL)
        }
    }

    static var obsidianInstalled: Bool {
        guard let scheme = URL(string: "obsidian://open") else { return false }
        return NSWorkspace.shared.urlForApplication(toOpen: scheme) != nil
    }
}

struct JustTypeConnectView: View {
    @ObservedObject var sync: JustTypeSyncManager
    @Binding var isPresented: Bool
    @Binding var clientId: String
    @Binding var privateKey: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect justtype")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)

            Text(sync.isAppConfigured ? "Sign in with justtype. On the consent screen, allow full private slate access so this app can read and edit your slates." : "Developer setup is required once before users can sign in. Use the client ID and app private key from the justtype dev portal.")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)

            if !sync.isAppConfigured {
                TextField("Client ID", text: $clientId)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.05)))

                Text("App private key PEM")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.35))

                TextEditor(text: $privateKey)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .scrollContentBackground(.hidden)
                    .frame(height: 120)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.05)))
            }

            HStack {
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.plain)
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                if sync.isConfigured {
                    Button("Disconnect") {
                        sync.disconnect()
                        isPresented = false
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.red.opacity(0.75))
                }
                if !sync.isAppConfigured {
                    Button("Save app config") {
                        sync.saveAppConfig(clientId: clientId, privateKeyPEM: privateKey)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(red: 0.4, green: 0.85, blue: 1.0))
                    .disabled(clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button(sync.isSigningIn ? "Signing in..." : "Sign in") {
                        sync.signIn()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(red: 0.4, green: 0.85, blue: 1.0))
                    .disabled(sync.isSigningIn)
                }
            }

            Text(sync.status)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.35))
                .lineLimit(2)
        }
        .padding(16)
        .frame(width: 330)
        .background(Color(red: 0.07, green: 0.07, blue: 0.09))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct NoteItemRow: View {
    let note: QuickNote
    let onDelete: () -> Void
    let onPin: () -> Void
    let onOpenInObsidian: () -> Void
    @State var offsetX: CGFloat = 0
    @State var isHovered = false
    @State var copied = false
    @State var isDeleting = false
    @State var holdProgress: Double = 0
    @State var holdTimer: Timer?
    @State var forceTouchMonitor: Any?
    @State var forceTouchFlag = ForceTouchFlag()

    var swipeThreshold: CGFloat { 70 }
    let holdDuration: Double = 0.6

    var body: some View {
        ZStack(alignment: .trailing) {
            if offsetX < 0 {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundColor(.red.opacity(0.6))
                    .padding(.trailing, 12)
            }

            if offsetX > 0 {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.cyan.opacity(0.6))
                    .padding(.leading, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 6) {
                if note.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.cyan)
                }
                Text(note.content)
                    .lineLimit(2)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(copied ? 0.4 : 0.85))
                Spacer()
                if holdTimer != nil {
                    Circle()
                        .trim(from: 0, to: holdProgress)
                        .stroke(Color(red: 0.4, green: 0.85, blue: 1.0), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 16, height: 16)
                        .transition(.opacity)
                }
                if copied {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 8, weight: .bold))
                        Text("Copied")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundColor(.cyan)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.cyan.opacity(0.12))
                    .cornerRadius(4)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
                Text(note.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.3))
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        offsetX < -swipeThreshold ? Color.red.opacity(0.15) :
                        offsetX > swipeThreshold ? Color.cyan.opacity(0.15) :
                        copied ? Color.cyan.opacity(0.1) :
                        Color.white.opacity(isHovered ? 0.08 : 0.03)
                    )
            )
            .offset(x: offsetX)
            .opacity(isDeleting ? 0 : 1)
            .scaleEffect(isDeleting ? 0.85 : 1)
        }
        .onHover { hovering in isHovered = hovering }
        .onAppear {
            let flag = forceTouchFlag
            let action = onOpenInObsidian
            forceTouchMonitor = NSEvent.addLocalMonitorForEvents(matching: [.pressure]) { event in
                if event.stage == 2 {
                    flag.wasForceTouched = true
                    Task { @MainActor in action() }
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = forceTouchMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    let t = value.translation
                    let dist = hypot(t.width, t.height)

                    if forceTouchFlag.wasForceTouched {
                        cancelHold()
                        return
                    }

                    if dist > 10 {
                        offsetX = t.width
                        cancelHold()
                    } else if holdTimer == nil {
                        holdProgress = 0
                        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak holdTimer] _ in
                            Task { @MainActor in
                                guard let holdTimer = holdTimer else { return }
                                let progress = min(holdProgress + 0.016 / holdDuration, 1.0)
                                holdProgress = progress
                                if progress >= 1.0 {
                                    holdTimer.invalidate()
                                    self.holdTimer = nil
                                    onOpenInObsidian()
                                }
                            }
                        }
                    }
                }
                .onEnded { value in
                    if forceTouchFlag.wasForceTouched {
                        forceTouchFlag.wasForceTouched = false
                        cancelHold()
                        return
                    }

                    let t = value.translation
                    let dist = hypot(t.width, t.height)

                    if dist >= swipeThreshold {
                        if t.width < -swipeThreshold {
                            isDeleting = true
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
                                offsetX = -swipeThreshold * 2
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                onDelete()
                            }
                        } else if t.width > swipeThreshold {
                            withAnimation(.interpolatingSpring(mass: 0.7, stiffness: 180, damping: 15)) {
                                offsetX = swipeThreshold * 1.3
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                onPin()
                                withAnimation(.interpolatingSpring(mass: 0.7, stiffness: 180, damping: 15)) {
                                    offsetX = 0
                                }
                            }
                        }
                    } else {
                        if holdProgress < 1.0 {
                            copyToClipboard()
                        }
                        if offsetX != 0 {
                            withAnimation(.interpolatingSpring(mass: 0.7, stiffness: 180, damping: 15)) {
                                offsetX = 0
                            }
                        }
                    }

                    cancelHold()
                }
        )
        .animation(.interpolatingSpring(mass: 0.7, stiffness: 180, damping: 15), value: isHovered)
    }

    private func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        holdProgress = 0
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.content, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            withAnimation(.easeOut(duration: 0.15)) { copied = false }
        }
    }
}

// MARK: - Force Touch Flag

class ForceTouchFlag {
    var wasForceTouched = false
}

class QuickNotesManager: NSObject, ObservableObject, @unchecked Sendable {
    @Published var notes: [QuickNote] = []

    private var vaultPath: URL?
    private let metadataPath = "notes-meta.json"
    private var pollTimer: Timer?
    private var knownFileDates: [String: Date] = [:]
    var notesDirectory: URL? { vaultPath }

    override init() {
        super.init()
        setupVault()
        scanForNotes()
        startPolling()
    }

    private func setupVault() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let path = documentsPath.appendingPathComponent("MenuBar Notes")
        if !FileManager.default.fileExists(atPath: path.path) {
            try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        vaultPath = path
    }

    private func metadataURL() -> URL? {
        vaultPath?.appendingPathComponent(metadataPath)
    }

    private func loadMetadata() -> [String: Bool] {
        guard let url = metadataURL(),
              let data = try? Data(contentsOf: url),
              let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] else {
            return [:]
        }
        return meta
    }

    private func saveMetadata(_ meta: [String: Bool]) {
        guard let url = metadataURL(),
              let data = try? JSONSerialization.data(withJSONObject: meta) else { return }
            try? data.write(to: url)
    }

    func noteFileURL(filename: String) -> URL? {
        vaultPath?.appendingPathComponent("\(filename).md")
    }

    private func generateFilename(from content: String) -> String {
        let words = content.split(separator: " ").prefix(6)
        let base = words.map(String.init).joined(separator: "-")
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let candidate = String(base.prefix(40))
        if candidate.isEmpty { return UUID().uuidString }

        let existingNames = Set(notes.map { $0.filename })
        if !existingNames.contains(candidate) { return candidate }

        var counter = 2
        while existingNames.contains("\(candidate)-\(counter)") {
            counter += 1
        }
        return "\(candidate)-\(counter)"
    }

    private func scanForNotes() {
        guard let vaultPath else { return }
        let meta = loadMetadata()
        var loaded: [QuickNote] = []
        var seen: [String: Date] = [:]

        let files = (try? FileManager.default.contentsOfDirectory(at: vaultPath, includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey])) ?? []
        for file in files where file.pathExtension == "md" && file.lastPathComponent != metadataPath && !file.lastPathComponent.hasPrefix(".") {
            let filename = file.deletingPathExtension().lastPathComponent
            let modDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            seen[filename] = modDate
            guard let rawContent = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let parsed = parseNoteFile(rawContent)
            let noteId = parsed.id.flatMap { UUID(uuidString: $0) } ?? UUID(uuidString: filename) ?? UUID()
            let timestamp = parsed.created ?? (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            loaded.append(QuickNote(
                id: noteId,
                filename: filename,
                content: parsed.content,
                timestamp: timestamp,
                isPinned: meta[noteId.uuidString] ?? false
            ))
        }

        knownFileDates = seen
        notes = loaded.sorted { $0.timestamp > $1.timestamp }
    }

    private func parseNoteFile(_ raw: String) -> (id: String?, content: String, created: Date?) {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let endIndex = lines[1...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return (nil, raw, nil)
        }
        let frontMatter = lines[1..<endIndex]
        var created: Date?
        var id: String?
        for line in frontMatter {
            if line.hasPrefix("id:") {
                id = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            }
            if line.hasPrefix("created:") {
                let dateStr = line.dropFirst(8).trimmingCharacters(in: .whitespaces)
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                created = formatter.date(from: dateStr)
                if created == nil {
                    formatter.formatOptions = [.withInternetDateTime]
                    created = formatter.date(from: dateStr)
                }
            }
        }
        let content = lines[(endIndex + 1)...].joined(separator: "\n").trimmingCharacters(in: .newlines)
        return (id, content.isEmpty ? raw : content, created)
    }

    private func formatNoteFile(_ note: QuickNote) -> String {
        return """
        ---
        id: \(note.id.uuidString)
        tags:
          - menubar
          - quick-note
        ---

        \(note.content)
        """
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.checkForExternalChanges()
            }
        }
    }

    private func checkForExternalChanges() {
        guard let vaultPath else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: vaultPath, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var current: [String: Date] = [:]
        for file in files where file.pathExtension == "md" && file.lastPathComponent != metadataPath && !file.lastPathComponent.hasPrefix(".") {
            let filename = file.deletingPathExtension().lastPathComponent
            let modDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            current[filename] = modDate
        }

        var changed = knownFileDates != current
        if !changed {
            for (filename, date) in current {
                if knownFileDates[filename] != date {
                    changed = true
                    break
                }
            }
        }

        if changed {
            scanForNotes()
            objectWillChange.send()
            NotificationCenter.default.post(name: .notesDidChange, object: nil)
        }
    }

    func addNote(_ content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return }
        let filename = generateFilename(from: trimmed)
        let note = QuickNote(id: UUID(), filename: filename, content: trimmed, timestamp: Date())
        notes.insert(note, at: 0)
        if notes.count > 100 { notes.removeLast() }
        persistNote(note)
        NotificationCenter.default.post(name: .notesDidChange, object: nil)
    }

    func deleteNote(_ note: QuickNote) {
        notes.removeAll { $0.id == note.id }
        if let fileURL = noteFileURL(filename: note.filename) {
            try? FileManager.default.removeItem(at: fileURL)
        }
        var meta = loadMetadata()
        meta.removeValue(forKey: note.id.uuidString)
        saveMetadata(meta)
        knownFileDates.removeValue(forKey: note.filename)
        objectWillChange.send()
        NotificationCenter.default.post(name: .notesDidChange, object: nil)
    }

    func pinNote(_ note: QuickNote) {
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index].isPinned.toggle()
            var meta = loadMetadata()
            meta[note.id.uuidString] = notes[index].isPinned
            saveMetadata(meta)
            objectWillChange.send()
        }
    }

    private func persistNote(_ note: QuickNote) {
        guard let fileURL = noteFileURL(filename: note.filename) else { return }
        try? formatNoteFile(note).write(to: fileURL, atomically: true, encoding: .utf8)
        var meta = loadMetadata()
        if note.isPinned { meta[note.id.uuidString] = true }
        saveMetadata(meta)
        if let modDate = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            knownFileDates[note.filename] = modDate
        }
    }

    func note(idString: String) -> QuickNote? {
        notes.first { $0.id.uuidString == idString }
    }

    func createSyncedNote(title: String?, content: String, slateNumber: Int) -> QuickNote {
        let base = title?.isEmpty == false ? title! : "justtype slate \(slateNumber)"
        let filename = generateFilename(from: base)
        let note = QuickNote(id: UUID(), filename: filename, content: content, timestamp: Date())
        notes.insert(note, at: 0)
        persistNote(note)
        return note
    }

    func writeSyncedNote(id: UUID, filename: String, content: String) {
        let existing = notes.first { $0.id == id }
        let note = QuickNote(id: id, filename: filename, content: content, timestamp: existing?.timestamp ?? Date(), isPinned: existing?.isPinned ?? false)
        if let index = notes.firstIndex(where: { $0.id == id }) {
            notes[index] = note
        } else {
            notes.insert(note, at: 0)
        }
        persistNote(note)
        objectWillChange.send()
    }

    deinit {
        pollTimer?.invalidate()
    }
}

struct QuickNote: Identifiable {
    let id: UUID
    let filename: String
    let content: String
    let timestamp: Date
    var isPinned: Bool

    init(content: String) {
        self.id = UUID()
        self.filename = ""
        self.content = content
        self.timestamp = Date()
        self.isPinned = false
    }

    init(id: UUID, filename: String, content: String, timestamp: Date, isPinned: Bool = false) {
        self.id = id
        self.filename = filename
        self.content = content
        self.timestamp = timestamp
        self.isPinned = isPinned
    }
}
