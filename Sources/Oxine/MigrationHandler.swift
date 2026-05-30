import Foundation
import SwiftProtobuf

class MigrationHandler {
    static func parseMigrationURL(_ urlString: String) -> [Account]? {
        guard let url = URL(string: urlString),
              url.scheme?.lowercased() == "otpauth-migration",
              url.host?.lowercased() == "offline",
              let dataParam = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?
                  .first(where: { $0.name == "data" })?
                  .value,
              let data = Data(base64Encoded: dataParam) else {
            return nil
        }
        
        do {
            let migrationPayload = try MigrationPayload(serializedData: data)
            var accounts: [Account] = []
            
            for otpParam in migrationPayload.otpParameters {
                // Determine account name and issuer from the name field
                var accountName = otpParam.name
                var issuer = otpParam.issuer
                
                // If issuer is empty but name contains colon, split it
                if issuer.isEmpty, let colonIndex = otpParam.name.firstIndex(of: ":") {
                    issuer = String(otpParam.name[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                    accountName = String(otpParam.name[otpParam.name.index(after: colonIndex)...])
                        .trimmingCharacters(in: .whitespaces)
                }
                
                // Create account
                let account = Account(
                    issuer: issuer,
                    account: accountName,
                    secret: otpParam.secret,
                    digits: Int(otpParam.digits) > 0 ? Int(otpParam.digits) : 6,
                    period: Int(otpParam.period) > 0 ? Int(otpParam.period) : 30,
                    algorithm: otpParam.algorithm.isEmpty ? "SHA1" : otpParam.algorithm
                )
                
                accounts.append(account)
            }
            
            return accounts
        } catch {
            print("Failed to parse migration URL: \(error)")
            return nil
        }
    }
}

// Generated protobuf classes would normally be here, but we'll define minimal ones for migration
// In practice, you'd use swift-protobuf plugin to generate these from Migration.proto
extension MigrationPayload {
    init(serializedData: Data) throws {
        let jsonDecoder = JSONDecoder()
        // This is a simplified approach - in reality we'd use protobuf decoding
        // For this implementation, we'll treat the data as JSON for simplicity
        // In a real app, you'd use: try MigrationPayload(serializedData: serializedData)
        // But we need the actual protobuf definitions compiled
        
        // Since we don't have the compiled protobuf, let's implement a basic parser
        // that works with the base64 decoded protobuf data
        throw NSError(domain: "MigrationHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "Protobuf parsing not implemented"])
    }
}

// Simplified migration payload structures for demonstration
struct MigrationPayload {
    let otpParameters: [OtpParameters]
}

struct OtpParameters {
    let secret: String
    let name: String
    let issuer: String
    let algorithm: String
    let digits: Int32
    let period: Int32
}