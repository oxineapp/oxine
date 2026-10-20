import SwiftUI
import AppKit
import PanelKit

/// Plain-text Markdown editing with the marks styled as you type, lists that
/// carry on when you press Return, and shortcuts with no buttons: ⌘B bold,
/// ⌘I italic, ⌘E code, ⌘K link, ⇧⌘X strikethrough, ⇧⌘L checklist. ⌘↩ submits.
/// The file stays plain Markdown; the styling is only on screen.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder = ""
    var fontSize: CGFloat = 13
    var inset = NSSize(width: 11, height: 9)
    /// Height of the text plus insets, for callers whose frame grows with it.
    var onHeight: (CGFloat) -> Void = { _ in }
    var onFocus: (Bool) -> Void = { _ in }
    /// The text was clicked. Focus alone (as on panel open) doesn't count.
    var onClick: () -> Void = {}
    var onSubmit: () -> Void = {}
    /// Bump to put the cursor in the editor.
    var focusRequest = 0

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        let view = MarkdownTextView(usingTextLayoutManager: false)
        view.delegate = context.coordinator
        view.textStorage?.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.textContainerInset = inset
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.font = .systemFont(ofSize: fontSize)
        view.typingAttributes = MarkdownStyle.base(size: fontSize)
        view.insertionPointColor = NSColor(Color.panelAccent)
        view.placeholder = placeholder
        context.coordinator.attach(view)
        view.string = text

        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let view = coordinator.textView else { return }
        if view.string != text {
            view.string = text
            view.needsDisplay = true
            coordinator.reportHeight()
        }
        view.placeholder = placeholder
        if focusRequest != coordinator.focusRequest {
            coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: MarkdownEditor
        weak var textView: MarkdownTextView?
        var focusRequest = 0
        private var lastHeight: CGFloat = -1

        init(_ parent: MarkdownEditor) {
            self.parent = parent
            self.focusRequest = parent.focusRequest
        }

        func attach(_ view: MarkdownTextView) {
            textView = view
            view.onFocus = { [weak self] in self?.parent.onFocus($0) }
            view.onClick = { [weak self] in self?.parent.onClick() }
            view.onSubmit = { [weak self] in self?.parent.onSubmit() }
            view.onResize = { [weak self] in self?.reportHeight() }
        }

        func textDidChange(_ notification: Notification) {
            guard let view = textView else { return }
            parent.text = view.string
            reportHeight()
        }

        nonisolated func textStorage(_ storage: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions,
                                     range: NSRange, changeInLength delta: Int) {
            guard mask.contains(.editedCharacters) else { return }
            // The storage is the text view's own, edited on the main thread.
            MainActor.assumeIsolated {
                guard let own = textView?.textStorage else { return }
                MarkdownStyle.apply(to: own, size: parent.fontSize)
            }
        }

        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                    parent.onSubmit()
                    return true
                }
                return MarkdownCommands.continueList(in: view)
            case #selector(NSResponder.insertTab(_:)):
                return MarkdownCommands.indent(in: view, outdent: false)
            case #selector(NSResponder.insertBacktab(_:)):
                return MarkdownCommands.indent(in: view, outdent: true)
            default:
                return false
            }
        }

        func reportHeight() {
            guard let view = textView, let layout = view.layoutManager, let container = view.textContainer else { return }
            layout.ensureLayout(for: container)
            let height = ceil(layout.usedRect(for: container).height + view.textContainerInset.height * 2)
            guard abs(height - lastHeight) > 0.5 else { return }
            lastHeight = height
            let report = parent.onHeight
            DispatchQueue.main.async { report(height) }
        }
    }
}

/// The text view behind `MarkdownEditor`: draws the placeholder, reports
/// focus, clicks and size, and takes the formatting shortcuts.
final class MarkdownTextView: NSTextView {
    var placeholder = "" { didSet { if placeholder != oldValue { needsDisplay = true } } }
    var onFocus: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    var onSubmit: (() -> Void)?
    var onResize: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocus?(false) }
        return resigned
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
        super.mouseDown(with: event)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?()
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.white.withAlphaComponent(0.42),
        ]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
                             y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command, event.keyCode == 36 || event.keyCode == 76 {
            onSubmit?()
            return true
        }
        if flags == .command {
            switch key {
            case "b": MarkdownCommands.wrap(self, "**"); return true
            case "i": MarkdownCommands.wrap(self, "*"); return true
            case "e": MarkdownCommands.wrap(self, "`"); return true
            case "k": MarkdownCommands.link(self); return true
            // The panel has no Edit menu to send these.
            case "z": undoManager?.undo(); return true
            case "a": selectAll(nil); return true
            case "c": copy(nil); return true
            case "x": cut(nil); return true
            case "v": pasteAsPlainText(nil); return true
            default: break
            }
        }
        if flags == [.command, .shift] {
            switch key {
            case "x": MarkdownCommands.wrap(self, "~~"); return true
            case "l": MarkdownCommands.toggleChecklist(self); return true
            case "z": undoManager?.redo(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Edits the shortcuts and Return make, each one step on the undo stack.
@MainActor enum MarkdownCommands {
    private static let listItem = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+] \[[ xX]\] |[-*+] |(\d+)([.)]) )(.*)$"#)

    static func replace(_ view: NSTextView, _ range: NSRange, with text: String, select: NSRange? = nil) {
        guard view.shouldChangeText(in: range, replacementString: text) else { return }
        view.textStorage?.replaceCharacters(in: range, with: text)
        view.didChangeText()
        view.setSelectedRange(select ?? NSRange(location: range.location + (text as NSString).length, length: 0))
    }

    /// Puts marks around the selection, or takes them off if they're there.
    /// With nothing selected, the cursor lands between them.
    static func wrap(_ view: NSTextView, _ mark: String) {
        let ns = view.string as NSString
        let sel = view.selectedRange()
        let m = (mark as NSString).length
        if sel.location >= m, NSMaxRange(sel) + m <= ns.length,
           ns.substring(with: NSRange(location: sel.location - m, length: m)) == mark,
           ns.substring(with: NSRange(location: NSMaxRange(sel), length: m)) == mark {
            replace(view, NSRange(location: sel.location - m, length: sel.length + 2 * m),
                    with: ns.substring(with: sel),
                    select: NSRange(location: sel.location - m, length: sel.length))
            return
        }
        replace(view, sel, with: mark + ns.substring(with: sel) + mark,
                select: NSRange(location: sel.location + m, length: sel.length))
    }

    /// `[selection]()` with the cursor in the parentheses, or `[](url)` when
    /// a link is selected.
    static func link(_ view: NSTextView) {
        let sel = view.selectedRange()
        let inner = (view.string as NSString).substring(with: sel)
        if inner.hasPrefix("http://") || inner.hasPrefix("https://") {
            replace(view, sel, with: "[](\(inner))", select: NSRange(location: sel.location + 1, length: 0))
        } else {
            let length = (inner as NSString).length
            replace(view, sel, with: "[\(inner)]()", select: NSRange(location: sel.location + length + 3, length: 0))
        }
    }

    /// Turns the selected lines into checklist items, or back into plain lines.
    static func toggleChecklist(_ view: NSTextView) {
        let ns = view.string as NSString
        let range = ns.lineRange(for: view.selectedRange())
        let block = ns.substring(with: range)
        let trailingNewline = block.hasSuffix("\n")
        let lines = (trailingNewline ? String(block.dropLast()) : block).components(separatedBy: "\n")
        let allChecks = lines.allSatisfy { $0.range(of: #"^\s*[-*+] \[[ xX]\] "#, options: .regularExpression) != nil }
        let changed = lines.map { line -> String in
            if allChecks {
                return line.replacingOccurrences(of: #"^(\s*)[-*+] \[[ xX]\] "#, with: "$1", options: .regularExpression)
            }
            if line.range(of: #"^\s*[-*+] \[[ xX]\] "#, options: .regularExpression) != nil { return line }
            if line.range(of: #"^\s*[-*+] "#, options: .regularExpression) != nil {
                return line.replacingOccurrences(of: #"^(\s*)[-*+] "#, with: "$1- [ ] ", options: .regularExpression)
            }
            return line.replacingOccurrences(of: #"^(\s*)"#, with: "$1- [ ] ", options: .regularExpression)
        }
        let text = changed.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        let end = range.location + (text as NSString).length - (trailingNewline ? 1 : 0)
        replace(view, range, with: text, select: NSRange(location: end, length: 0))
    }

    /// Return in a list item starts the next one (an unticked box after a
    /// checklist item, the next number after a numbered one). Return on an
    /// empty item ends the list.
    static func continueList(in view: NSTextView) -> Bool {
        let ns = view.string as NSString
        let sel = view.selectedRange()
        guard sel.length == 0 else { return false }
        var lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        if NSMaxRange(lineRange) > 0, lineRange.length > 0,
           ns.substring(with: NSRange(location: NSMaxRange(lineRange) - 1, length: 1)) == "\n" {
            lineRange.length -= 1
        }
        let line = ns.substring(with: lineRange)
        let lineNS = line as NSString
        guard let match = listItem.firstMatch(in: line, range: NSRange(location: 0, length: lineNS.length)) else { return false }
        let indent = lineNS.substring(with: match.range(at: 1))
        let marker = lineNS.substring(with: match.range(at: 2))
        let rest = lineNS.substring(with: match.range(at: 5))
        let markerEnd = lineRange.location + match.range(at: 2).location + match.range(at: 2).length
        guard sel.location >= markerEnd else { return false }

        if rest.trimmingCharacters(in: .whitespaces).isEmpty {
            replace(view, lineRange, with: "", select: NSRange(location: lineRange.location, length: 0))
            return true
        }
        var next = marker
        if match.range(at: 3).location != NSNotFound, let n = Int(lineNS.substring(with: match.range(at: 3))) {
            next = "\(n + 1)\(lineNS.substring(with: match.range(at: 4))) "
        } else if marker.contains("[") {
            next = String(marker.prefix(1)) + " [ ] "
        }
        replace(view, sel, with: "\n" + indent + next)
        return true
    }

    /// Tab and ⇧Tab in a list item move it in and out by two spaces.
    static func indent(in view: NSTextView, outdent: Bool) -> Bool {
        let ns = view.string as NSString
        let sel = view.selectedRange()
        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let line = ns.substring(with: lineRange)
        guard listItem.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil else {
            return false
        }
        if outdent {
            let spaces = line.prefix(2).prefix { $0 == " " }.count
            guard spaces > 0 else { return true }
            replace(view, NSRange(location: lineRange.location, length: spaces), with: "",
                    select: NSRange(location: max(sel.location - spaces, lineRange.location), length: 0))
        } else {
            replace(view, NSRange(location: lineRange.location, length: 0), with: "  ",
                    select: NSRange(location: sel.location + 2, length: 0))
        }
        return true
    }
}

/// On-screen styling for Markdown text: headings larger, bold and italic
/// shown, code in mono, checklist boxes and bullets in the accent, and the
/// marks themselves dimmed.
@MainActor enum MarkdownStyle {
    static func base(size: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 2
        return [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            .paragraphStyle: paragraph,
        ]
    }

    private static let mark = NSColor.white.withAlphaComponent(0.3)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    private static let fence = regex(#"^```[^\n]*\n[\s\S]*?^```[^\n]*$"#)
    private static let heading = regex(#"^(#{1,6})[ \t]+.*$"#)
    private static let bold = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italic = regex(#"(?<![*_\w])([*_])(?=[^\s*_])(.+?)(?<=[^\s*_])\1(?![*_\w])"#)
    private static let code = regex(#"(`)([^`\n]+)(`)"#)
    private static let strike = regex(#"(~~)(?=\S)(.+?)(?<=\S)(~~)"#)
    private static let check = regex(#"^[ \t]*([-*+] \[([ xX])\])(.*)$"#)
    private static let bullet = regex(#"^[ \t]*([-*+]|\d+[.)])(?= )"#)
    private static let quote = regex(#"^(>)[ \t]?.*$"#)
    private static let link = regex(#"(\[)([^\]\n]+)(\]\()([^)\n]*)(\))"#)

    static func apply(to storage: NSTextStorage, size: CGFloat) {
        let text = storage.string
        let full = NSRange(location: 0, length: (text as NSString).length)
        guard full.length > 0 else { return }
        let accent = NSColor(Color.panelAccent)
        storage.setAttributes(base(size: size), range: full)

        func each(_ regex: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
            regex.enumerateMatches(in: text, range: full) { match, _, _ in if let match { body(match) } }
        }
        func dim(_ range: NSRange) {
            if range.location != NSNotFound { storage.addAttribute(.foregroundColor, value: mark, range: range) }
        }
        func trait(_ mask: NSFontTraitMask, _ range: NSRange) {
            storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                let font = (value as? NSFont) ?? .systemFont(ofSize: size)
                storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: mask), range: sub)
            }
        }

        each(heading) { m in
            let level = m.range(at: 1).length
            let bump: CGFloat = level == 1 ? 5 : level == 2 ? 3 : 1.5
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: size + bump, weight: .semibold), range: m.range)
            dim(m.range(at: 1))
        }
        each(bold) { m in
            trait(.boldFontMask, m.range)
            dim(NSRange(location: m.range.location, length: m.range(at: 1).length))
            dim(NSRange(location: NSMaxRange(m.range) - m.range(at: 1).length, length: m.range(at: 1).length))
        }
        each(italic) { m in
            trait(.italicFontMask, m.range)
            dim(m.range(at: 1))
            dim(NSRange(location: NSMaxRange(m.range) - 1, length: 1))
        }
        each(strike) { m in
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 2))
            storage.addAttribute(.foregroundColor, value: NSColor.white.withAlphaComponent(0.55), range: m.range(at: 2))
            dim(m.range(at: 1))
            dim(m.range(at: 3))
        }
        each(bullet) { m in
            storage.addAttribute(.foregroundColor, value: accent, range: m.range(at: 1))
        }
        each(check) { m in
            storage.addAttribute(.foregroundColor, value: accent, range: m.range(at: 1))
            let ticked = (text as NSString).substring(with: m.range(at: 2)) != " "
            if ticked {
                storage.addAttribute(.foregroundColor, value: NSColor.white.withAlphaComponent(0.45), range: m.range(at: 3))
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 3))
            }
        }
        each(quote) { m in
            storage.addAttribute(.foregroundColor, value: NSColor.white.withAlphaComponent(0.62), range: m.range)
            storage.addAttribute(.foregroundColor, value: accent, range: m.range(at: 1))
        }
        each(link) { m in
            storage.addAttribute(.foregroundColor, value: accent, range: m.range(at: 2))
            dim(m.range(at: 1))
            dim(m.range(at: 3))
            dim(m.range(at: 4))
            dim(m.range(at: 5))
        }
        let mono = NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular)
        each(code) { m in
            storage.addAttribute(.font, value: mono, range: m.range(at: 2))
            storage.addAttribute(.backgroundColor, value: NSColor.white.withAlphaComponent(0.08), range: m.range(at: 2))
            dim(m.range(at: 1))
            dim(m.range(at: 3))
        }
        each(fence) { m in
            storage.addAttribute(.font, value: mono, range: m.range)
            storage.addAttribute(.foregroundColor, value: NSColor.white.withAlphaComponent(0.85), range: m.range)
        }
    }
}
