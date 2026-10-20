import SwiftUI
import AppKit
import PanelKit

/// The Board layout: pinned items in a row of small tiles, then everything
/// else in two columns of tiles, grouped by day.
struct ClipBoardGrid: View {
    /// Pinned first, then newest first.
    let items: [ClipboardItem]
    let hoveredID: UUID?
    let copiedID: UUID?
    let isShown: (ClipboardItem) -> Bool
    /// The list's coordinate space, for reporting tile frames.
    let space: String
    let pointer: HoverPointer
    let onFrameChange: () -> Void
    let onCopy: (ClipboardItem) -> Void
    let onToggleReveal: (ClipboardItem) -> Void
    let onPin: (ClipboardItem) -> Void
    let onDelete: (ClipboardItem) -> Void

    private struct Section: Identifiable {
        let title: String
        let items: [ClipboardItem]
        var id: String { title }
    }

    private var sections: [Section] {
        let calendar = Calendar.current
        var today: [ClipboardItem] = [], yesterday: [ClipboardItem] = [], earlier: [ClipboardItem] = []
        for item in items where !item.isPinned {
            if calendar.isDateInToday(item.timestamp) { today.append(item) }
            else if calendar.isDateInYesterday(item.timestamp) { yesterday.append(item) }
            else { earlier.append(item) }
        }
        return [Section(title: "Today", items: today),
                Section(title: "Yesterday", items: yesterday),
                Section(title: "Earlier", items: earlier)].filter { !$0.items.isEmpty }
    }

    var body: some View {
        let pinned = items.filter(\.isPinned)
        LazyVStack(alignment: .leading, spacing: 0) {
            if !pinned.isEmpty {
                header("Pinned")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(pinned) { tile($0, compact: true) }
                }
            }
            ForEach(sections) { section in
                header(section.title)
                let (left, right) = Self.columns(section.items)
                HStack(alignment: .top, spacing: 8) {
                    LazyVStack(spacing: 8) { ForEach(left) { tile($0) } }
                    LazyVStack(spacing: 8) { ForEach(right) { tile($0) } }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white.opacity(0.55))
            .padding(.leading, 2)
            .padding(.top, 10)
            .padding(.bottom, 7)
    }

    private func tile(_ item: ClipboardItem, compact: Bool = false) -> some View {
        ClipBoardTile(
            item: item,
            compact: compact,
            isHovered: hoveredID == item.id,
            isCopied: copiedID == item.id,
            isShown: isShown(item),
            onCopy: { onCopy(item) },
            onToggleReveal: { onToggleReveal(item) },
            onPin: { onPin(item) },
            onDelete: { onDelete(item) })
        .id(item.id)
        .hoverFrame(item.id, in: pointer, space: space, onChange: onFrameChange)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    /// Deals tiles into two columns, each to the shorter one so far, by a
    /// rough height for its kind and length.
    private static func columns(_ items: [ClipboardItem]) -> ([ClipboardItem], [ClipboardItem]) {
        var left: [ClipboardItem] = [], right: [ClipboardItem] = []
        var leftHeight: CGFloat = 0, rightHeight: CGFloat = 0
        for item in items {
            let height = estimatedHeight(item) + 8
            if leftHeight <= rightHeight {
                left.append(item); leftHeight += height
            } else {
                right.append(item); rightHeight += height
            }
        }
        return (left, right)
    }

    private static func estimatedHeight(_ item: ClipboardItem) -> CGFloat {
        if item.isSecret { return 92 }
        let lines = CGFloat(min(3, max(item.lineCount, Int(ceil(Double(item.content.count) / 30)))))
        switch item.kind {
        case .link:  return 72
        case .color: return 80
        case .code:  return 56 + lines * 16
        case .text:  return 40 + lines * 18
        }
    }
}

/// One Board tile. Click copies; Pin and Delete float in the corner on hover.
/// A color is its own tile, and its "Copied" mark stays readable on it.
struct ClipBoardTile: View {
    let item: ClipboardItem
    var compact = false
    let isHovered: Bool
    let isCopied: Bool
    let isShown: Bool
    let onCopy: () -> Void
    let onToggleReveal: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void

    private var swatch: ClipColor? { item.isSecret ? nil : item.clipColor }

    /// Text on a color tile: dark on a light color, white on a dark one.
    private var swatchInk: Color? {
        swatch.map { $0.luminance > 0.4 ? Color(red: 0.02, green: 0.14, blue: 0.18) : .white }
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 13, style: .continuous) }

    var body: some View {
        let ink = ContrastInk.copied(on: swatch)
        VStack(alignment: .leading, spacing: 6) {
            content
            if compact { Spacer(minLength: 0) }
            meta(ink)
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, minHeight: compact ? 74 : nil, maxHeight: compact ? 74 : nil, alignment: .topLeading)
        .background(shape.fill(swatch?.color ?? Color.white.opacity(isHovered ? 0.075 : 0.05)))
        .brightness(swatch != nil && isHovered ? 0.04 : 0)
        .overlay(
            shape.strokeBorder(isCopied ? ink.ring : Color.white.opacity(0.08), lineWidth: isCopied ? 1.5 : 0.5)
        )
        .overlay(alignment: .topTrailing) { corner }
        .contentShape(shape)
        .onTapGesture(perform: onCopy)
        .onDrag { NSItemProvider(object: item.content as NSString) }
    }

    @ViewBuilder private var content: some View {
        let excerpt = String(item.content.prefix(400))
        if item.isSecret {
            Button(action: onToggleReveal) {
                Spoiler(isHidden: !isShown, origin: .center) {
                    Text(excerpt)
                        .font(.system(size: 11, design: .monospaced))
                        .lineSpacing(2)
                        .lineLimit(compact ? 1 : 3)
                        .foregroundColor(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, compact ? 8 : 10)
                        .padding(.vertical, compact ? 7 : 9)
                }
                .frame(minHeight: compact ? 28 : 46)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.2)))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isShown ? "Hide" : "Show")
        } else if compact {
            Text(item.firstLine)
                .font(item.kind == .code || item.kind == .color ? .system(size: 12, design: .monospaced) : .system(size: 12))
                .lineLimit(2)
                .foregroundColor(swatchInk ?? .white.opacity(0.9))
        } else if let link = item.linkParts {
            VStack(alignment: .leading, spacing: 3) {
                Text(link.host)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(1)
                if !link.path.isEmpty {
                    Text(link.path)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(.white.opacity(0.58))
                        .lineLimit(2)
                }
            }
        } else if item.kind == .code {
            Text(excerpt)
                .font(.system(size: 11, design: .monospaced))
                .lineSpacing(2)
                .lineLimit(3)
                .foregroundColor(.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.28)))
        } else if item.kind == .color {
            Text(item.firstLine)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundColor(swatchInk)
                .padding(.top, 22)
        } else {
            Text(excerpt)
                .font(.system(size: 13))
                .lineSpacing(2)
                .lineLimit(3)
                .foregroundColor(.white.opacity(0.9))
        }
    }

    private func meta(_ ink: ContrastInk) -> some View {
        let origin = item.sourceApp ?? (item.isSecret ? "Secret" : item.kind.label)
        return HStack(spacing: 6) {
            Text(compact ? origin : "\(origin) · \(item.age)")
                .font(.system(size: 10.5))
                .foregroundColor(swatchInk.map { $0.opacity(0.72) } ?? .white.opacity(0.52))
                .lineLimit(1)
            Spacer(minLength: 0)
            if isCopied {
                Text("Copied")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(ink.foreground)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(ink.fill))
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .trailing)))
            }
        }
    }

    private var corner: some View {
        HStack(spacing: 1) {
            ClipIconButton(icon: item.isPinned ? "pin.slash" : "pin", help: item.isPinned ? "Unpin" : "Pin",
                           size: CGSize(width: 24, height: 22), action: onPin)
            ClipIconButton(icon: "trash", help: "Delete", danger: true,
                           size: CGSize(width: 24, height: 22), action: onDelete)
        }
        .padding(2)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(6)
        .opacity(isHovered ? 1 : 0)
        .scaleEffect(isHovered ? 1 : 0.9, anchor: .topTrailing)
        .allowsHitTesting(isHovered)
    }
}
