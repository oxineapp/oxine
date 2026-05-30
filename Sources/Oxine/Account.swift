import Foundation

struct Account: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var issuer: String
    var account: String
    var secret: String
    var digits: Int = 6
    var period: Int = 30
    var algorithm: String = "SHA1"

    var label: String {
        if !issuer.isEmpty && !account.isEmpty { return "\(issuer) (\(account))" }
        if !issuer.isEmpty { return issuer }
        return account.isEmpty ? "Unnamed" : account
    }

    var totp: TOTP? {
        TOTP(secret: secret,
             digits: digits,
             period: period,
             algorithm: TOTP.Algorithm(rawValue: algorithm.uppercased()) ?? .sha1)
    }
}

extension Account {
    static func from(uri: String) -> Account? {
        guard let comps = URLComponents(string: uri),
              comps.scheme?.lowercased() == "otpauth",
              comps.host?.lowercased() == "totp" else { return nil }

        let query = comps.queryItems ?? []
        func q(_ name: String) -> String? { query.first { $0.name == name }?.value }

        guard let secret = q("secret"), Base32.isValid(secret) else { return nil }

        var label = comps.path
        if label.hasPrefix("/") { label.removeFirst() }
        label = label.removingPercentEncoding ?? label

        var issuer = q("issuer") ?? ""
        var accountName = label
        if let colon = label.firstIndex(of: ":") {
            if issuer.isEmpty { issuer = String(label[..<colon]).trimmingCharacters(in: .whitespaces) }
            accountName = String(label[label.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }

        let digits = Int(q("digits") ?? "") ?? 6
        let period = Int(q("period") ?? "") ?? 30
        let algo = (q("algorithm") ?? "SHA1").uppercased()

        return Account(issuer: issuer,
                       account: accountName,
                       secret: secret.uppercased(),
                       digits: digits,
                       period: period,
                       algorithm: algo)
    }
}
