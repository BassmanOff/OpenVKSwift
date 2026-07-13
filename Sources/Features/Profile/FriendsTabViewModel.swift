import SwiftUI

/// ViewModel для вкладки «Друзья» в таб-баре: загрузка, локальный поиск, глобальный поиск.
@MainActor
final class FriendsTabViewModel: ObservableObject {
    @Published private(set) var friends: [User] = []
    @Published var query = ""
    @Published private(set) var searchResults: [User] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isSearching = false
    @Published var errorMessage: String?

    private var loaded = false

    private func makeClient(_ settings: AppSettings) -> OVKClient? {
        guard let token = settings.token else { return nil }
        return OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
    }

    func loadIfNeeded(settings: AppSettings) async {
        guard !loaded else { return }
        await load(settings: settings)
    }

    func load(settings: AppSettings) async {
        guard let client = makeClient(settings) else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let res: ItemsResponse<User> = try await client.call(
                "friends.get",
                params: ["user_id": "0", "fields": "photo_100,photo_50,online,last_seen,screen_name", "count": "1000"]
            )
            friends = res.items
            loaded = true
        } catch {
            if error.isCancellation { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Pull-to-refresh: перезагружает список друзей. Старые данные остаются на
    /// экране до прихода свежих (как в NewsfeedViewModel.reload) — не затираем список
    /// до ответа, чтобы не было «пустого» мигания. Поиск/навигация не трогаем.
    func reload(settings: AppSettings) async {
        guard let client = makeClient(settings) else { return }
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            let res: ItemsResponse<User> = try await client.call(
                "friends.get",
                params: ["user_id": "0", "fields": "photo_100,photo_50,online,last_seen,screen_name", "count": "1000"]
            )
            friends = res.items
        } catch {
            if error.isCancellation { return }
            // При обновлении не затираем уже показанный список; ошибку — только на пустом экране.
            if friends.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    /// Лёгкое фоновое обновление ТОЛЬКО статусов онлайна (раз в 2-3 мин).
    /// Запрашиваем минимум полей (online,last_seen) и обновляем `online`/`lastSeenPlatform`
    /// у уже загруженных друзей по id — весь список не перезагружаем, порядок не меняем.
    /// Не добавляет/не удаляет друзей (это делает только полная reload).
    func refreshOnlineStatus(settings: AppSettings) async {
        guard !friends.isEmpty, let client = makeClient(settings) else { return }
        do {
            let res: ItemsResponse<User> = try await client.call(
                "friends.get",
                params: ["user_id": "0", "fields": "online,last_seen", "count": "1000"]
            )
            let freshByID = Dictionary(res.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var updated = friends
            for i in updated.indices {
                if let fresh = freshByID[updated[i].id] {
                    updated[i].online = fresh.online
                    updated[i].lastSeenPlatform = fresh.lastSeenPlatform
                }
            }
            friends = updated
        } catch {
            // Статусы онлайна некритичны — тихо игнорируем.
        }
    }

    /// Локальные совпадения среди своих друзей (для «сначала свои»).
    func localMatches(_ query: String) -> [User] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return friends.filter { $0.fullName.lowercased().contains(q) }
    }

    /// Глобальный поиск (users.search), исключая уже найденные локально.
    func searchGlobal(_ query: String, settings: AppSettings) async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let client = makeClient(settings) else {
            searchResults = []
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            let res: ItemsResponse<User> = try await client.call(
                "users.search",
                params: ["q": q, "count": "50", "fields": "photo_100,photo_50,online,last_seen,screen_name"]
            )
            let localIDs = Set(localMatches(q).map { $0.id })
            searchResults = res.items.filter { !localIDs.contains($0.id) }
        } catch {
            searchResults = []
        }
    }
}