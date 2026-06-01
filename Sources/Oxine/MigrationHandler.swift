import Foundation

/// Imports Google Authenticator exports — the `otpauth-migration://offline?data=…`
/// links its "Export accounts" QR codes encode. The `data` parameter is a
/// base64'd protobuf. The schema is tiny and well-known, so we decode the wire
/// format directly rather than pulling in a protobuf codegen toolchain.
///
/// Real schema (note: algorithm/digits/type are *enum varints*, and the secret
/// is raw *bytes* — not the strings the old stub assumed):
///   MigrationPayload { repeated OtpParameters otp_parameters = 1; … }
///   OtpParameters { bytes secret=1; string name=2; string issuer=3;
///                   Algorithm algorithm=4; DigitCount digits=5; OtpType type=6;
///                   int64 counter=7; }
enum MigrationHandler {
    static func parseMigrationURL(_ urlString: String) -> [Account]? {
        guard let comps = URLComponents(string: urlString),
              comps.scheme?.lowercased() == "otpauth-migration",
              let raw = comps.queryItems?.first(where: { $0.name == "data" })?.value
        else { return nil }
        // URLComponents already percent-decoded the value; '+' may have become a
        // space, so restore it before base64-decoding.
        let b64 = raw.replacingOccurrences(of: " ", with: "+")
        guard let data = Data(base64Encoded: b64) else { return nil }

        var reader = ProtoReader(data)
        var accounts: [Account] = []
        while let (field, wire) = reader.readTag() {
            if field == 1, wire == 2, let msg = reader.readBytes() {
                if let account = parseOtpParameters(msg) { accounts.append(account) }
            } else {
                reader.skip(wire)
            }
        }
        return accounts.isEmpty ? nil : accounts
    }

    private static func parseOtpParameters(_ data: Data) -> Account? {
        var reader = ProtoReader(data)
        var secret = Data()
        var name = "", issuer = "", algorithm = "SHA1"
        var digits = 6
        var isHOTP = false

        while let (field, wire) = reader.readTag() {
            switch (field, wire) {
            case (1, 2): secret = reader.readBytes() ?? Data()
            case (2, 2): name = reader.readString()
            case (3, 2): issuer = reader.readString()
            case (4, 0):
                switch reader.readVarint() {
                case 2: algorithm = "SHA256"
                case 3: algorithm = "SHA512"
                default: algorithm = "SHA1"   // 1 = SHA1, 0 = unspecified, 4 = MD5 (unsupported → SHA1)
                }
            case (5, 0): digits = reader.readVarint() == 2 ? 8 : 6   // 2 = eight, else six
            case (6, 0): isHOTP = reader.readVarint() == 1           // 1 = HOTP, 2 = TOTP
            default: reader.skip(wire)
            }
        }

        // This is a TOTP app; skip counter-based HOTP entries and empty secrets.
        guard !secret.isEmpty, !isHOTP else { return nil }

        // Some exports pack "Issuer:account" into the name with no separate issuer.
        var resolvedIssuer = issuer
        var resolvedAccount = name
        if resolvedIssuer.isEmpty, let colon = name.firstIndex(of: ":") {
            resolvedIssuer = String(name[..<colon]).trimmingCharacters(in: .whitespaces)
            resolvedAccount = String(name[name.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }

        return Account(issuer: resolvedIssuer,
                       account: resolvedAccount,
                       secret: Base32.encode(secret),
                       digits: digits,
                       period: 30,
                       algorithm: algorithm)
    }
}

/// Minimal protobuf wire-format reader (varints + length-delimited fields).
private struct ProtoReader {
    private let bytes: [UInt8]
    private var i = 0
    init(_ data: Data) { bytes = [UInt8](data) }

    mutating func readVarint() -> Int {
        var result = 0, shift = 0
        while i < bytes.count {
            let b = bytes[i]; i += 1
            result |= Int(b & 0x7F) << shift
            if b & 0x80 == 0 { break }
            shift += 7
            if shift > 63 { break }
        }
        return result
    }

    /// Returns (fieldNumber, wireType), or nil at end of input.
    mutating func readTag() -> (Int, Int)? {
        guard i < bytes.count else { return nil }
        let tag = readVarint()
        return (tag >> 3, tag & 0x7)
    }

    mutating func readBytes() -> Data? {
        let len = readVarint()
        guard len >= 0, i + len <= bytes.count else { return nil }
        defer { i += len }
        return Data(bytes[i..<i + len])
    }

    mutating func readString() -> String {
        guard let d = readBytes() else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }

    /// Advance past a field of the given wire type we don't care about.
    mutating func skip(_ wire: Int) {
        switch wire {
        case 0: _ = readVarint()
        case 1: i += 8
        case 2: _ = readBytes()
        case 5: i += 4
        default: i = bytes.count   // unknown wire type → stop
        }
    }
}
