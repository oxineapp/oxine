import SwiftUI

struct ClipboardHistoryView: View {
    @Binding var items: [ClipboardItem]
    @ObservedObject var clipboardManager: ClipboardManager
    @ObservedObject var notesManager: QuickNotesManager
    var onSwitchToNotes: (() -> Void)? = nil
    @State var searchText = ""

    var filteredItems: [ClipboardItem] {
        if searchText.isEmpty { return items }
        return items.filter { $0.content.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if filteredItems.isEmpty {
                emptyState
            } else {
                itemsList
            }
        }
    }

    var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(searchText.isEmpty ? 0.2 : 0.4))
            TextField("Search clipboard\u{2026}", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.white.opacity(0.04))
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: searchText.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass")
                .font(.system(size: 20))
                .foregroundColor(.white.opacity(0.12))
            Text(searchText.isEmpty ? "No clipboard history" : "No results")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.25))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var itemsList: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(filteredItems) { item in
                    ClipboardItemRow(item: item, onDelete: {
                        clipboardManager.deleteItem(item)
                    }, onPin: {
                        clipboardManager.pinItem(item)
                    }, onCopy: {
                        clipboardManager.copyToClipboard(item)
                    }, onSaveAsNote: {
                        notesManager.addNote(item.content)
                        onSwitchToNotes?()
                    })
                        .contextMenu {
                            Button("Copy", action: { clipboardManager.copyToClipboard(item) })
                            Button("Save as Note", action: {
                                notesManager.addNote(item.content)
                                onSwitchToNotes?()
                            })
                            Button("Delete", action: { clipboardManager.deleteItem(item) })
                                .tint(.red)
                        }
                }
            }
            .padding(8)
        }
    }
}

struct ClipboardItemRow: View {
    let item: ClipboardItem
    let onDelete: () -> Void
    let onPin: () -> Void
    let onCopy: () -> Void
    var onSaveAsNote: (() -> Void)? = nil
    @State var isHovered = false
    @State var offsetX: CGFloat = 0
    @State var isDeleting = false
    @State var copied = false

    var swipeThreshold: CGFloat { 70 }

    var preview: String {
        let maxLength = 50
        let cleaned = item.content.replacingOccurrences(of: "\n", with: " ")
        return cleaned.count > maxLength ? String(cleaned.prefix(maxLength)) + "\u{2026}" : cleaned
    }

    var relativeTime: String {
        let interval = Date().timeIntervalSince(item.timestamp)
        switch interval {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(interval / 60))m ago"
        case ..<86400: return "\(Int(interval / 3600))h ago"
        default: return "\(Int(interval / 86400))d ago"
        }
    }

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
                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.cyan)
                }
                Text(preview)
                    .lineLimit(1)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
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
                Text(relativeTime)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.3))
                if item.copyCount > 1 {
                    Text("\u{00D7}\(item.copyCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.4))
                }
                if isHovered, let onSaveAsNote {
                    Button(action: onSaveAsNote) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.35))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Save as note")
                }
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
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    let t = value.translation
                    if hypot(t.width, t.height) > 10 {
                        offsetX = t.width
                    }
                }
                .onEnded { value in
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
                        onCopy()
                        withAnimation(.easeOut(duration: 0.15)) { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            withAnimation(.easeOut(duration: 0.15)) { copied = false }
                        }
                        if offsetX != 0 {
                            withAnimation(.interpolatingSpring(mass: 0.7, stiffness: 180, damping: 15)) {
                                offsetX = 0
                            }
                        }
                    }
                }
        )
        .animation(.interpolatingSpring(mass: 0.7, stiffness: 180, damping: 15), value: isHovered)
    }
}
