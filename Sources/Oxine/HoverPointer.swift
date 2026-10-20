import SwiftUI
import AppKit

/// Which row or tile the pointer is on, for hover highlights in scrolling
/// lists. It changes on every scroll frame, so it stays out of SwiftUI state;
/// only the hovered id is state, in the view that owns this.
///
/// AppKit only sends hover events when the mouse moves, so rows scrolling
/// under a still pointer never get them. Instead, whenever the pointer moves
/// or a row moves, the pointer's real position is read from the window and
/// checked against the rows' frames in the list's visible area. Rows report
/// those frames in a coordinate space named on the ScrollView, so they change
/// as it scrolls; put a `PointerProbe` behind the ScrollView.
@MainActor class HoverPointer {
    /// Frames of the rows on screen, in the list's visible area.
    private(set) var frames: [UUID: CGRect] = [:]
    /// Which view instance reported each frame. A row that moves (pinned,
    /// or dealt into the other column) is built anew before the old one goes,
    /// and the old one's leaving mustn't erase the new one's frame.
    private var owners: [UUID: UUID] = [:]
    weak var probe: PointerProbeView?
    /// The last location a hover event reported, to tell real pointer moves
    /// from repeats.
    var lastHover: CGPoint?
    var refreshQueued = false

    /// The pointer in the list's visible area, nil when it's outside.
    var location: CGPoint? { probe?.pointer }
    var viewport: CGSize { probe?.bounds.size ?? .zero }

    func report(_ id: UUID, frame: CGRect, from owner: UUID) {
        frames[id] = frame
        owners[id] = owner
    }

    func forget(_ id: UUID, from owner: UUID) {
        guard owners[id] == owner else { return }
        frames[id] = nil
        owners[id] = nil
    }

    /// The row at a point. The slop closes small gaps between rows.
    func row(at point: CGPoint, slop: CGFloat = 1.5) -> UUID? {
        frames.first { $0.value.insetBy(dx: -4, dy: -slop).contains(point) }?.key
    }
}

/// Reports a row's frame to a `HoverPointer` as it lays out and scrolls, and
/// takes it back when the row goes.
struct HoverFrame: ViewModifier {
    let id: UUID
    let pointer: HoverPointer
    /// The coordinate space named on the ScrollView.
    let space: String
    var onChange: () -> Void = {}
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        let space = space
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { frame in
                pointer.report(id, frame: frame, from: owner)
                onChange()
            }
            .onDisappear { pointer.forget(id, from: owner) }
    }
}

extension View {
    func hoverFrame(_ id: UUID, in pointer: HoverPointer, space: String, onChange: @escaping () -> Void = {}) -> some View {
        modifier(HoverFrame(id: id, pointer: pointer, space: space, onChange: onChange))
    }
}

/// A transparent view behind the list that reads where the pointer really is
/// from its window, so the hover check works without a mouse event.
final class PointerProbeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The pointer in this view, origin top left; nil when it's outside.
    var pointer: CGPoint? {
        guard let window else { return nil }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(p) else { return nil }
        return CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y)
    }
}

struct PointerProbe: NSViewRepresentable {
    let pointer: HoverPointer

    func makeNSView(context: Context) -> PointerProbeView {
        let view = PointerProbeView()
        pointer.probe = view
        return view
    }

    func updateNSView(_ view: PointerProbeView, context: Context) {
        pointer.probe = view
    }
}
