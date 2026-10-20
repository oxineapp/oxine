import SwiftUI
import AppKit
import PanelKit

/// The three places a button sits on the right-click ring: up left, up
/// right, and on its own below (where a destructive action goes).
enum RingSlot: CaseIterable {
    case upLeft, upRight, down

    /// From the ring's center to each button's center.
    static let radius: CGFloat = 46
    static let size: CGFloat = 38

    /// Degrees, 0 to the right and 90 down.
    var angle: Double {
        switch self {
        case .upLeft:  return -150
        case .upRight: return -30
        case .down:    return 90
        }
    }

    var offset: CGSize {
        let a = angle * .pi / 180
        return CGSize(width: cos(a) * Self.radius, height: sin(a) * Self.radius)
    }

    /// The slot a held right button was dragged toward, once it's 28 pt out:
    /// the one closest in direction.
    static func flick(_ v: CGVector) -> RingSlot? {
        guard hypot(v.dx, v.dy) > 28 else { return nil }
        let a = atan2(v.dy, v.dx) * 180 / .pi
        func gap(_ slot: RingSlot) -> Double {
            let d = abs(a - slot.angle).truncatingRemainder(dividingBy: 360)
            return min(d, 360 - d)
        }
        return allCases.min { gap($0) < gap($1) }
    }

    /// The button under a point, given relative to the ring's center.
    static func button(at v: CGVector) -> RingSlot? {
        allCases.first { hypot(v.dx - $0.offset.width, v.dy - $0.offset.height) <= size / 2 + 3 }
    }

    /// Where the two halves of a split button sit: back out on the left,
    /// confirm on the right.
    var splitOffsets: (cancel: CGSize, confirm: CGSize) {
        let o = offset
        return (CGSize(width: o.width - 25, height: o.height + 4), CGSize(width: o.width + 25, height: o.height + 4))
    }
}

/// One action on the ring.
struct RingChoice {
    let slot: RingSlot
    let icon: String
    let title: String
    /// Destructive: picking it splits the button into ✕ and ✓, and only ✓
    /// runs it.
    var danger = false
}

struct RingState {
    /// The row or card the ring was opened on.
    let itemID: UUID
    let choices: [RingChoice]
    /// The ring's center in the list's visible area, kept clear of its edges.
    let center: CGPoint
    /// The press point minus the center (non-zero only near an edge).
    let pressOffset: CGSize
    /// The right button is still down.
    var pressed = true
    var highlight: RingSlot?
    /// A destructive action waiting for ✓ or ✕.
    var confirming: RingSlot?
    let openedAt = Date()

    /// How long after opening a held right button starts picking actions.
    /// A right-click let go before this only opens the ring.
    static let deadzone: TimeInterval = 0.4

    var settled: Bool { Date().timeIntervalSince(openedAt) >= Self.deadzone }

    func choice(_ slot: RingSlot) -> RingChoice? { choices.first { $0.slot == slot } }

    /// Whether a point relative to the center is on one of the ring's buttons.
    func hitsButton(_ v: CGVector) -> Bool {
        if let slot = confirming {
            let halves = slot.splitOffsets
            for o in [halves.cancel, halves.confirm] where hypot(v.dx - o.width, v.dy - o.height) <= RingSlot.size / 2 + 3 {
                return true
            }
        }
        guard let slot = RingSlot.button(at: v) else { return false }
        return choice(slot) != nil && slot != confirming
    }

    /// A window location relative to the ring's center. Window y runs up,
    /// the view's runs down.
    func vector(from press: CGPoint, to location: CGPoint) -> CGVector {
        CGVector(dx: pressOffset.width + location.x - press.x,
                 dy: pressOffset.height - (location.y - press.y))
    }

    /// How far the pointer has moved since the press.
    func flickVector(from press: CGPoint, to location: CGPoint) -> CGVector {
        CGVector(dx: location.x - press.x, dy: press.y - location.y)
    }
}

/// The right-click ring for a list: right-click a row and the ring opens
/// around the pointer and stays open; click an action to run it. Holding the
/// right button past the first moment, dragging toward an action and letting
/// go runs it too. Letting go sooner never runs anything.
///
/// The owner says which row is under the pointer (`target`), what the ring
/// offers for it (`choices`) and what each slot does (`perform`), and draws
/// `ActionRing` over its list in the same coordinates `target` reports.
@MainActor final class RingModel: ObservableObject {
    @Published var state: RingState?

    /// The row under the pointer, the pointer in the list's visible area,
    /// and that area's size; nil when the pointer isn't on a row.
    var target: () -> (id: UUID, point: CGPoint, viewport: CGSize)? = { nil }
    var choices: (UUID) -> [RingChoice] = { _ in [] }
    var perform: (RingSlot, UUID) -> Void = { _, _ in }
    var onOpen: (UUID) -> Void = { _ in }
    var onClose: () -> Void = {}

    private var monitor: Any?
    /// Window location of the right press that opened the ring.
    private var pressLocation: CGPoint = .zero

    func start() {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.rightMouseDown, .rightMouseDragged, .rightMouseUp, .leftMouseDown]) { [weak self] event in
                self?.handle(event) ?? event
            }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        state = nil
    }

    func close() {
        guard state != nil else { return }
        withAnimation(.easeOut(duration: 0.15)) { state = nil }
        onClose()
    }

    func pick(_ slot: RingSlot) {
        guard let current = state, let choice = current.choice(slot) else { return }
        if choice.danger {
            // Ask first: the button splits into ✕ and ✓.
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                state?.confirming = slot
                state?.highlight = nil
                state?.pressed = false
            }
            return
        }
        close()
        perform(slot, current.itemID)
    }

    /// ✓ on a split button.
    func confirm() {
        guard let current = state, let slot = current.confirming else { return }
        close()
        perform(slot, current.itemID)
    }

    /// ✕ on a split button: back to the ring.
    func cancelConfirm() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { state?.confirming = nil }
    }

    func highlight(_ slot: RingSlot?) {
        guard state?.highlight != slot else { return }
        withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) { state?.highlight = slot }
    }

    private func open(_ id: UUID, choices: [RingChoice], at point: CGPoint, in viewport: CGSize) {
        // Keep the ring and its label inside the list.
        let side = RingSlot.radius + RingSlot.size / 2 + 6
        let below = side + 34
        let center = CGPoint(
            x: min(max(point.x, side), max(viewport.width - side, side)),
            y: min(max(point.y, side), max(viewport.height - below, side)))
        onOpen(id)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            state = RingState(itemID: id, choices: choices, center: center,
                              pressOffset: CGSize(width: point.x - center.x, height: point.y - center.y))
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard PanelVisibility.shared.isOpen, event.window?.isKeyWindow == true else { return event }
        switch event.type {
        case .rightMouseDown:
            guard let target = target() else { return event }
            let offered = choices(target.id)
            guard !offered.isEmpty else { return event }
            pressLocation = event.locationInWindow
            open(target.id, choices: offered, at: target.point, in: target.viewport)
            return nil
        case .rightMouseDragged:
            guard let current = state, current.pressed, current.confirming == nil else { return event }
            let slot = current.settled
                ? RingSlot.flick(current.flickVector(from: pressLocation, to: event.locationInWindow))
                : nil
            highlight(slot.flatMap { current.choice($0) == nil ? nil : $0 })
            return nil
        case .rightMouseUp:
            guard let current = state, current.pressed else { return event }
            if current.settled, let slot = current.highlight {
                pick(slot)
            } else {
                state?.pressed = false
                highlight(nil)
            }
            return nil
        case .leftMouseDown:
            guard let current = state else { return event }
            if current.hitsButton(current.vector(from: pressLocation, to: event.locationInWindow)) { return event }
            close()
            return nil
        default:
            return event
        }
    }
}

/// Liquid Glass buttons that spread out from the press point. Each is its own
/// glass, and a highlighted one grows by its frame around its own center
/// (scaling the glass, or a shared glass container, pulled it off its spot).
struct ActionRing: View {
    let state: RingState
    var onPick: (RingSlot) -> Void
    var onHighlight: (RingSlot?) -> Void
    var onConfirm: () -> Void = {}
    var onCancelConfirm: () -> Void = {}
    @State private var spread = false

    private var label: String? {
        if let asking = state.confirming.flatMap(state.choice) { return asking.title + "?" }
        return state.highlight.flatMap(state.choice)?.title
    }

    var body: some View {
        ZStack {
            ForEach(state.choices, id: \.slot) { choice in
                if state.confirming == choice.slot {
                    RingSplit(slot: choice.slot, onCancel: onCancelConfirm, onConfirm: onConfirm)
                } else {
                    button(choice)
                        .offset(spread ? choice.slot.offset : .zero)
                        .opacity(state.confirming == nil ? 1 : 0.35)
                        .allowsHitTesting(state.confirming == nil)
                }
            }
            if let label {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .glassEffect(.regular, in: Capsule())
                    .fixedSize()
                    .offset(y: RingSlot.radius + RingSlot.size / 2 + (state.confirming == nil ? 18 : 26))
                    .transition(.opacity)
            }
        }
        .position(state.center)
        .onAppear {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.7)) { spread = true }
        }
    }

    private func button(_ choice: RingChoice) -> some View {
        let lit = state.highlight == choice.slot
        let side = RingSlot.size + (lit ? 5 : 0)
        return Button { onPick(choice.slot) } label: {
            Image(systemName: choice.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(choice.danger ? Color(red: 1, green: 0.54, blue: 0.48) : .white.opacity(0.92))
                .frame(width: side, height: side)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(lit ? .regular.tint(Color.panelAccent.opacity(0.45)) : .regular, in: Circle())
        .frame(width: RingSlot.size + 5, height: RingSlot.size + 5)
        .onHover { inside in
            if inside { onHighlight(choice.slot) } else if lit { onHighlight(nil) }
        }
    }
}

/// A destructive ring button split in two, like a drop pulling apart: ✕ backs
/// out, ✓ goes ahead.
private struct RingSplit: View {
    let slot: RingSlot
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @State private var apart = false

    var body: some View {
        let halves = slot.splitOffsets
        GlassEffectContainer(spacing: 10) {
            ZStack {
                RingSplitButton(icon: "xmark", help: "Cancel", danger: false, action: onCancel)
                    .offset(apart ? halves.cancel : slot.offset)
                RingSplitButton(icon: "checkmark", help: "Yes, delete", danger: true, action: onConfirm)
                    .offset(apart ? halves.confirm : slot.offset)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.66)) { apart = true }
        }
    }
}

private struct RingSplitButton: View {
    let icon: String
    let help: String
    let danger: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let side = RingSlot.size + (hovering ? 5 : 0)
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(danger ? .white : .white.opacity(0.9))
                .frame(width: side, height: side)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(danger ? .regular.tint(Color(red: 1, green: 0.3, blue: 0.25).opacity(hovering ? 0.75 : 0.55)) : .regular,
                     in: Circle())
        .frame(width: RingSlot.size + 5, height: RingSlot.size + 5)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovering)
        .help(help)
    }
}
