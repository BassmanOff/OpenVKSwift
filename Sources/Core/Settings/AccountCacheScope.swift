import Foundation

/// Stable, account-specific storage for data returned by an OpenVK-compatible server.
struct AccountCacheScope {
    let directory: URL
    let keySuffix: String

    init(apiURL: URL, userID: Int, documents: URL) {
        let server = Data(apiURL.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        keySuffix = "\(server)_\(userID)"
        directory = documents
            .appendingPathComponent("AccountCaches", isDirectory: true)
            .appendingPathComponent(keySuffix, isDirectory: true)
    }

    static func current(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> AccountCacheScope {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let userID = defaults.object(forKey: "user_id") as? Int ?? 0
        let apiURL: URL = defaults.data(forKey: "selected_instance")
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { ($0["apiURL"] as? String).flatMap(URL.init(string:)) }
            ?? Instance.openvkOrg.apiURL
        return AccountCacheScope(apiURL: apiURL, userID: userID, documents: documents)
    }

    /// Moves the pre-account-scoping cache into the active account once.
    func file(_ name: String, migrateLegacy: Bool = true) -> URL {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let scoped = directory.appendingPathComponent(name)
        guard migrateLegacy, !manager.fileExists(atPath: scoped.path) else { return scoped }
        let documents = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let legacy = documents.appendingPathComponent(name)
        if manager.fileExists(atPath: legacy.path) {
            try? manager.moveItem(at: legacy, to: scoped)
        }
        return scoped
    }

    func defaultsKey(_ base: String) -> String {
        "\(base)_\(keySuffix)"
    }

    func removeFiles(prefixes: [String]) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for file in files where prefixes.contains(where: file.lastPathComponent.hasPrefix) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
