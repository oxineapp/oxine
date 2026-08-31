import AppKit
import QuartzCore

/// A fixed maximum area with content-sized background and independently drawn guides.
/// All text effects are cancelled before a new line, so fast seeks cannot restore stale text.
@MainActor
final class LyricCanvas: NSView {
    struct Style: Equatable {
        var fontFamily = "system"
        var fontSize = 22.0
        var backgroundEnabled = true
        var backgroundOpacity = 0.82
        var showBounds = false
        var showTrack = true
        var animation = "fade"
        var animationDuration = 0.25
    }

    private let background = NSView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let caption = NSTextField(labelWithString: "")
    private let guideLabel = NSTextField(labelWithString: "")
    private let outline = CAShapeLayer()
    private var typingTimer: Timer?
    private var fullText = ""
    private var lastStyle: Style?
    private var lastSize: NSSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        addSubview(background)
        for text in [label, caption, guideLabel] {
            text.alignment = .center
            text.textColor = .white
            text.isSelectable = false
            text.wantsLayer = true
            addSubview(text)
        }
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .white.withAlphaComponent(0.65)
        guideLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        guideLabel.textColor = .systemTeal
        outline.strokeColor = NSColor.systemTeal.withAlphaComponent(0.9).cgColor
        outline.fillColor = nil
        outline.zPosition = 10
        outline.lineWidth = 1
        outline.lineDashPattern = [6, 4]
        layer?.addSublayer(outline)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func font(for style: Style) -> NSFont {
        let size = style.fontSize
        switch style.fontFamily {
        case "system": return .systemFont(ofSize: size, weight: .semibold)
        case "rounded":
            let descriptor = NSFont.systemFont(ofSize: size, weight: .semibold).fontDescriptor.withDesign(.rounded)
            return descriptor.flatMap { NSFont(descriptor: $0, size: size) } ?? .systemFont(ofSize: size)
        case "monospaced": return .monospacedSystemFont(ofSize: size, weight: .medium)
        case "serif":
            let descriptor = NSFont.systemFont(ofSize: size, weight: .medium).fontDescriptor.withDesign(.serif)
            return descriptor.flatMap { NSFont(descriptor: $0, size: size) } ?? .systemFont(ofSize: size)
        default:
            let family = style.fontFamily.hasPrefix("family:") ? String(style.fontFamily.dropFirst(7)) : style.fontFamily
            return NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
                ?? .systemFont(ofSize: size, weight: .semibold)
        }
    }

    func render(text: String?, track: String, style: Style, appearing: Bool = false) {
        let newText = text ?? ""
        let effectChanged = style.animation != lastStyle?.animation || style.animationDuration != lastStyle?.animationDuration
        let changed = newText != fullText || appearing || effectChanged
        let needsLayout = changed || style != lastStyle || bounds.size != lastSize
        let previousDisplay = label.stringValue
        if needsLayout {
            label.font = Self.font(for: style)
            // Measure the final string, not a partially revealed typewriter prefix.
            label.stringValue = newText
            label.maximumNumberOfLines = 0
            let innerWidth = max(1, bounds.width - 32)
            let footer: CGFloat = style.showTrack ? 38 : 20
            let maxHeight = max(1, bounds.height - footer)
            let measured = label.sizeThatFits(NSSize(width: innerWidth, height: 10000)).height
            let lineHeight = ceil((label.font?.ascender ?? 22) - (label.font?.descender ?? -5) + (label.font?.leading ?? 0))
            // Only reserve complete lines; the maximum box never clips a half line.
            let available = max(lineHeight, floor(maxHeight / lineHeight) * lineHeight)
            let labelHeight = min(max(measured, lineHeight), min(maxHeight, available))
            let height = min(bounds.height, labelHeight + footer)
            let bottom = bounds.height - height
            background.frame = NSRect(x: 0, y: bottom, width: bounds.width, height: height)
            label.frame = NSRect(x: 16, y: bottom + (style.showTrack ? 28 : 10), width: innerWidth, height: labelHeight)
            caption.frame = NSRect(x: 16, y: bottom + 8, width: innerWidth, height: 16)
            label.maximumNumberOfLines = max(1, Int(floor(labelHeight / lineHeight)))
            caption.isHidden = !style.showTrack || newText.isEmpty
            label.isHidden = newText.isEmpty
            background.isHidden = !style.backgroundEnabled || newText.isEmpty || style.backgroundOpacity == 0
            background.layer?.backgroundColor = NSColor.black.withAlphaComponent(style.backgroundOpacity).cgColor
            // Keep text legible on a fully transparent background.
            for textField in [label, caption] {
                textField.layer?.shadowColor = NSColor.black.cgColor
                textField.layer?.shadowOpacity = 0.8
                textField.layer?.shadowRadius = 3
                textField.layer?.shadowOffset = CGSize(width: 0, height: -1)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            outline.frame = bounds
            outline.path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: 14, cornerHeight: 14, transform: nil)
            outline.isHidden = !style.showBounds
            CATransaction.commit()
            guideLabel.isHidden = !style.showBounds || (!newText.isEmpty && bottom < 22)
            guideLabel.stringValue = "MAX LYRIC AREA · \(Int(bounds.width)) × \(Int(bounds.height)) pt"
            guideLabel.frame = NSRect(x: 12, y: 3, width: max(1, bounds.width - 24), height: 14)
            if !changed, typingTimer != nil { label.stringValue = previousDisplay }
        }
        caption.stringValue = track
        lastStyle = style
        lastSize = bounds.size
        guard changed else { return }
        cancelAnimation()
        fullText = newText
        label.stringValue = newText
        guard !newText.isEmpty, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        animate(style)
    }

    func cancelAnimation() {
        typingTimer?.invalidate(); typingTimer = nil
        label.layer?.removeAllAnimations()
        label.stringValue = fullText
    }

    private func animate(_ style: Style) {
        guard style.animation != "none" else { return }
        let duration = max(0.1, style.animationDuration)
        if style.animation == "typewriter" {
            let characters = Array(fullText) // Unicode graphemes, including emoji and accents.
            let start = Date()
            label.stringValue = ""
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                MainActor.assumeIsolated {
                    let progress = min(1, max(0, Date().timeIntervalSince(start) / duration))
                    self.label.stringValue = String(characters.prefix(Int(ceil(progress * Double(characters.count)))))
                    if progress >= 1 { self.typingTimer?.invalidate(); self.typingTimer = nil }
                }
            }
            typingTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            return
        }
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0
        opacity.toValue = 1
        var effects: [CAAnimation] = [opacity]
        if style.animation == "slide" {
            let slide = CABasicAnimation(keyPath: "transform.translation.y")
            slide.fromValue = -10
            slide.toValue = 0
            effects.append(slide)
        } else if style.animation == "pop" {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.94
            scale.toValue = 1
            effects.append(scale)
        }
        let group = CAAnimationGroup()
        group.animations = effects
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        label.layer?.add(group, forKey: "lyricAppearance")
    }
}
