import Foundation
import Combine

@MainActor
final class Store: ObservableObject {
    static let service = "MenuBarAuth"
    static let accountsKey = "accounts"

    @Published private(set) var accounts: [Account] = []

    init() {
        load()
    }

    func load() {
        guard let data = Keychain.get(service: Self.service, account: Self.accountsKey),
              let decoded = try? JSONDecoder().decode([Account].self, from: data) else {
            accounts = []
            return
        }
        accounts = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        Keychain.set(data, service: Self.service, account: Self.accountsKey)
    }

    @discardableResult
    func add(_ account: Account) -> Bool {
        let dup = accounts.contains { $0.issuer == account.issuer && $0.account == account.account }
        if dup { return false }
        accounts.append(account)
        persist()
        return true
    }

    @discardableResult
    func addMany(_ incoming: [Account]) -> Int {
        var added = 0
        for acc in incoming {
            let dup = accounts.contains { $0.issuer == acc.issuer && $0.account == acc.account }
            if !dup { accounts.append(acc); added += 1 }
        }
        if added > 0 { persist() }
        return added
    }

    func remove(_ account: Account) {
        accounts.removeAll { $0.id == account.id }
        persist()
    }
}
