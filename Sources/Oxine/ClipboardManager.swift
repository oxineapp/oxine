import Foundation
import AppKit
import PanelKit

@MainActor
class ClipboardManager: NSObject, ObservableObject {
    @Published var history: [ClipboardItem] = []
    
    private var lastChangeCount: Int = 0
    private nonisolated(unsafe) var timer: Timer?
    private let userDefaults = UserDefaults(suiteName: "com.oxine.clipboard")
    /// The history lives in Oxine's keychain vault rather than a plist, since
    /// secrets (concealed copies, keys, tokens) land in it too.
    private static let vaultService = "Clipboard"
    private static let vaultAccount = "history"
    private static let legacyKey = "clipboardHistory"
    /// Off when the stored history couldn't be read (a denied keychain
    /// prompt): saving then would overwrite it, and every copy would prompt
    /// again. The session's copies stay in memory instead.
    private var canSave = false
    private let settingsDefaults = UserDefaults(suiteName: "com.oxine.settings")

    private var effectiveMaxItems: Int {
        let stored = settingsDefaults?.integer(forKey: "maxItems") ?? 0
        return stored > 0 ? stored : 50
    }
    
    /// The last app other than Oxine to come to the front: where ⌘↩ pastes.
    private var previousApp: NSRunningApplication?

    override init() {
        super.init()
        loadHistory()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        previousApp = app
    }
    
    func startMonitoring() {
        timer?.invalidate()
        lastChangeCount = NSPasteboard.general.changeCount

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkClipboard()
            }
        }
    }
    
    private func checkClipboard() {
        let changeCount = NSPasteboard.general.changeCount
        
        if changeCount != lastChangeCount {
            lastChangeCount = changeCount

            if let string = NSPasteboard.general.string(forType: .string) {
                // Password managers (and the authenticator's export) mark
                // secrets concealed; those and anything that looks like a key
                // or token show veiled in the history.
                let concealed = NSPasteboard.general.types?.contains(.concealed) == true
                let secret = concealed || SecretDetector.looksSecret(string)
                addItem(string, isSecret: secret, source: NSWorkspace.shared.frontmostApplication)
                // A link with trackers: the notch offers to clean it.
                if !secret { LinkTrackers.check(string) }
                // A genuine external copy — nudge the menu-bar orbit to spin.
                NotificationCenter.default.post(name: .clipboardCaptured, object: nil)
            }
        }
    }
    
    func addItem(_ content: String, isSecret: Bool = false, source: NSRunningApplication? = nil) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty { return }

        // Check if item already exists
        if let existingIndex = history.firstIndex(where: { $0.content == trimmed }) {
            // Update timestamp and increment count
            history[existingIndex].timestamp = Date()
            history[existingIndex].copyCount += 1
            if isSecret { history[existingIndex].isSecret = true }
            if let source { history[existingIndex].setSource(source) }

            // Move to top (after pinned items)
            let item = history.remove(at: existingIndex)
            let firstNonPinned = history.firstIndex(where: { !$0.isPinned }) ?? history.count
            history.insert(item, at: firstNonPinned)
        } else {
            // New item
            var item = ClipboardItem(content: trimmed, isSecret: isSecret)
            if let source { item.setSource(source) }
            let firstNonPinned = history.firstIndex(where: { !$0.isPinned }) ?? history.count
            history.insert(item, at: firstNonPinned)

            let unpinnedCount = history.filter { !$0.isPinned }.count
            if unpinnedCount > effectiveMaxItems {
                if let lastUnpinned = history.lastIndex(where: { !$0.isPinned }) {
                    history.remove(at: lastUnpinned)
                }
            }
        }

        saveHistory()
    }
    
    func copyToClipboard(_ item: ClipboardItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.content, forType: .string)
        // Keep a secret concealed for other clipboard histories too.
        if item.isSecret { NSPasteboard.general.setData(Data(), forType: .concealed) }
        lastChangeCount = NSPasteboard.general.changeCount
    }

    /// Copies the item, closes the panel and pastes it into the app that was
    /// in front before. Pasting needs Accessibility; without it the item is
    /// only copied and macOS asks for the permission.
    func paste(_ item: ClipboardItem) {
        copyToClipboard(item)
        guard AXIsProcessTrusted() else {
            FnGestureEngine.requestAccessibility()
            return
        }
        guard let target = previousApp, !target.isTerminated else { return }
        if PanelVisibility.shared.isOpen { AppDelegate.instance?.togglePanel() }
        target.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let source = CGEventSource(stateID: .combinedSessionState)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down)   // V
                event?.flags = .maskCommand
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    func setSecret(_ item: ClipboardItem, _ secret: Bool) {
        if let index = history.firstIndex(where: { $0.id == item.id }) {
            history[index].isSecret = secret
            saveHistory()
        }
    }
    
    /// Deleted items and where they were, newest last, for Undo. Kept for
    /// this session only.
    private var recentlyDeleted: [(item: ClipboardItem, index: Int)] = []

    var canUndoDelete: Bool { !recentlyDeleted.isEmpty }

    func deleteItem(_ item: ClipboardItem) {
        guard let index = history.firstIndex(where: { $0.id == item.id }) else { return }
        recentlyDeleted.append((history.remove(at: index), index))
        if recentlyDeleted.count > 20 { recentlyDeleted.removeFirst() }
        saveHistory()
    }

    /// Puts the last deleted item back where it was.
    func undoDelete() {
        guard let last = recentlyDeleted.popLast() else { return }
        history.insert(last.item, at: min(last.index, history.count))
        saveHistory()
    }

    func pinItem(_ item: ClipboardItem) {
        if let index = history.firstIndex(where: { $0.id == item.id }) {
            history[index].isPinned.toggle()
            saveHistory()
        }
    }
    
    func clearHistory() {
        history.removeAll()
        recentlyDeleted.removeAll()
        saveHistory()
    }
    
    private func saveHistory() {
        guard canSave else { return }
        let encoded = history.map { [
            "id": $0.id.uuidString,
            "content": $0.content,
            "timestamp": $0.timestamp.timeIntervalSince1970,
            "copyCount": $0.copyCount,
            "isPinned": $0.isPinned,
            "isSecret": $0.isSecret,
            "sourceApp": $0.sourceApp ?? "",
            "sourceBundleID": $0.sourceBundleID ?? "",
        ] as [String: Any] }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: encoded, format: .binary, options: 0)
        else { return }
        Keychain.set(data, service: Self.vaultService, account: Self.vaultAccount)
    }

    private func loadHistory() {
        switch Keychain.read(service: Self.vaultService, account: Self.vaultAccount) {
        case .success(let data):
            canSave = true
            let stored = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [[String: Any]]
            history = decode(stored ?? [])
        case .notFound:
            // First run on the keychain: move the old plain-text history over,
            // then delete it once the vault has it.
            canSave = true
            history = decode(userDefaults?.array(forKey: Self.legacyKey) as? [[String: Any]] ?? [])
            saveHistory()
            if Keychain.get(service: Self.vaultService, account: Self.vaultAccount) != nil {
                userDefaults?.removeObject(forKey: Self.legacyKey)
            }
        case .denied, .failure:
            log("Clipboard history: keychain unreadable, keeping this session's copies in memory only")
        }
    }

    private func decode(_ stored: [[String: Any]]) -> [ClipboardItem] {
        stored.compactMap { dict in
            guard let id = dict["id"] as? String,
                  let content = dict["content"] as? String,
                  let timestamp = dict["timestamp"] as? TimeInterval else { return nil }

            let copyCount = (dict["copyCount"] as? Int) ?? 1
            let isPinned = (dict["isPinned"] as? Bool) ?? false
            // Items saved before secrets were flagged get checked once here.
            let isSecret = (dict["isSecret"] as? Bool) ?? SecretDetector.looksSecret(content)

            var item = ClipboardItem(
                id: UUID(uuidString: id) ?? UUID(),
                content: content,
                timestamp: Date(timeIntervalSince1970: timestamp),
                copyCount: copyCount,
                isPinned: isPinned,
                isSecret: isSecret
            )
            if let app = dict["sourceApp"] as? String, !app.isEmpty { item.sourceApp = app }
            if let bundle = dict["sourceBundleID"] as? String, !bundle.isEmpty { item.sourceBundleID = bundle }
            return item
        }
    }

    deinit {
        timer?.invalidate()
    }
}

struct ClipboardItem: Identifiable {
    let id: UUID
    let content: String
    var timestamp: Date
    var copyCount: Int = 1
    var isPinned = false
    /// Shown veiled in the history (see `Spoiler`) until revealed.
    var isSecret = false
    let kind: ClipKind
    /// The first line with text on it, and how many lines there are.
    let firstLine: String
    let lineCount: Int
    /// The app in front when it was copied.
    var sourceApp: String?
    var sourceBundleID: String?

    init(content: String, isSecret: Bool = false) {
        self.id = UUID()
        self.content = content
        self.timestamp = Date()
        self.copyCount = 1
        self.isSecret = isSecret
        self.kind = ClipKind.classify(content)
        (self.firstLine, self.lineCount) = ClipKind.summarize(content)
    }

    mutating func setSource(_ app: NSRunningApplication) {
        sourceApp = app.localizedName
        sourceBundleID = app.bundleIdentifier
    }

    init(id: UUID, content: String, timestamp: Date, copyCount: Int = 1, isPinned: Bool = false, isSecret: Bool = false) {
        self.id = id
        self.content = content
        self.timestamp = timestamp
        self.copyCount = copyCount
        self.isPinned = isPinned
        self.isSecret = isSecret
        self.kind = ClipKind.classify(content)
        (self.firstLine, self.lineCount) = ClipKind.summarize(content)
    }
}

extension NSPasteboard.PasteboardType {
    /// The nspasteboard.org marker apps put on copied secrets.
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
}
