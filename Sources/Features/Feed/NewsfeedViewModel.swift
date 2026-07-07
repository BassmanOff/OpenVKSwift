import SwiftUI

/// Лента новостей (newsfeed.get / newsfeed.getGlobal) — записи друзей/сообществ или все записи.
/// Пагинация курсором `start_from` → `next_from` (как в VK API).
///
/// ВАЖНО: reload НЕ очищает список до прихода ответа. Если очистить сразу, List
/// исчезает из иерархии прямо во время pull-to-refresh: спиннер пропадает, мигает
/// «В ленте пусто», а незавершённый запрос отменяется (та самая ошибка «cancelled»).
@MainActor
final class NewsfeedViewModel: ObservableObject {
    /// Моя лента (друзья + сообщества) или общая лента всех записей.
    enum Kind: Hashable { case my, global }

    @Published private(set) var posts: [Post] = []
    @Published private(set) var authors: [Int: WallViewModel.Author] = [:]
    /// Первая загрузка / pull-to-refresh (центральный спиннер, когда список пуст).
    @Published private(set) var isLoading = false
    /// Подгрузка следующей страницы (спиннер-футер внизу списка).
    @Published private(set) var isLoadingMore = false
    @Published private(set) var canLoadMore = true
    @Published var errorMessage: String?
    @Published private(set) var kind: Kind = .my

    private var nextFrom: String?
    private let pageSize = 25
    private var loaded = false
    /// Растёт при каждом reload/переключении ленты — ответы устаревших запросов отбрасываются.
    private var generation = 0

    /// Ответ newsfeed.get/getGlobal: посты + профили/группы авторов + курсор следующей страницы.
    private struct Response: Decodable {
        let items: [Post]
        let profiles: [User]?
        let groups: [Community]?
        let nextFrom: String?
        enum CodingKeys: String, CodingKey {
            case items, profiles, groups
            case nextFrom = "next_from"
        }
    }

    private var method: String { kind == .my ? "newsfeed.get" : "newsfeed.getGlobal" }

    func loadIfNeeded(settings: AppSettings) async {
        guard !loaded else { return }
        loaded = true
        // Мгновенно показываем закэшированную ленту (в т.ч. обновлённую в фоне BGAppRefresh),
        // потом тихо обновляем сетью — пользователь не ждёт «пустой» экран.
        if posts.isEmpty { applyCache() }
        await reload(settings: settings)
    }

    /// Переключение «Моя лента»/«Все записи». Здесь список очищаем сразу —
    /// это явное действие пользователя (не жест refresh), старые посты не к месту.
    func switchTo(_ kind: Kind, settings: AppSettings) async {
        guard kind != self.kind else { return }
        self.kind = kind
        generation += 1
        posts = []
        authors = [:]
        nextFrom = nil
        canLoadMore = true
        errorMessage = nil
        applyCache() // кэш этой ленты, если есть — мгновенно
        await reload(settings: settings)
    }

    /// Подставляет закэшированную первую страницу текущей ленты (если она есть).
    private func applyCache() {
        guard let data = Self.loadCache(kind: kind),
              let res: Response = try? OVKClient.decode(data) else { return }
        mergeAuthors(res)
        posts = dedup(res.items)
        nextFrom = res.nextFrom
    }

    /// Загружает первую страницу. Старые посты остаются на экране до прихода свежих.
    func reload(settings: AppSettings) async {
        generation += 1
        let gen = generation
        errorMessage = nil
        isLoading = true
        defer { if gen == generation { isLoading = false } }

        do {
            // Первую страницу тянем «сырой», чтобы закэшировать исходный JSON.
            let raw = try await fetchRaw(startFrom: nil, settings: settings)
            guard gen == generation else { return } // пришёл ответ устаревшего запроса
            let res: Response = try OVKClient.decode(raw)
            mergeAuthors(res)
            posts = dedup(res.items)
            nextFrom = res.nextFrom
            canLoadMore = !(res.nextFrom ?? "").isEmpty && res.items.count >= pageSize
            Self.saveCache(raw, kind: kind)
        } catch {
            guard gen == generation, !error.isCancellation else { return }
            // При обновлении не затираем уже показанные посты; ошибку показываем только на пустом экране.
            if posts.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    /// Подгрузка следующей страницы (вызывается по появлению последнего поста).
    func loadMore(settings: AppSettings) async {
        guard !isLoading, !isLoadingMore, canLoadMore, !posts.isEmpty else { return }
        let gen = generation
        isLoadingMore = true
        defer { if gen == generation { isLoadingMore = false } }

        do {
            let res = try await fetchPage(startFrom: nextFrom, settings: settings)
            guard gen == generation else { return }
            mergeAuthors(res)

            // Дедупликация: сервер может повторять посты между страницами.
            let existing = Set(posts.map { $0.id })
            let fresh = res.items.filter { !existing.contains($0.id) }
            posts += fresh

            // Стоп, если курсор пуст/не сдвинулся, страница неполная или все посты — дубли.
            let previous = nextFrom
            nextFrom = res.nextFrom
            if (res.nextFrom ?? "").isEmpty || res.nextFrom == previous
                || res.items.count < pageSize || fresh.isEmpty {
                canLoadMore = false
            }
        } catch {
            guard gen == generation, !error.isCancellation else { return }
            canLoadMore = false
            if posts.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    /// Удаляет запись (wall.delete) и убирает её из ленты.
    func delete(_ post: Post, settings: AppSettings) async {
        guard let token = settings.token else { return }
        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        do {
            try await client.execute(
                "wall.delete",
                params: ["owner_id": String(post.ownerID), "post_id": String(post.postID)]
            )
            posts.removeAll { $0.id == post.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Private

    private func fetchPage(startFrom: String?, settings: AppSettings) async throws -> Response {
        try OVKClient.decode(try await fetchRaw(startFrom: startFrom, settings: settings))
    }

    /// Сырое тело страницы ленты (для кэша первой страницы и обычной подгрузки).
    private func fetchRaw(startFrom: String?, settings: AppSettings) async throws -> Data {
        guard let token = settings.token else { throw OVKError.notAuthorized }
        let client = OVKClient(
            instance: settings.instance,
            token: token,
            apiVersion: settings.apiVersion
        )
        var params: [String: String] = [
            "count": String(pageSize),
            "extended": "1"
        ]
        if let startFrom, !startFrom.isEmpty {
            params["start_from"] = startFrom
        }
        return Data(try await client.rawResponse(method, params: params).utf8)
    }

    // MARK: - Дисковый кэш первой страницы (лента видна сразу при запуске)

    private static func cacheURL(kind: Kind) -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(kind == .my ? "feed_cache_my.json" : "feed_cache_global.json")
    }

    private static func saveCache(_ raw: Data, kind: Kind) {
        try? raw.write(to: cacheURL(kind: kind), options: .atomic)
    }

    private static func loadCache(kind: Kind) -> Data? {
        try? Data(contentsOf: cacheURL(kind: kind))
    }

    /// Стирает кэш ленты (при выходе из аккаунта).
    static func clearCache() {
        try? FileManager.default.removeItem(at: cacheURL(kind: .my))
        try? FileManager.default.removeItem(at: cacheURL(kind: .global))
    }

    /// Фоновое обновление «моей ленты» (BGAppRefresh): тихо тянет первую страницу и кладёт
    /// в кэш, чтобы при следующем запуске пользователь сразу увидел почти свежие посты.
    static func prefetchForBackground(settings: AppSettings) async {
        guard let token = settings.token else { return }
        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        if let raw = try? await client.rawResponse("newsfeed.get", params: ["count": "25", "extended": "1"]) {
            // Кэшируем только валидный ответ (с "response"), не ошибку.
            let data = Data(raw.utf8)
            if let _: Response = try? OVKClient.decode(data) { saveCache(data, kind: .my) }
        }
    }

    private func mergeAuthors(_ res: Response) {
        for u in res.profiles ?? [] {
            authors[u.id] = WallViewModel.Author(name: u.fullName, avatar: u.avatarURL)
        }
        for g in res.groups ?? [] {
            authors[-g.groupID] = WallViewModel.Author(name: g.name, avatar: g.avatarURL)
        }
    }

    /// Дедуп внутри одной страницы (повторяющиеся id ломают identity в ForEach).
    private func dedup(_ items: [Post]) -> [Post] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }
}
