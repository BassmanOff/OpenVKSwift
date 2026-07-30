import Foundation

/// Метаданные сохранённого входа. Токен хранится отдельно в Keychain.
struct SavedAccount: Codable, Identifiable, Hashable {
    let userID: Int
    var name: String
    var avatarURL: URL?
    let instance: Instance

    var id: String { "\(instance.apiURL.absoluteString)#\(userID)" }

    static func normalized(
        _ accounts: [SavedAccount],
        tokenFor: (SavedAccount) -> String?
    ) -> [SavedAccount] {
        let candidates = accounts.map { account in
            (
                account: SavedAccount(
                    userID: account.userID,
                    name: account.name,
                    avatarURL: account.avatarURL,
                    instance: Instance.matchingPreset(for: account.instance) ?? account.instance
                ),
                token: tokenFor(account)
            )
        }
        var result: [SavedAccount] = []
        for candidate in candidates {
            let account = candidate.account
            guard !result.contains(where: { $0.id == account.id }) else { continue }
            if let token = candidate.token,
               let ownerID = Int(token.prefix { $0 != "-" }),
               ownerID != account.userID,
               candidates.contains(where: {
                   $0.account.instance.apiURL == account.instance.apiURL &&
                   $0.account.userID == ownerID &&
                   $0.token == token
               }) {
                continue
            }
            result.append(account)
        }
        return result
    }
}
