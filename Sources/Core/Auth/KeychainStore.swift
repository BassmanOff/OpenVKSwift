import Foundation
import Security

/// Минимальная обёртка над Keychain для хранения access_token.
struct KeychainStore {
    private let service = "com.ovkclient.app"
    private let activeAccount = "access_token"

    var token: String? {
        get { read(account: activeAccount) }
        nonmutating set {
            set(newValue, account: activeAccount)
        }
    }

    func token(for account: SavedAccount) -> String? {
        read(account: accountKey(account))
    }

    func setToken(_ token: String?, for account: SavedAccount) {
        set(token, account: accountKey(account))
    }

    private func set(_ value: String?, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        guard let value else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func accountKey(_ account: SavedAccount) -> String {
        "saved_account:\(account.id)"
    }
}
