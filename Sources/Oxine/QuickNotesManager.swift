import Foundation
import AppKit
import CryptoKit

/// The notes on disk: one plain Markdown file per note in `NotesLocation.url`.
/// A note's id comes from its file name; pins live in `notes-meta.json` beside
/// them, keyed by that id. The folder is polled for edits made in other apps.
class QuickNotesManager: NSObject, ObservableObject, @unchecked Sendable {
    @Published var notes: [QuickNote] = []

    private var vaultPath: URL?
    private let metadataPath = "notes-meta.json"
    private var pollTimer: Timer?
    private var knownFileDates: [String: Date] = [:]
    /// Notes moved to the Trash this session, newest last, for Undo.
    private var trashed: [(trashURL: URL, original: URL)] = []
    var notesDirectory: URL? { vaultPath }
    var canUndoDelete: Bool { !trashed.isEmpty }

    override init() {
        super.init()
        setupVault()
        scanForNotes()
        startPolling()
        NotificationCenter.default.addObserver(
            self, selector: #selector(notesFolderChanged),
            name: .notesFolderChanged, object: nil)
    }

    private func setupVault() {
        // Resolved from the configurable setting (default ~/Documents/Oxine Notes);
        // NotesLocation creates the folder if needed.
        vaultPath = NotesLocation.url
    }

    /// The notes folder moved (Settings change) — re-point and reload the list.
    @objc private func notesFolderChanged() {
        setupVault()
        knownFileDates = [:]
        scanForNotes()
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

    /// A slug of the note's first words, made unique in the folder.
    private func generateFilename(from content: String) -> String {
        let words = content.split(whereSeparator: \.isWhitespace).prefix(6)
        let base = words.map(String.init).joined(separator: "-")
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9-]", with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let candidate = String(base.prefix(40))
        if candidate.isEmpty { return UUID().uuidString }

        let existingNames = Set(notes.map { $0.filename })
        if !existingNames.contains(candidate) && noteFileURL(filename: candidate).map({ !FileManager.default.fileExists(atPath: $0.path) }) ?? true {
            return candidate
        }
        var counter = 2
        while existingNames.contains("\(candidate)-\(counter)") { counter += 1 }
        return "\(candidate)-\(counter)"
    }

    /// A note's id, made from its file name so it's the same on every scan.
    private static func stableID(for filename: String) -> UUID {
        var b = Array(SHA256.hash(data: Data(filename.utf8)).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    private func scanForNotes() {
        guard let vaultPath else { return }
        var meta = loadMetadata()
        var metaChanged = false
        var loaded: [QuickNote] = []
        var seen: [String: Date] = [:]

        let files = (try? FileManager.default.contentsOfDirectory(at: vaultPath, includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey])) ?? []
        for file in files where file.pathExtension == "md" && file.lastPathComponent != metadataPath && !file.lastPathComponent.hasPrefix(".") {
            let filename = file.deletingPathExtension().lastPathComponent
            guard let rawContent = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var parsed = parseNoteFile(rawContent)
            let noteId = UUID(uuidString: filename) ?? Self.stableID(for: filename)

            // Oxine used to put an `id:` header at the top of every note, which
            // other editors show. Take it out once and carry the pin over.
            if let legacyID = parsed.id, parsed.content != rawContent {
                parsed.frontMatter = Self.removingID(from: parsed.frontMatter)
                write(Self.fileText(header: parsed.frontMatter, content: parsed.content), to: file)
                if meta[legacyID] != nil {
                    meta[noteId.uuidString] = meta.removeValue(forKey: legacyID)
                    metaChanged = true
                }
            }

            seen[filename] = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let timestamp = parsed.created ?? (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            loaded.append(QuickNote(
                id: noteId,
                filename: filename,
                content: parsed.content,
                timestamp: timestamp,
                isPinned: meta[noteId.uuidString] ?? false,
                frontMatter: parsed.frontMatter
            ))
        }

        if metaChanged { saveMetadata(meta) }
        knownFileDates = seen
        notes = loaded.sorted { $0.timestamp > $1.timestamp }
    }

    /// A header without Oxine's old `id:` line; nil when nothing else is left.
    private static func removingID(from header: String?) -> String? {
        guard let header else { return nil }
        let kept = header.components(separatedBy: "\n").filter { !$0.hasPrefix("id:") }
        return kept.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } ? nil : kept.joined(separator: "\n")
    }

    private static func fileText(header: String?, content: String) -> String {
        guard let header else { return content + "\n" }
        return "---\n\(header)\n---\n\n\(content)\n"
    }

    /// Writes a note file and keeps its creation date, which is the note's date
    /// when the file has no `created:` line.
    private func write(_ text: String, to url: URL) {
        let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
        try? text.write(to: url, atomically: true, encoding: .utf8)
        if let created {
            try? FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)
        }
    }

    private func parseNoteFile(_ raw: String) -> (id: String?, content: String, created: Date?, frontMatter: String?) {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              lines.count > 1,
              let endIndex = lines[1...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return (nil, raw, nil, nil)
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
        return (id, content.isEmpty ? raw : content, created, frontMatter.joined(separator: "\n"))
    }

    /// The file is the note's Markdown and nothing else. A header another app
    /// put there is written back as it was; Obsidian gets its tags header on
    /// new notes.
    private func formatNoteFile(_ note: QuickNote) -> String {
        if let header = note.frontMatter {
            return Self.fileText(header: header, content: note.content)
        }
        if NotesEditor.isObsidian {
            return Self.fileText(header: "tags:\n  - menubar\n  - quick-note", content: note.content)
        }
        return Self.fileText(header: nil, content: note.content)
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

        if knownFileDates != current {
            scanForNotes()
            objectWillChange.send()
            NotificationCenter.default.post(name: .notesDidChange, object: nil)
        }
    }

    @discardableResult
    func addNote(_ content: String) -> QuickNote? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let filename = generateFilename(from: NoteDocument(trimmed).title ?? trimmed)
        let note = QuickNote(id: UUID(), filename: filename, content: trimmed, timestamp: Date())
        notes.insert(note, at: 0)
        persistNote(note)
        NotificationCenter.default.post(name: .notesDidChange, object: nil)
        return note
    }

    /// Writes new text for a note, keeping its file, header, date and pin.
    func updateNote(_ id: UUID, content: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].content != content else { return }
        let old = notes[index]
        let note = QuickNote(id: old.id, filename: old.filename, content: content, timestamp: old.timestamp,
                             isPinned: old.isPinned, frontMatter: old.frontMatter)
        notes[index] = note
        persistNote(note)
        NotificationCenter.default.post(name: .notesDidChange, object: nil)
    }

    /// Ticks or unticks the checklist item on one line of a note.
    func toggleCheck(_ note: QuickNote, line: Int) {
        var lines = note.content.components(separatedBy: "\n")
        guard lines.indices.contains(line) else { return }
        let text = lines[line]
        if let r = text.range(of: "[ ]") {
            lines[line] = text.replacingCharacters(in: r, with: "[x]")
        } else if let r = text.range(of: "[x]", options: .caseInsensitive) {
            lines[line] = text.replacingCharacters(in: r, with: "[ ]")
        } else {
            return
        }
        updateNote(note.id, content: lines.joined(separator: "\n"))
    }

    /// Moves the note's file to the Trash. `undoDelete()` puts it back.
    func deleteNote(_ note: QuickNote) {
        notes.removeAll { $0.id == note.id }
        if let fileURL = noteFileURL(filename: note.filename) {
            var resulting: NSURL?
            do {
                try FileManager.default.trashItem(at: fileURL, resultingItemURL: &resulting)
                if let trashURL = resulting as URL? { trashed.append((trashURL, fileURL)) }
            } catch {
                log("Notes: couldn't move \(fileURL.lastPathComponent) to the Trash: \(error.localizedDescription)")
            }
        }
        knownFileDates.removeValue(forKey: note.filename)
        objectWillChange.send()
        NotificationCenter.default.post(name: .notesDidChange, object: nil)
    }

    /// Brings the last trashed note back from the Trash, pin and all.
    func undoDelete() {
        guard let last = trashed.popLast() else { return }
        do {
            try FileManager.default.moveItem(at: last.trashURL, to: last.original)
        } catch {
            log("Notes: couldn't restore \(last.original.lastPathComponent): \(error.localizedDescription)")
            return
        }
        scanForNotes()
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
        write(formatNoteFile(note), to: fileURL)
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

    // Used by the justtype sync (JustTypeSync.swift), which is off for now.

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
        let note = QuickNote(id: id, filename: filename, content: content, timestamp: existing?.timestamp ?? Date(),
                             isPinned: existing?.isPinned ?? false, frontMatter: existing?.frontMatter)
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
    /// The file's header lines between the `---` fences, kept to write back.
    /// Most notes have none.
    let frontMatter: String?
    /// The note read for display, worked out once.
    let document: NoteDocument

    init(content: String) {
        self.init(id: UUID(), filename: "", content: content, timestamp: Date())
    }

    init(id: UUID, filename: String, content: String, timestamp: Date, isPinned: Bool = false, frontMatter: String? = nil) {
        self.id = id
        self.filename = filename
        self.content = content
        self.timestamp = timestamp
        self.isPinned = isPinned
        self.frontMatter = frontMatter
        self.document = NoteDocument(content)
    }

    /// "Today, 09:40", "Yesterday", "Mon", "12 Oct", "12 Oct 2025".
    var dateLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(timestamp) {
            return "Today, " + timestamp.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(timestamp) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: timestamp, to: Date()).day ?? 0
        if days < 7 { return timestamp.formatted(.dateTime.weekday(.abbreviated)) }
        if calendar.isDate(timestamp, equalTo: Date(), toGranularity: .year) {
            return timestamp.formatted(.dateTime.day().month(.abbreviated))
        }
        return timestamp.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

/// A note's Markdown read into a title and simple blocks for the cards. The
/// first line is the title unless it's a list item.
struct NoteDocument {
    enum Block: Hashable {
        case text(String)
        case heading(String)
        case bullet(String)
        /// A checklist item and the line it's on in the note.
        case check(done: Bool, text: String, line: Int)
        case quote(String)
        case code(String)
    }

    let title: String?
    let blocks: [Block]

    var checklist: (done: Int, total: Int)? {
        var done = 0, total = 0
        for case .check(let isDone, _, _) in blocks {
            total += 1
            if isDone { done += 1 }
        }
        return total > 0 ? (done, total) : nil
    }

    private static let checkPattern = try! NSRegularExpression(pattern: #"^\s*[-*+]\s+\[([ xX])\]\s*(.*)$"#)
    private static let bulletPattern = try! NSRegularExpression(pattern: #"^\s*(?:[-*+]|\d+[.)])\s+(.*)$"#)
    private static let headingPattern = try! NSRegularExpression(pattern: #"^#{1,6}\s+(.*)$"#)

    init(_ content: String) {
        var title: String?
        var blocks: [Block] = []
        var inCode = false
        for (index, raw) in content.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inCode.toggle(); continue }
            if inCode { blocks.append(.code(raw)); continue }
            if line.isEmpty { continue }
            let first = title == nil && blocks.isEmpty
            if let m = Self.match(Self.checkPattern, line) {
                blocks.append(.check(done: m[0] != " ", text: m[1], line: index))
            } else if let m = Self.match(Self.bulletPattern, line) {
                blocks.append(.bullet(m[0]))
            } else if let m = Self.match(Self.headingPattern, line) {
                if first { title = NoteDocument.plain(m[0]) } else { blocks.append(.heading(m[0])) }
            } else if line.hasPrefix(">") {
                blocks.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else if first {
                title = NoteDocument.plain(line)
            } else {
                blocks.append(.text(line))
            }
        }
        self.title = title
        self.blocks = blocks
    }

    private static func match(_ regex: NSRegularExpression, _ line: String) -> [String]? {
        let ns = line as NSString
        guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }

    /// Text without inline Markdown marks: `**bold**` reads "bold".
    static func plain(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        for mark in ["**", "__", "~~", "`"] { s = s.replacingOccurrences(of: mark, with: "") }
        s = s.replacingOccurrences(of: #"(?<![\w*])[*_](\S(?:.*?\S)?)[*_](?![\w*])"#, with: "$1", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// One line of the card's text, with inline Markdown (bold, italic, code,
    /// links) rendered.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
