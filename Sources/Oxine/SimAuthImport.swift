import Foundation
import CryptoKit
import CommonCrypto

enum SimAuthImport {
    static let service = "SimAuth"
    static let keyAccount = "encryption_key"
    static let dataAccount = "accounts_data"

    enum ImportError: Error, CustomStringConvertible {
        case noData
        case noKey
        case badKey
        case badToken
        case hmacMismatch
        case decryptFailed
        case badJSON

        var description: String {
            switch self {
            case .noData: return "No SimAuth account data found in the keychain."
            case .noKey: return "SimAuth encryption key not found in the keychain."
            case .badKey: return "SimAuth encryption key is malformed."
            case .badToken: return "SimAuth data is not a valid Fernet token."
            case .hmacMismatch: return "SimAuth data failed integrity verification."
            case .decryptFailed: return "Could not decrypt SimAuth data."
            case .badJSON: return "Decrypted SimAuth data was not valid JSON."
            }
        }
    }

    static func isAvailable() -> Bool {
        Keychain.get(service: service, account: dataAccount) != nil
            && Keychain.get(service: service, account: keyAccount) != nil
    }

    static func loadAccounts() throws -> [Account] {
        guard let keyData = Keychain.get(service: service, account: keyAccount),
              let keyStr = String(data: keyData, encoding: .utf8) else { throw ImportError.noKey }
        guard let storedData = Keychain.get(service: service, account: dataAccount),
              let stored = String(data: storedData, encoding: .utf8) else { throw ImportError.noData }

        guard let keyBytes = base64urlDecode(keyStr.trimmingCharacters(in: .whitespacesAndNewlines)),
              keyBytes.count == 32 else { throw ImportError.badKey }
        let signingKey = keyBytes.prefix(16)
        let aesKey = keyBytes.suffix(16)

        let token: String
        if let colon = stored.firstIndex(of: ":") {
            token = String(stored[stored.index(after: colon)...])
        } else {
            token = stored
        }

        let plaintext = try fernetDecrypt(token: token, signingKey: Data(signingKey), aesKey: Data(aesKey))

        guard let json = try? JSONSerialization.jsonObject(with: plaintext) as? [[String: Any]] else {
            throw ImportError.badJSON
        }

        return json.compactMap { dict in
            guard let secret = dict["secret"] as? String, !secret.isEmpty else { return nil }
            return Account(
                issuer: (dict["issuer"] as? String) ?? "",
                account: (dict["account"] as? String) ?? "",
                secret: secret.uppercased()
            )
        }
    }

    private static func fernetDecrypt(token: String, signingKey: Data, aesKey: Data) throws -> Data {
        guard let raw = base64urlDecode(token), raw.count > 1 + 8 + 16 + 32 else {
            throw ImportError.badToken
        }
        let bytes = [UInt8](raw)
        guard bytes[0] == 0x80 else { throw ImportError.badToken }

        let hmacStart = bytes.count - 32
        let signed = Data(bytes[0..<hmacStart])
        let providedHMAC = Data(bytes[hmacStart...])

        let computed = Data(HMAC<SHA256>.authenticationCode(for: signed, using: SymmetricKey(data: signingKey)))
        guard computed == providedHMAC else { throw ImportError.hmacMismatch }

        let iv = Data(bytes[9..<25])
        let ciphertext = Data(bytes[25..<hmacStart])

        guard let plaintext = aesCBCDecrypt(ciphertext: ciphertext, key: aesKey, iv: iv) else {
            throw ImportError.decryptFailed
        }
        return plaintext
    }

    private static func aesCBCDecrypt(ciphertext: Data, key: Data, iv: Data) -> Data? {
        var out = Data(count: ciphertext.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            ciphertext.withUnsafeBytes { ctPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(kCCDecrypt),
                                CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, key.count,
                                ivPtr.baseAddress,
                                ctPtr.baseAddress, ciphertext.count,
                                outPtr.baseAddress, outCapacity,
                                &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.removeSubrange(moved..<out.count)
        return out
    }

    private static func base64urlDecode(_ s: String) -> Data? {
        var str = s.replacingOccurrences(of: "-", with: "+")
                   .replacingOccurrences(of: "_", with: "/")
        let pad = str.count % 4
        if pad > 0 { str += String(repeating: "=", count: 4 - pad) }
        return Data(base64Encoded: str)
    }
}
