import Foundation
import AppKit

@MainActor
class ClipboardManager: NSObject, ObservableObject {
    @Published var history: [ClipboardItem] = []
    
    private var lastChangeCount: Int = 0
    private nonisolated(unsafe) var timer: Timer?
    private let userDefaults = UserDefaults(suiteName: "com.oxine.clipboard")
    private let settingsDefaults = UserDefaults(suiteName: "com.oxine.settings")

    private var effectiveMaxItems: Int {
        let stored = settingsDefaults?.integer(forKey: "maxItems") ?? 0
        return stored > 0 ? stored : 50
    }
    
    override init() {
        super.init()
        loadHistory()
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
                addItem(string)
                // A genuine external copy — nudge the menu-bar orbit to spin.
                NotificationCenter.default.post(name: .clipboardCaptured, object: nil)
            }
        }
    }
    
    func addItem(_ content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty { return }

        // Check if item already exists
        if let existingIndex = history.firstIndex(where: { $0.content == trimmed }) {
            // Update timestamp and increment count
            history[existingIndex].timestamp = Date()
            history[existingIndex].copyCount += 1

            // Move to top (after pinned items)
            let item = history.remove(at: existingIndex)
            let firstNonPinned = history.firstIndex(where: { !$0.isPinned }) ?? history.count
            history.insert(item, at: firstNonPinned)
        } else {
            // New item
            let item = ClipboardItem(content: trimmed)
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
        lastChangeCount = NSPasteboard.general.changeCount
    }
    
    func deleteItem(_ item: ClipboardItem) {
        history.removeAll { $0.id == item.id }
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
        saveHistory()
    }
    
    private func saveHistory() {
        let encoded = history.map { [
            "id": $0.id.uuidString,
            "content": $0.content,
            "timestamp": $0.timestamp.timeIntervalSince1970,
            "copyCount": $0.copyCount,
            "isPinned": $0.isPinned,
        ] as [String: Any] }
        userDefaults?.set(encoded, forKey: "clipboardHistory")
    }

    private func loadHistory() {
        guard let stored = userDefaults?.array(forKey: "clipboardHistory") as? [[String: Any]] else { return }

        history = stored.compactMap { dict in
            guard let id = dict["id"] as? String,
                  let content = dict["content"] as? String,
                  let timestamp = dict["timestamp"] as? TimeInterval else { return nil }

            let copyCount = (dict["copyCount"] as? Int) ?? 1
            let isPinned = (dict["isPinned"] as? Bool) ?? false

            return ClipboardItem(
                id: UUID(uuidString: id) ?? UUID(),
                content: content,
                timestamp: Date(timeIntervalSince1970: timestamp),
                copyCount: copyCount,
                isPinned: isPinned
            )
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

    init(content: String) {
        self.id = UUID()
        self.content = content
        self.timestamp = Date()
        self.copyCount = 1
    }

    init(id: UUID, content: String, timestamp: Date, copyCount: Int = 1, isPinned: Bool = false) {
        self.id = id
        self.content = content
        self.timestamp = timestamp
        self.copyCount = copyCount
        self.isPinned = isPinned
    }
}
