import Foundation

/// ScreenLyrics' timestamp lookup, extended for repeated timestamps and LRC offsets.
public struct LyricLine: Equatable, Sendable {
    public let timestamp: Double
    public let text: String
}

public enum LRC {
    public static func parse(_ source: String) -> [LyricLine] {
        let stamp = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        let offset = try! NSRegularExpression(pattern: #"(?i)\[offset:([+-]?\d+)\]"#)
        let ns = source as NSString
        let offsetMatch = offset.firstMatch(in: source, range: NSRange(location: 0, length: ns.length))
        let shift = offsetMatch.flatMap { Double(ns.substring(with: $0.range(at: 1))) }.map { $0 / 1000 } ?? 0
        var result: [LyricLine] = []
        for line in source.components(separatedBy: .newlines) {
            let text = line as NSString
            let matches = stamp.matches(in: line, range: NSRange(location: 0, length: text.length))
            guard let last = matches.last else { continue }
            let words = text.substring(from: NSMaxRange(last.range)).trimmingCharacters(in: .whitespaces)
            for match in matches {
                guard let minutes = Double(text.substring(with: match.range(at: 1))),
                      let seconds = Double(text.substring(with: match.range(at: 2))), seconds < 60 else { continue }
                result.append(LyricLine(timestamp: minutes * 60 + seconds - shift, text: words))
            }
        }
        return result.sorted { $0.timestamp < $1.timestamp }
    }

    /// Positive adjustment advances the lyrics; negative adjustment delays them.
    public static func line(in lines: [LyricLine], position: Double, adjustment: Double) -> String? {
        guard position.isFinite, adjustment.isFinite else { return nil }
        let time = position + adjustment
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].timestamp <= time { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0, !lines[lo - 1].text.isEmpty else { return nil }
        return lines[lo - 1].text
    }
}
