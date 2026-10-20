import Foundation

/// Decides whether a copied string looks like a secret, so the clipboard
/// history shows it veiled. Copies marked concealed are secret regardless;
/// this catches plain copies of keys, tokens and generated passwords.
enum SecretDetector {
    static func looksSecret(_ text: String) -> Bool {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 20_000 else { return false }
        if s.contains("-----BEGIN"), s.contains("PRIVATE KEY") { return true }
        let lower = s.lowercased()
        if lower.hasPrefix("otpauth://") || lower.hasPrefix("otpauth-migration://") { return true }
        if matches(s, credentialsURL) { return true }
        // Everything below is a single token.
        guard !s.contains(where: \.isWhitespace) else { return false }
        if tokenPatterns.contains(where: { matches(s, $0) }) { return true }
        return looksGenerated(s)
    }

    /// A URL with a password in it: `postgres://user:pass@host/db`.
    private static let credentialsURL = regex(#"^[A-Za-z][A-Za-z0-9+.-]*://[^/\s:@]+:[^/\s@]+@\S"#)

    /// Known key and token formats, matched against the whole string.
    private static let tokenPatterns: [NSRegularExpression] = [
        #"sk-[A-Za-z0-9_-]{20,}"#,                     // OpenAI, Anthropic
        #"gh[pousr]_[A-Za-z0-9]{30,}"#,                // GitHub
        #"github_pat_[A-Za-z0-9_]{40,}"#,
        #"glpat-[A-Za-z0-9_-]{20,}"#,                  // GitLab
        #"xox[abposr]-[A-Za-z0-9-]{10,}"#,             // Slack
        #"(AKIA|ASIA)[0-9A-Z]{16}"#,                   // AWS access key
        #"AIza[0-9A-Za-z_-]{35}"#,                     // Google API key
        #"[rs]k_(live|test)_[0-9A-Za-z]{20,}"#,        // Stripe
        #"SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}"#, // SendGrid
        #"npm_[A-Za-z0-9]{36}"#,
        #"hf_[A-Za-z0-9]{30,}"#,                       // Hugging Face
        #"xai-[A-Za-z0-9]{40,}"#,
        #"dop_v1_[a-f0-9]{64}"#,                       // DigitalOcean
        #"shp(at|ss|ca|pa)_[a-fA-F0-9]{32}"#,          // Shopify
        #"AGE-SECRET-KEY-1[0-9A-Z]{58}"#,
        #"eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#, // JWT
    ].map { regex("^(\($0))$") }

    private static let email = regex(#"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$"#)
    private static let uuid = regex(#"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#)
    /// Apple Passwords' generated style: `kufxyz-8ditbo-Puqsoh`.
    private static let applePassword = regex(#"^[A-Za-z0-9]{6}-[A-Za-z0-9]{6}-[A-Za-z0-9]{6}$"#)

    /// A generated password: 12–128 characters with both cases, a digit or a
    /// symbol, and frequent switches between those kinds. Code identifiers,
    /// version strings and dates switch rarely or lack one case.
    private static func looksGenerated(_ s: String) -> Bool {
        guard (12...128).contains(s.count),
              !s.contains("/"), !s.contains("\\"),
              !matches(s, email), !matches(s, uuid) else { return false }
        let hasLower = s.contains(where: \.isLowercase)
        let hasUpper = s.contains(where: \.isUppercase)
        let hasDigit = s.contains(where: \.isNumber)
        let hasSymbol = s.contains { !$0.isLetter && !$0.isNumber }
        guard hasLower, hasUpper, hasDigit || hasSymbol else { return false }
        if matches(s, applePassword) { return hasDigit }
        func kind(_ c: Character) -> Int { c.isLowercase ? 0 : c.isUppercase ? 1 : c.isNumber ? 2 : 3 }
        let kinds = s.map(kind)
        let switches = zip(kinds, kinds.dropFirst()).filter { $0 != $1 }.count
        return Double(switches) / Double(kinds.count - 1) >= 0.45
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants; a typo should fail loudly in development.
        try! NSRegularExpression(pattern: pattern)
    }

    private static func matches(_ s: String, _ re: NSRegularExpression) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}
