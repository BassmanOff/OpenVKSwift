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
    @Published private(set) var savedAccounts: [SavedAccount]
    /// Меняется при входе, выходе и переключении аккаунта, чтобы пересоздать экран и кэши.
    @Published private(set) var sessionID: UUID
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
    /// Экран плеера в стиле VK 7–8. ВКЛ по умолчанию; явный выбор пользователя сохраняется.
    @Published var useNewPlayer: Bool {
        didSet { defaults.set(useNewPlayer, forKey: newPlayerKey) }
    }
    /// Альтернативный вид из ранних сборок: квадратные аватары и зелёная точка онлайн
    /// в профиле. По умолчанию выключен — оригинальный iOS 7-вид использует круги и текст.
    @Published var legacyAvatarIndicators: Bool {
        didSet { defaults.set(legacyAvatarIndicators, forKey: legacyAvatarIndicatorsKey) }
    }

    /// id альбома сервисного аккаунта для фото конкретного пользователя из ЛС.
    func servicePMPhotoAlbumID(for userID: Int) -> Int? {
        defaults.object(forKey: servicePMAlbumKey(userID)) as? Int
    }
    func setServicePMPhotoAlbumID(_ albumID: Int?, for userID: Int) {
        let key = servicePMAlbumKey(userID)
        if let albumID { defaults.set(albumID, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }
    func servicePMPhotoReference(for messageID: Int, userID: Int) -> ServicePhotoReference? {
        guard let data = defaults.data(forKey: ServicePhotoReference.storageKey(
            userID: userID, messageID: messageID
        )) else { return nil }
        return try? JSONDecoder().decode(ServicePhotoReference.self, from: data)
    }
    func setServicePMPhotoReference(_ reference: ServicePhotoReference?, for messageID: Int, userID: Int) {
        let key = ServicePhotoReference.storageKey(userID: userID, messageID: messageID)
        if let reference, let data = try? JSONEncoder().encode(reference) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
    /// Временный локальный секрет сборки. Он не хранится в Git, но остаётся извлекаемым
    /// из собранного IPA — заменить backend-токеном до распространения этой функции.
    var serviceAccountToken: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "OVKServiceAccountToken") as? String else {
            return nil
        }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
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
    private let savedAccountsKey = "saved_accounts"
    private let autoDownloadKey = "auto_download_my_tracks"
    private let notifyKey = "notify_messages"
    private let keepAliveKey = "background_keep_alive"
    private let imageOptKey = "image_optimization"
    private let reactionsKey = "enable_custom_reactions"
    private let archivedUnreadKey = "count_archived_unread"
    private let postCardKey = "message_post_full_card"
    private let newPlayerKey = "use_new_player"
    private let legacyAvatarIndicatorsKey = "legacy_avatar_indicators"
    private let pmWarnKey = "pm_service_photo_warned"

    private func servicePMAlbumKey(_ userID: Int) -> String {
        "service_pm_photo_album_id_\(userID)"
    }

    init() {
        let accountStore = KeychainStore()
        let discardedAccounts: [SavedAccount]
        if let data = defaults.data(forKey: instanceKey),
           let saved = try? JSONDecoder().decode(Instance.self, from: data) {
            instance = Instance.matchingPreset(for: saved) ?? saved
        } else {
            instance = .openvkOrg
        }
        token = accountStore.token
        userID = defaults.object(forKey: userIDKey) as? Int
        if let data = defaults.data(forKey: savedAccountsKey),
           let accounts = try? JSONDecoder().decode([SavedAccount].self, from: data) {
            let normalizedAccounts = SavedAccount.normalized(accounts, tokenFor: accountStore.token)
            savedAccounts = normalizedAccounts
            discardedAccounts = accounts.filter { account in
                !normalizedAccounts.contains { $0.id == account.id }
            }
        } else {
            savedAccounts = []
            discardedAccounts = []
        }
        sessionID = UUID()
        autoDownloadMyTracks = defaults.object(forKey: autoDownloadKey) as? Bool ?? true
        notifyMessages = defaults.object(forKey: notifyKey) as? Bool ?? true
        backgroundKeepAlive = defaults.object(forKey: keepAliveKey) as? Bool ?? false
        imageOptimization = defaults.object(forKey: imageOptKey) as? Bool ?? true
        enableCustomReactions = defaults.object(forKey: reactionsKey) as? Bool ?? true
        countArchivedUnread = defaults.object(forKey: archivedUnreadKey) as? Bool ?? true
        messagePostFullCard = defaults.object(forKey: postCardKey) as? Bool ?? false
        useNewPlayer = defaults.object(forKey: newPlayerKey) as? Bool ?? true
        legacyAvatarIndicators = defaults.object(forKey: legacyAvatarIndicatorsKey) as? Bool ?? false

        for account in discardedAccounts {
            keychain.setToken(nil, for: account)
        }
        persistAccounts()

        // Миграция существующей единственной сессии в список аккаунтов.
        if let token, let userID {
            saveAccount(token: token, userID: userID)
        }
    }

    var isLoggedIn: Bool { token != nil }

    func signIn(token: String, userID: Int) {
        keychain.token = token
        defaults.set(userID, forKey: userIDKey)
        self.token = token
        self.userID = userID
        saveAccount(token: token, userID: userID)
        clearSessionWatermarks()
        sessionID = UUID()
    }

    /// Дозаписывает userID, если он потерялся (например, токен уцелел в Keychain, а UserDefaults очистились).
    func rememberUserID(_ id: Int) {
        guard id > 0, userID != id else { return }
        defaults.set(id, forKey: userIDKey)
        userID = id
        if let token { saveAccount(token: token, userID: id) }
    }

    /// Имя и аватар приходят из users.get при открытии собственного профиля.
    func updateCurrentAccount(name: String, avatarURL: URL?) {
        guard let userID, let index = savedAccounts.firstIndex(where: {
            $0.userID == userID && $0.instance.apiURL == instance.apiURL
        }) else { return }
        guard savedAccounts[index].name != name || savedAccounts[index].avatarURL != avatarURL else { return }
        savedAccounts[index].name = name
        savedAccounts[index].avatarURL = avatarURL
        persistAccounts()
    }

    func isCurrentAccount(_ account: SavedAccount) -> Bool {
        token != nil && userID == account.userID && instance.apiURL == account.instance.apiURL
    }

    /// Возвращает false, если запись осталась, а её токен уже удалён из Keychain.
    @discardableResult
    func switchAccount(to account: SavedAccount) -> Bool {
        guard !isCurrentAccount(account) else { return true }
        guard let savedToken = keychain.token(for: account) else { return false }
        instance = Instance.matchingPreset(for: account.instance) ?? account.instance
        keychain.token = savedToken
        defaults.set(account.userID, forKey: userIDKey)
        token = savedToken
        userID = account.userID
        saveAccount(token: savedToken, userID: account.userID)
        clearSessionWatermarks()
        sessionID = UUID()
        return true
    }

    func deleteAccount(_ account: SavedAccount) {
        let deletingCurrent = isCurrentAccount(account)
        keychain.setToken(nil, for: account)
        savedAccounts.removeAll { $0.id == account.id }
        persistAccounts()
        if deletingCurrent {
            for replacement in savedAccounts where switchAccount(to: replacement) { return }
            signOut()
        }
    }

    func signOut() {
        keychain.token = nil
        defaults.removeObject(forKey: userIDKey)
        clearSessionWatermarks()
        token = nil
        userID = nil
        sessionID = UUID()
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

    private func saveAccount(token: String, userID: Int) {
        let normalizedInstance = Instance.matchingPreset(for: instance) ?? instance
        let id = "\(normalizedInstance.apiURL.absoluteString)#\(userID)"
        let duplicates = savedAccounts.filter {
            $0.id != id &&
            $0.instance.apiURL == normalizedInstance.apiURL &&
            keychain.token(for: $0) == token
        }
        for duplicate in duplicates {
            keychain.setToken(nil, for: duplicate)
        }
        let duplicateIDs = Set(duplicates.map(\.id))
        savedAccounts.removeAll { duplicateIDs.contains($0.id) }
        let existing = savedAccounts.first { $0.id == id }
        let account = SavedAccount(
            userID: userID,
            name: existing?.name ?? "ID \(userID)",
            avatarURL: existing?.avatarURL,
            instance: normalizedInstance
        )
        if let index = savedAccounts.firstIndex(where: { $0.id == id }) {
            // Повторный вход обновляет существующую запись, а не создаёт дубликат.
            savedAccounts[index] = account
        } else {
            savedAccounts.insert(account, at: 0)
        }
        keychain.setToken(token, for: account)
        persistAccounts()
    }

    private func persistAccounts() {
        if let data = try? JSONEncoder().encode(savedAccounts) {
            defaults.set(data, forKey: savedAccountsKey)
        }
    }

    private func clearSessionWatermarks() {
        // Watermark'и уведомлений — персональные (другой аккаунт не должен их наследовать).
        defaults.removeObject(forKey: "activity_notified_date")
        defaults.removeObject(forKey: "msg_notified_last_ids")
    }

}
