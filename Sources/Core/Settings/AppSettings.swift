import Foundation
import Combine

/// Глобальное состояние сессии: выбранный инстанс, токен, текущий пользователь.
@MainActor
final class AppSettings: ObservableObject {
    @Published var instance: Instance {
        didSet { persistInstance() }
    }
    @Published private(set) var token: String?
    @Published private(set) var userID: Int?

    /// Версия API в стиле VK. OpenVK принимает параметр `v`.
    let apiVersion = "5.131"

    private let keychain = KeychainStore()
    private let defaults = UserDefaults.standard
    private let instanceKey = "selected_instance"
    private let userIDKey = "user_id"

    init() {
        if let data = defaults.data(forKey: instanceKey),
           let saved = try? JSONDecoder().decode(Instance.self, from: data) {
            instance = saved
        } else {
            instance = .openvkOrg
        }
        token = keychain.token
        userID = defaults.object(forKey: userIDKey) as? Int
    }

    var isLoggedIn: Bool { token != nil }

    func signIn(token: String, userID: Int) {
        keychain.token = token
        defaults.set(userID, forKey: userIDKey)
        self.token = token
        self.userID = userID
    }

    func signOut() {
        keychain.token = nil
        defaults.removeObject(forKey: userIDKey)
        token = nil
        userID = nil
    }

    /// Сообщает серверу, что мы онлайн (платформа берётся из client_name токена → «с iPhone»).
    /// Окно онлайна у OpenVK — 5 минут, поэтому вызывается периодически.
    func reportOnline() {
        guard let token else { return }
        let client = OVKClient(instance: instance, token: token, apiVersion: apiVersion)
        Task { try? await client.execute("account.setOnline") }
    }

    private func persistInstance() {
        if let data = try? JSONEncoder().encode(instance) {
            defaults.set(data, forKey: instanceKey)
        }
    }
}
