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
    /// Автозагрузка треков, добавленных в «Мою музыку» (вкл по умолчанию).
    @Published var autoDownloadMyTracks: Bool {
        didSet { defaults.set(autoDownloadMyTracks, forKey: autoDownloadKey) }
    }
    /// Локальные уведомления о новых сообщениях (выкл по умолчанию — включается в настройках).
    @Published var notifyMessages: Bool {
        didSet { defaults.set(notifyMessages, forKey: notifyKey) }
    }
    /// Оптимизация изображений: даунсэмплинг + фоновое декодирование (вкл по умолчанию).
    /// Тумблер в настройках — для сравнения скорости появления картинок.
    @Published var imageOptimization: Bool {
        didSet { defaults.set(imageOptimization, forKey: imageOptKey) }
    }
    /// Новый видеодвижок без VLC (вкл по умолчанию); выкл — запасной путь через VLC.
    @Published var nativeVideoEngine: Bool {
        didSet { defaults.set(nativeVideoEngine, forKey: nativeVideoKey) }
    }

    /// Версия API в стиле VK. OpenVK принимает параметр `v`.
    let apiVersion = "5.131"

    private let keychain = KeychainStore()
    private let defaults = UserDefaults.standard
    private let instanceKey = "selected_instance"
    private let userIDKey = "user_id"
    private let autoDownloadKey = "auto_download_my_tracks"
    private let notifyKey = "notify_messages"
    private let imageOptKey = "image_optimization"
    private let nativeVideoKey = "native_video_engine"

    init() {
        if let data = defaults.data(forKey: instanceKey),
           let saved = try? JSONDecoder().decode(Instance.self, from: data) {
            instance = saved
        } else {
            instance = .openvkOrg
        }
        token = keychain.token
        userID = defaults.object(forKey: userIDKey) as? Int
        autoDownloadMyTracks = defaults.object(forKey: autoDownloadKey) as? Bool ?? true
        notifyMessages = defaults.object(forKey: notifyKey) as? Bool ?? false
        imageOptimization = defaults.object(forKey: imageOptKey) as? Bool ?? true
        nativeVideoEngine = defaults.object(forKey: nativeVideoKey) as? Bool ?? true
    }

    var isLoggedIn: Bool { token != nil }

    func signIn(token: String, userID: Int) {
        keychain.token = token
        defaults.set(userID, forKey: userIDKey)
        self.token = token
        self.userID = userID
    }

    /// Дозаписывает userID, если он потерялся (например, токен уцелел в Keychain, а UserDefaults очистились).
    func rememberUserID(_ id: Int) {
        guard id > 0, userID != id else { return }
        defaults.set(id, forKey: userIDKey)
        userID = id
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

    /// Отмечает трек как «сейчас слушаю»: `audio.setBroadcast` ставит статус трансляции
    /// И регистрирует прослушивание (внутри вызывает beacon → `$audio->listen`, +1 к счётчику).
    /// `audio` = "{owner}_{vid}"; наш `audioID` — это и есть VID (audio.add резолвит через getByOwnerAndVID).
    /// `target_ids` должен равняться своему user id — иначе сервер вернёт ошибку 600.
    func broadcastListen(ownerID: Int, audioID: Int) {
        guard let token, let uid = userID, uid > 0 else { return }
        let client = OVKClient(instance: instance, token: token, apiVersion: apiVersion)
        Task {
            try? await client.execute("audio.setBroadcast", params: [
                "audio": "\(ownerID)_\(audioID)",
                "target_ids": String(uid)
            ])
        }
    }

    private func persistInstance() {
        if let data = try? JSONEncoder().encode(instance) {
            defaults.set(data, forKey: instanceKey)
        }
    }
}
