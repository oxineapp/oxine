import SwiftUI

/// History row presentation, switchable from the search bar and persisted across
/// relaunches: content-aware **Cards** (default — URLs render domain-first) or
/// the compact **Classic** list.
enum HistoryStyle: Int, CaseIterable {
    case card      // content-aware cards (URLs render domain-first)
    case baseline  // compact classic rows

    var label: String {
        switch self {
        case .card:     return "Cards"
        case .baseline: return "Classic"
        }
    }

    var icon: String {
        switch self {
        case .card:     return "rectangle.grid.1x2"
        case .baseline: return "list.bullet"
        }
    }

    var next: HistoryStyle {
        HistoryStyle(rawValue: (rawValue + 1) % HistoryStyle.allCases.count) ?? .card
    }

    static let storeKey = "historyStyle"
    static var stored: HistoryStyle {
        HistoryStyle(rawValue: UserDefaults.standard.integer(forKey: storeKey)) ?? .card
    }
}

struct ClipboardHistoryView: View {
    @Binding var items: [ClipboardItem]
    @ObservedObject var clipboardManager: ClipboardManager
    @ObservedObject var notesManager: QuickNotesManager
    var onSwitchToNotes: (() -> Void)? = nil
    @State var searchText = ""
    @State private var style: HistoryStyle = HistoryStyle.stored

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
            // Switch the row layout (Cards / Classic); the choice sticks.
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { style = style.next }
                UserDefaults.standard.set(style.rawValue, forKey: HistoryStyle.storeKey)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: style.icon)
                        .font(.system(size: 8, weight: .semibold))
                    Text(style.label)
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundColor(Color.panelAccent.opacity(0.9))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(Color.panelAccent.opacity(0.14))
                )
            }
            .buttonStyle(.plain)
            .help("Switch History layout (Cards / Classic)")
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
            // Lazy so a tab switch only builds the visible rows, not all ~200 at once
            // (eager VStack here was the main tab-switch stutter).
            LazyVStack(spacing: 6) {
                ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                    ClipboardItemRow(item: item, style: style, isFirst: index == 0, onDelete: {
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
    var style: HistoryStyle = .baseline
    var isFirst: Bool = false
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

    /// URL split for the content-aware Card layout: domain leads, the rest trails.
    /// Returns nil for non-URL content so it falls back to a plain preview.
    var urlParts: (domain: String, rest: String)? {
        let trimmed = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed),
              let host = url.host, url.scheme?.hasPrefix("http") == true else { return nil }
        let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        var rest = url.path
        if let q = url.query { rest += "?" + q }
        rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return (domain, rest)
    }

    // MARK: shared trailing cluster (copied badge, ×N, hover save)

    @ViewBuilder var trailingCluster: some View {
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
        if item.copyCount > 1 {
            Text("\u{00D7}\(item.copyCount)")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white.opacity(0.4))
        }
        // Always reserve the button's slot (constant row height) and just
        // fade it in on hover — inserting/removing it changed the row's
        // height and made hovering jitter.
        if let onSaveAsNote {
            Button(action: onSaveAsNote) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
                    .frame(width: 22, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Save as note")
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
    }

    @ViewBuilder var pinDot: some View {
        if item.isPinned {
            Image(systemName: "pin.fill")
                .font(.system(size: 8))
                .foregroundColor(.cyan)
        }
    }

    // MARK: per-style row

    @ViewBuilder var styledRow: some View {
        switch style {
        case .card:     cardRow
        case .baseline: baselineRow
        }
    }

    /// CARD — content-aware tiles. URLs render domain-first with the path dimmed
    /// underneath; plain text gets up to two lines. Time + count live in the card.
    var cardRow: some View {
        HStack(alignment: .top, spacing: 8) {
            pinDot
            VStack(alignment: .leading, spacing: 3) {
                if let parts = urlParts {
                    Text(parts.domain)
                        .lineLimit(1)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(copied ? 0.4 : 0.92))
                    if !parts.rest.isEmpty {
                        Text(parts.rest)
                            .lineLimit(1)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.35))
                    }
                } else {
                    Text(item.content.replacingOccurrences(of: "\n", with: " "))
                        .lineLimit(2)
                        .font(.system(size: 12.5))
                        .foregroundColor(.white.opacity(copied ? 0.4 : 0.9))
                }
                Text(relativeTime)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.25))
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 4) { trailingCluster }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    offsetX < -swipeThreshold ? Color.red.opacity(0.15) :
                    offsetX > swipeThreshold ? Color.cyan.opacity(0.15) :
                    copied ? Color.cyan.opacity(0.1) :
                    Color.white.opacity(isHovered ? 0.07 : 0.035)
                )
        )
    }

    /// BASELINE — the current shipped row, kept for side-by-side comparison.
    var baselineRow: some View {
        HStack(spacing: 6) {
            pinDot
            Text(preview)
                .lineLimit(1)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.85))
            Spacer()
            trailingCluster
            Text(relativeTime)
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

            styledRow
                .offset(x: offsetX)
                .opacity(isDeleting ? 0 : 1)
                .scaleEffect(isDeleting ? 0.85 : 1)
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
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
