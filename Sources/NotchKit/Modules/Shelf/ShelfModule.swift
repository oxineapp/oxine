import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PanelKit

/// A file shelf in the notch: drag files in to stash them, drag them back out
/// anywhere, or fling them via AirDrop. Entries auto-expire after a day.
@MainActor
public final class ShelfModule: NotchModule {
    public let id = "shelf"
    public let title = "Shelf"
    public let icon = "tray.full"
    public var onIdleChange: (() -> Void)?

    let store = ShelfStore()

    public init() {}

    public func expandedView() -> AnyView { AnyView(ShelfExpanded(store: store)) }
}

// MARK: - Store

struct ShelfItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let addedAt: Date
    var name: String { url.lastPathComponent }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
}

@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    /// Entries older than this drop off the shelf.
    private let ttl: TimeInterval = 24 * 60 * 60

    func add(_ url: URL) {
        prune()
        guard !items.contains(where: { $0.url == url }) else { return }
        items.append(ShelfItem(url: url, addedAt: Date()))
    }

    func remove(_ item: ShelfItem) { items.removeAll { $0.id == item.id } }

    func prune() {
        let now = Date()
        items.removeAll { now.timeIntervalSince($0.addedAt) > ttl || !FileManager.default.fileExists(atPath: $0.url.path) }
    }

    /// Send everything on the shelf via AirDrop.
    func airdrop() {
        prune()
        let urls = items.map(\.url)
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        service.perform(withItems: urls)
    }
}

// MARK: - Expanded

/// Load file URLs from dropped providers, then deliver them on the main actor.
@MainActor
func loadDroppedURLs(_ providers: [NSItemProvider], _ completion: @escaping ([URL]) -> Void) {
    let lock = NSLock()
    var urls: [URL] = []
    let group = DispatchGroup()
    for provider in providers {
        group.enter()
        _ = provider.loadObject(ofClass: NSURL.self) { obj, _ in
            if let url = obj as? URL { lock.lock(); urls.append(url); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) { completion(urls) }
}

struct ShelfExpanded: View {
    @ObservedObject var store: ShelfStore
    /// The AirDrop tile only belongs on the full Shelf tab — the Home slot is just
    /// the drop tray (AirDrop lives on the dedicated tab).
    var showAirDrop = true
    /// When false, an outer view owns the drop (the Home slot's card handles it
    /// above the glass), so we don't attach our own onDrop and instead reflect the
    /// caller's `externalTargeted` for the highlight.
    var handlesOwnDrop = true
    var externalTargeted = false
    @State private var ownTargeted = false
    @State private var airTargeted = false

    private var targeted: Bool { handlesOwnDrop ? ownTargeted : externalTargeted }

    var body: some View {
        HStack(spacing: 10) {
            dropZone
            if showAirDrop { airDropTile }
        }
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(targeted ? Color.panelAccent : .white.opacity(0.12),
                                style: StrokeStyle(lineWidth: 1, dash: store.items.isEmpty ? [5, 4] : []))
                )

            if store.items.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.4))
                    Text("Drop files here")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                    Text("Kept for a day")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.3))
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(store.items) { item in
                            ShelfTile(item: item) { store.remove(item) }
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: handlesOwnDrop ? [.fileURL] : [], isTargeted: $ownTargeted) { providers in
            loadDroppedURLs(providers) { urls in urls.forEach(store.add) }
            return true
        }
    }

    private var airDropTile: some View {
        VStack(spacing: 6) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 22, weight: .medium))
            Text("AirDrop")
                .font(.system(size: 11, weight: .semibold))
        }
        // Brighten when items are on the shelf OR a file is being dragged onto it.
        .foregroundColor(airTargeted || !store.items.isEmpty ? .white.opacity(0.95) : .white.opacity(0.35))
        .frame(width: 92)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(airTargeted ? 0.14 : 0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(airTargeted ? Color.panelAccent : .clear, lineWidth: 1.5)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        // Click to send what's on the shelf…
        .onTapGesture { store.airdrop() }
        // …or drop files straight onto it to AirDrop them directly.
        .onDrop(of: [.fileURL], isTargeted: $airTargeted) { providers in
            loadDroppedURLs(providers) { urls in
                guard !urls.isEmpty, let svc = NSSharingService(named: .sendViaAirDrop) else { return }
                svc.perform(withItems: urls)
            }
            return true
        }
        .help("Drop files to AirDrop, or click to send the shelf")
    }
}

private struct ShelfTile: View {
    let item: ShelfItem
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            // The icon is an AppKit drag source so dragging out can MOVE, not just
            // copy (SwiftUI's `.onDrag` only ever offers copy). On a successful move
            // the file is gone, so we drop the shelf entry.
            FileDragSource(url: item.url, onEnd: { op in
                if op.contains(.move) { onRemove() }
            }) {
                Image(nsImage: item.icon)
                    .resizable()
                    .frame(width: 44, height: 44)
            }
            .frame(width: 44, height: 44)
            // The remove button overlays the icon's own top-right corner (not the
            // wider name area), so it sits cleanly on the tile rather than floating.
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.65))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 7, y: -7)
                    .transition(.opacity.combined(with: .scale))
                }
            }
            Text(item.name)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 58)
        }
        .padding(.top, 4)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}

// MARK: - AppKit drag source (copy OR move)

/// Wraps SwiftUI content in a real AppKit drag source that advertises BOTH copy
/// and move for a file URL. SwiftUI's `.onDrag` only ever offers `.copy`, which is
/// why dragging out of the shelf always copied; here the destination (or the
/// user's ⌘/⌥ modifiers) decides — a same-volume Finder drop moves, exactly like
/// dragging in Finder. Matches Boring Notch's `NSDraggingSource` approach.
struct FileDragSource<Content: View>: NSViewRepresentable {
    let url: URL
    /// Final drag operation, so the caller can drop the shelf entry after a move.
    var onEnd: (NSDragOperation) -> Void = { _ in }
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> DragSourceView {
        let v = DragSourceView()
        v.update(url: url, onEnd: onEnd, content: AnyView(content))
        return v
    }

    func updateNSView(_ v: DragSourceView, context: Context) {
        v.update(url: url, onEnd: onEnd, content: AnyView(content))
    }
}

final class DragSourceView: NSView, NSDraggingSource {
    private var url: URL!
    private var onEnd: (NSDragOperation) -> Void = { _ in }
    private var hosting: NSHostingView<AnyView>?
    private var mouseDownEvent: NSEvent?
    private var accessing = false

    func update(url: URL, onEnd: @escaping (NSDragOperation) -> Void, content: AnyView) {
        self.url = url
        self.onEnd = onEnd
        if let hosting {
            hosting.rootView = content
        } else {
            let h = NSHostingView(rootView: content)
            h.translatesAutoresizingMaskIntoConstraints = false
            addSubview(h)
            NSLayoutConstraint.activate([
                h.leadingAnchor.constraint(equalTo: leadingAnchor),
                h.trailingAnchor.constraint(equalTo: trailingAnchor),
                h.topAnchor.constraint(equalTo: topAnchor),
                h.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            hosting = h
        }
    }

    override func mouseDown(with event: NSEvent) { mouseDownEvent = event }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent else { return }
        let dist = hypot(event.locationInWindow.x - down.locationInWindow.x,
                         event.locationInWindow.y - down.locationInWindow.y)
        guard dist > 3 else { return }              // a real drag, not a click
        mouseDownEvent = nil

        let item = NSPasteboardItem()
        if url.startAccessingSecurityScopedResource() { accessing = true }
        item.setString(url.absoluteString, forType: .fileURL)
        item.setString(url.path, forType: .string)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 48, height: 48)
        dragItem.setDraggingFrame(NSRect(x: 0, y: 0, width: 48, height: 48), contents: icon)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Offer move AND copy; the destination / modifier keys pick (Finder moves
        // on the same volume, copies across volumes, ⌥ forces copy, ⌘ forces move).
        context == .withinApplication ? [.copy, .move, .generic] : [.copy, .move]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt point: NSPoint,
                         operation: NSDragOperation) {
        if accessing { url.stopAccessingSecurityScopedResource(); accessing = false }
        onEnd(operation)
    }
}
