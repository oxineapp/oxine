import Foundation
import CryptoKit

enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func decode(_ input: String) -> Data? {
        let cleaned = input
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .uppercased()
            .replacingOccurrences(of: "=", with: "")
        if cleaned.isEmpty { return nil }

        var lookup = [Character: UInt8]()
        for (i, c) in alphabet.enumerated() { lookup[c] = UInt8(i) }

        var bits = 0
        var value = 0
        var out = Data()
        for ch in cleaned {
            guard let v = lookup[ch] else { return nil }
            value = (value << 5) | Int(v)
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((value >> bits) & 0xFF))
            }
        }
        return out
    }

    static func isValid(_ input: String) -> Bool {
        guard let data = decode(input), data.count >= 10 else { return false }
        return true
    }

    /// Encode raw bytes to (unpadded, upper-case) Base32 — used to turn the raw
    /// secret bytes from a Google Authenticator migration payload back into the
    /// Base32 text the rest of the app stores.
    static func encode(_ data: Data) -> String {
        if data.isEmpty { return "" }
        var output = ""
        var value = 0
        var bits = 0
        for byte in data {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                output.append(alphabet[(value >> bits) & 0x1F])
            }
            value &= (1 << bits) - 1   // keep only leftover low bits (no overflow)
        }
        if bits > 0 {
            output.append(alphabet[(value << (5 - bits)) & 0x1F])
        }
        return output
    }
}

struct TOTP {
    enum Algorithm: String {
        case sha1 = "SHA1"
        case sha256 = "SHA256"
        case sha512 = "SHA512"
    }

    let secret: Data
    let digits: Int
    let period: Int
    let algorithm: Algorithm

    init?(secret base32: String, digits: Int = 6, period: Int = 30, algorithm: Algorithm = .sha1) {
        guard let data = Base32.decode(base32) else { return nil }
        self.secret = data
        self.digits = digits
        self.period = period
        self.algorithm = algorithm
    }

    func code(at date: Date = Date()) -> String {
        let counter = UInt64(date.timeIntervalSince1970) / UInt64(period)
        var bigEndian = counter.bigEndian
        let counterData = Data(bytes: &bigEndian, count: 8)
        let key = SymmetricKey(data: secret)

        let digest: Data
        switch algorithm {
        case .sha1:
            digest = Data(HMAC<Insecure.SHA1>.authenticationCode(for: counterData, using: key))
        case .sha256:
            digest = Data(HMAC<SHA256>.authenticationCode(for: counterData, using: key))
        case .sha512:
            digest = Data(HMAC<SHA512>.authenticationCode(for: counterData, using: key))
        }

        let offset = Int(digest[digest.count - 1] & 0x0F)
        let binary = (Int(digest[offset] & 0x7F) << 24)
            | (Int(digest[offset + 1]) << 16)
            | (Int(digest[offset + 2]) << 8)
            | Int(digest[offset + 3])

        let otp = binary % Int(pow(10.0, Double(digits)))
        return String(format: "%0\(digits)d", otp)
    }

    func secondsRemaining(at date: Date = Date()) -> Int {
        period - (Int(date.timeIntervalSince1970) % period)
    }

    func progress(at date: Date = Date()) -> Double {
        Double(period - secondsRemaining(at: date)) / Double(period)
    }
}
