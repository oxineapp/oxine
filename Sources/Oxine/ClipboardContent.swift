import SwiftUI
import AppKit

/// What a clipboard item holds, for its tile, its filter chip and how its
/// opened view lays out. Secrets are a flag on the item, on top of this.
enum ClipKind {
    case text, link, code, color

    /// Worked out once per item when it's created.
    static func classify(_ content: String) -> ClipKind {
        let t = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if ClipColor.parse(t) != nil { return .color }
        if isLink(t) { return .link }
        if looksLikeCode(t) { return .code }
        return .text
    }

    static func summarize(_ content: String) -> (firstLine: String, lineCount: Int) {
        let lines = content.split(whereSeparator: \.isNewline)
        let first = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? Substring(content)
        return (first.trimmingCharacters(in: .whitespaces), max(lines.count, 1))
    }

    var label: String {
        switch self {
        case .text:  return "Text"
        case .link:  return "Link"
        case .code:  return "Code"
        case .color: return "Color"
        }
    }

    var icon: String {
        switch self {
        case .text:  return "text.alignleft"
        case .link:  return "globe"
        case .code:  return "apple.terminal"
        case .color: return "paintpalette"
        }
    }

    private static func isLink(_ t: String) -> Bool {
        guard !t.contains(where: \.isWhitespace) else { return false }
        if let url = URL(string: t), let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme), url.host != nil { return true }
        return t.lowercased().hasPrefix("www.") && t.contains(".")
    }

    /// Shell commands whose first word isn't also an English word.
    private static let commands: Set<String> = [
        "sudo", "git", "cd", "ls", "rm", "mv", "cp", "mkdir", "chmod", "chown", "grep", "sed", "awk",
        "npm", "npx", "pnpm", "yarn", "brew", "swift", "xcodebuild", "xcrun", "curl", "wget", "ssh", "scp",
        "docker", "kubectl", "python3", "pip", "pip3", "node", "cargo", "rustc", "defaults", "launchctl",
        "codesign", "export", "tailscale", "headscale", "gh", "killall", "pkill", "osascript",
    ]

    private static func looksLikeCode(_ t: String) -> Bool {
        let firstLine = t.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? t
        let firstWord = firstLine.split(separator: " ").first.map(String.init) ?? ""
        if commands.contains(firstWord) || firstWord.hasPrefix("./") { return true }

        // A path: one token with a slash and a file name or a known root.
        if !t.contains(where: \.isWhitespace), t.contains("/"), !t.contains("://") {
            if t.hasPrefix("/") || t.hasPrefix("~/") || t.hasPrefix("../") { return true }
            if t.range(of: #"\.[A-Za-z]{1,6}(:\d+)?$"#, options: .regularExpression) != nil { return true }
        }

        var score = 0
        if t.contains("{") && t.contains("}") { score += 2 }
        if t.range(of: #"(=>|->|::|==|!=|&&|\|\||\$\(|\$\{)"#, options: .regularExpression) != nil { score += 2 }
        if t.range(of: #";\s*$"#, options: [.regularExpression, .anchored]) != nil
            || t.range(of: #";\n"#, options: .regularExpression) != nil { score += 2 }
        if t.range(of: #"\b(func|let|var|const|def|class|import|return|struct|enum|fn|impl|public|private)\b"#,
                   options: .regularExpression) != nil { score += 1 }
        if t.contains("\n"), t.range(of: #"\n(\t|  )\S"#, options: .regularExpression) != nil { score += 1 }
        if t.range(of: #"\w\([^)]*\)"#, options: .regularExpression) != nil { score += 1 }
        return score >= 3
    }
}

/// A copied color: `#RGB`, `#RRGGBB`, `#RRGGBBAA` or `rgb()`/`rgba()`.
struct ClipColor {
    let red, green, blue: Double

    var color: Color { Color(red: red, green: green, blue: blue) }

    /// WCAG relative luminance.
    var luminance: Double { ClipColor.luminance(red, green, blue) }

    static func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    static func parse(_ s: String) -> ClipColor? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("#") {
            var hex = String(t.dropFirst())
            guard [3, 6, 8].contains(hex.count), hex.allSatisfy(\.isHexDigit) else { return nil }
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard let v = UInt64(hex.prefix(6), radix: 16) else { return nil }
            return ClipColor(red: Double((v >> 16) & 0xFF) / 255,
                             green: Double((v >> 8) & 0xFF) / 255,
                             blue: Double(v & 0xFF) / 255)
        }
        let lower = t.lowercased()
        guard lower.hasPrefix("rgb(") || lower.hasPrefix("rgba("), lower.hasSuffix(")"),
              let open = lower.firstIndex(of: "(") else { return nil }
        let parts = lower[lower.index(after: open)..<lower.index(before: lower.endIndex)]
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            .compactMap { Double($0) }
        guard parts.count >= 3, parts.prefix(3).allSatisfy({ (0...255).contains($0) }) else { return nil }
        return ClipColor(red: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255)
    }
}

extension ClipboardItem {
    /// A link split for display: host first, then the path. The query and
    /// fragment only show when the row is opened.
    var linkParts: (host: String, path: String, hasMore: Bool)? {
        guard kind == .link else { return nil }
        let raw = content.lowercased().hasPrefix("www.") ? "https://" + content : content
        guard let url = URL(string: raw), let host = url.host else { return nil }
        let shortHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = url.path == "/" ? "" : url.path
        return (shortHost, path, url.query != nil || url.fragment != nil)
    }

    var clipColor: ClipColor? { kind == .color ? ClipColor.parse(content) : nil }

    /// "now", "12m", "3h", "2d", "5w".
    var age: String {
        let s = Date().timeIntervalSince(timestamp)
        switch s {
        case ..<60:      return "now"
        case ..<3600:    return "\(Int(s / 60))m"
        case ..<86400:   return "\(Int(s / 3600))h"
        case ..<604800:  return "\(Int(s / 86400))d"
        default:         return "\(Int(s / 604800))w"
        }
    }

    /// The app it was copied in, or what it is for items saved before that
    /// was recorded; plus the line count for multi-line copies.
    var subtitle: String {
        let origin = sourceApp ?? (isSecret ? "Secret" : kind.label)
        let lines = lineCount
        return lines > 1 ? "\(origin) · \(lines) lines" : origin
    }
}

/// Text or ink that reads on top of a tile's own color: the accent unless the
/// tile is close to it, then dark ink on a light tile or white on a dark one.
struct ContrastInk {
    let foreground: Color
    let fill: Color
    let ring: Color

    @MainActor static func copied(on tile: ClipColor?) -> ContrastInk {
        let accent = Color.panelAccent
        // Untinted tiles sit on the dark panel glass.
        let surface = tile?.luminance ?? 0.018
        let a = NSColor(accent).usingColorSpace(.sRGB).map {
            ClipColor.luminance($0.redComponent, $0.greenComponent, $0.blueComponent)
        } ?? 0.6
        let contrast = (max(a, surface) + 0.05) / (min(a, surface) + 0.05)
        if contrast >= 3 {
            return ContrastInk(foreground: accent, fill: accent.opacity(0.16), ring: accent)
        }
        return surface > 0.4
            ? ContrastInk(foreground: Color(red: 0.03, green: 0.13, blue: 0.17), fill: .black.opacity(0.12),
                          ring: Color(red: 0.03, green: 0.13, blue: 0.17).opacity(0.75))
            : ContrastInk(foreground: .white, fill: .white.opacity(0.16), ring: .white.opacity(0.85))
    }
}
