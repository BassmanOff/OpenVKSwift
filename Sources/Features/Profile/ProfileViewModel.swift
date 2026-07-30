import SwiftUI

/// Профиль текущего пользователя (users.get с нужными полями).
@MainActor
final class ProfileViewModel: ObservableObject {
    @Published private(set) var user: User?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    /// Статус дружбы с отображаемым пользователем (0=нет, 1=заявка отправлена/исходящая, 2=заявка получена/входящая, 3=друг).
    /// Внимание: сервер в users.get меняет 1↔2 относительно внутреннего getSubscriptionStatus.
    @Published private(set) var friendStatus: Int?
    private var loaded = false
    private let cacheScope = AccountCacheScope.current()

    private static let fields =
        "photo_200,photo_100,photo_50,photo_max,status,screen_name,online,last_seen,city,about,bdate,sex,counters,friend_status,verified,nickname,music,movies,tv,books,games,interests,quotes,telegram,reg_date"

    func loadIfNeeded(userID: Int, settings: AppSettings) async {
        guard !loaded else { return }
        await load(userID: userID, settings: settings)
    }

    func load(userID: Int, settings: AppSettings) async {
        guard let token = settings.token else { return }
        let sessionID = settings.sessionID
        // Мгновенно показываем закэшированный профиль — не ждём сеть при запуске.
        if user == nil, let data = loadCache(userID: userID),
           let cached: [User] = try? OVKClient.decode(data) {
            user = cached.first
            if settings.sessionID == sessionID {
                rememberCurrentAccount(requestedID: userID, settings: settings)
            }
        }
        isLoading = (user == nil)
        errorMessage = nil
        defer { isLoading = false }

        let client = OVKClient(
            instance: settings.instance,
            token: token,
            apiVersion: settings.apiVersion
        )
        do {
            // user_ids=0 → текущий пользователь; ответ — массив в response.
            let raw = Data(try await client.rawResponse(
                "users.get",
                params: ["user_ids": String(userID), "fields": Self.fields]
            ).utf8)
            let users: [User] = try OVKClient.decode(raw)
            guard settings.sessionID == sessionID else { return }
            user = users.first
            friendStatus = users.first?.friendStatus
            rememberCurrentAccount(requestedID: userID, settings: settings)
            loaded = true
            saveCache(raw, userID: userID)
            await augmentOwnBirthday(requestedID: userID, settings: settings, client: client)
        } catch {
            if error.isCancellation { return }
            // Кэш остаётся — ошибку показываем только если и его нет.
            if user == nil { errorMessage = error.localizedDescription }
        }
    }

    private struct SelfProfileInfo: Decodable { let bdate: String? }

    /// users.get отдаёт bdate=null при дефолтной приватности дня рождения (в БД birthday_privacy=0,
    /// который веб показывает С ГОДОМ, а VKAPI Users.get ошибочно мапит в null). Из-за этого у
    /// пользователей, указавших год, дата рождения вообще не отображается. Только для СВОЕГО
    /// профиля добираем настоящую дату через account.getProfileInfo — она всегда полная,
    /// независимо от приватности. Чужие профили так не починить (сервер их bdate не отдаёт).
    private func augmentOwnBirthday(requestedID: Int, settings: AppSettings, client: OVKClient) async {
        guard user?.bdate == nil else { return }                       // приватность 1 (без года) — не трогаем
        guard requestedID == 0 || requestedID == settings.userID else { return }  // только свой профиль
        guard let info: SelfProfileInfo = try? await client.call("account.getProfileInfo"),
              let bdate = info.bdate, !isEmptyBirthday(bdate) else { return }
        user?.bdate = bdate
    }

    /// account.getProfileInfo отдаёт "01.01.1970" как заглушку «дата не задана» (см. Account.php).
    private func isEmptyBirthday(_ bdate: String) -> Bool {
        let parts = bdate.split(separator: ".").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return parts == [1, 1, 1970]
    }

    // MARK: - Действия с друзьями

    /// Отправить заявку в друзья / принять заявку (один и тот же API — friends.add).
    /// `optimisticStatus` — статус после успешного запроса (1=заявка отправлена, 3=друзья).
    func sendFriendRequest(settings: AppSettings, optimisticStatus: Int = 1) async {
        guard let client = client(settings), let userID = user?.id else { return }
        friendStatus = optimisticStatus
        _ = try? await client.rawResponse("friends.add", params: ["user_id": String(userID)])
    }

    /// Отменить отправленную заявку / отклонить полученную / удалить из друзей (friends.delete).
    func removeFriend(settings: AppSettings) async {
        guard let client = client(settings), let userID = user?.id else { return }
        friendStatus = 0 // оптимистично
        _ = try? await client.rawResponse("friends.delete", params: ["user_id": String(userID)])
    }

    /// Блокировка пользователя через совместимый с VKAPI account.ban.
    func blockUser(settings: AppSettings) async throws {
        guard let client = client(settings), let userID = user?.id else { throw OVKError.empty }
        try await client.execute("account.ban", params: ["owner_id": String(userID)])
        friendStatus = 0
    }

    private func client(_ s: AppSettings) -> OVKClient? {
        guard let token = s.token else { return nil }
        return OVKClient(instance: s.instance, token: token, apiVersion: s.apiVersion)
    }

    private func rememberCurrentAccount(requestedID: Int, settings: AppSettings) {
        guard requestedID == 0 || requestedID == settings.userID, let user else { return }
        if settings.userID == nil { settings.rememberUserID(user.id) }
        settings.updateCurrentAccount(name: user.fullName, avatarURL: user.avatarURL)
    }

    // MARK: - Дисковый кэш профиля (виден сразу при запуске)

    private func cacheURL(userID: Int) -> URL {
        cacheScope.file("profile_cache_\(userID).json")
    }

    private func saveCache(_ raw: Data, userID: Int) {
        try? raw.write(to: cacheURL(userID: userID), options: .atomic)
    }

    private func loadCache(userID: Int) -> Data? {
        try? Data(contentsOf: cacheURL(userID: userID))
    }

    /// Стирает все кэши профилей (при выходе из аккаунта).
    static func clearCache() {
        AccountCacheScope.current().removeFiles(prefixes: ["profile_cache_"])
    }
}
