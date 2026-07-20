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
    /// Локальные уведомления о новых сообщениях (ВКЛ по умолчанию).
    @Published var notifyMessages: Bool {
        didSet { defaults.set(notifyMessages, forKey: notifyKey) }
    }
    /// Фоновый режим: тихое аудио держит процесс живым → LongPoll не засыпает →
    /// уведомления приходят мгновенно даже при закрытом приложении, ценой батареи.
    /// ВЫКЛ по умолчанию.
    @Published var backgroundKeepAlive: Bool {
        didSet { defaults.set(backgroundKeepAlive, forKey: keepAliveKey) }
    }
    /// Оптимизация изображений: даунсэмплинг + фоновое декодирование (вкл по умолчанию).
    /// Тумблер в настройках — для сравнения скорости появления картинок.
    @Published var imageOptimization: Bool {
        didSet { defaults.set(imageOptimization, forKey: imageOptKey) }
    }
    /// Кастомные реакции (скрытые zero-width сообщения). ВКЛ по умолчанию. Выключение —
    /// для отладки: сообщения-реакции показываются как в веб-версии OpenVK (обычный текст
    /// с исходным содержимым), payload не интерпретируется.
    @Published var enableCustomReactions: Bool {
        didSet { defaults.set(enableCustomReactions, forKey: reactionsKey) }
    }
    /// Показывать ли на значке «Архив» бейдж непрочитанных из архивных диалогов
    /// (в общий бейдж вкладки/иконки приложения архив НЕ входит — вкл по умолчанию).
    @Published var countArchivedUnread: Bool {
        didSet { defaults.set(countArchivedUnread, forKey: archivedUnreadKey) }
    }
    /// Карточка репоста-ссылки (wall123_456) в ЛС: компактная строка (по умолчанию) или
    /// развёрнутая карточка с аватаром/фото на всю ширину.
    @Published var messagePostFullCard: Bool {
        didSet { defaults.set(messagePostFullCard, forKey: postCardKey) }
    }
    /// Параллельный экран плеера в стиле VK 7–8. ВЫКЛ по умолчанию.
    @Published var useNewPlayer: Bool {
        didSet { defaults.set(useNewPlayer, forKey: newPlayerKey) }
    }

    /// id альбома «_Private(OVK_iOS)», куда дублируются фото из ЛС (у OpenVK нет вложений
    /// в личных сообщениях — шлём прямой линк на .jpeg из этого альбома). Создаётся при
    /// первой отправке; ПЕР-АККАУНТНЫЙ — чистится при выходе (чужой id указал бы в чужой альбом).
    var pmPhotoAlbumID: Int? {
        get { defaults.object(forKey: pmAlbumKey) as? Int }
        set {
            if let newValue { defaults.set(newValue, forKey: pmAlbumKey) }
            else { defaults.removeObject(forKey: pmAlbumKey) }
        }
    }
    /// Показывали ли предупреждение, что фото из ЛС попадают в общедоступный альбом.
    var didWarnPMPhoto: Bool {
        get { defaults.bool(forKey: pmWarnKey) }
        set { defaults.set(newValue, forKey: pmWarnKey) }
    }

    /// Версия API в стиле VK. OpenVK принимает параметр `v`.
    let apiVersion = "5.131"

    private let keychain = KeychainStore()
    private let defaults = UserDefaults.standard
    private let instanceKey = "selected_instance"
    private let userIDKey = "user_id"
    private let autoDownloadKey = "auto_download_my_tracks"
    private let notifyKey = "notify_messages"
    private let keepAliveKey = "background_keep_alive"
    private let imageOptKey = "image_optimization"
    private let reactionsKey = "enable_custom_reactions"
    private let archivedUnreadKey = "count_archived_unread"
    private let postCardKey = "message_post_full_card"
    private let newPlayerKey = "use_new_player"
    private let pmAlbumKey = "pm_photo_album_id"
    private let pmWarnKey = "pm_photo_warned"

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
        notifyMessages = defaults.object(forKey: notifyKey) as? Bool ?? true
        backgroundKeepAlive = defaults.object(forKey: keepAliveKey) as? Bool ?? false
        imageOptimization = defaults.object(forKey: imageOptKey) as? Bool ?? true
        enableCustomReactions = defaults.object(forKey: reactionsKey) as? Bool ?? true
        countArchivedUnread = defaults.object(forKey: archivedUnreadKey) as? Bool ?? true
        messagePostFullCard = defaults.object(forKey: postCardKey) as? Bool ?? false
        useNewPlayer = defaults.object(forKey: newPlayerKey) as? Bool ?? false
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
        // Watermark'и уведомлений — персональные (другой аккаунт не должен их наследовать).
        defaults.removeObject(forKey: "activity_notified_date")
        defaults.removeObject(forKey: "msg_notified_last_ids")
        // id альбома фото-ЛС — пер-аккаунтный (чужой указал бы в чужой альбом).
        defaults.removeObject(forKey: pmAlbumKey)
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
