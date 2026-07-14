import SwiftUI
import Combine

/// Лента новостей (newsfeed.get / newsfeed.getGlobal) — записи друзей/сообществ или все записи.
/// Пагинация курсором `start_from` → `next_from` (как в VK API).
///
/// ВАЖНО: reload НЕ очищает список до прихода ответа. Если очистить сразу, List
/// исчезает из иерархии прямо во время pull-to-refresh: спиннер пропадает, мигает
/// «В ленте пусто», а незавершённый запрос отменяется (та самая ошибка «cancelled»).
@MainActor
final class NewsfeedViewModel: CachedListViewModel<NewsfeedViewModel.Response, Post, NewsfeedViewModel.Kind> {

    /// Периодический опрос счётчиков (лайки/комменты/репосты) уже загруженных постов (60с).
    /// Как в ActivityViewModel: таймер на Main RunLoop, переживает переоценку .task.
    private var countsPollTimer: AnyCancellable?

    override func loadIfNeeded(settings: AppSettings) async {
        startCountsPolling(settings: settings)
        await super.loadIfNeeded(settings: settings)
    }

    private func startCountsPolling(settings: AppSettings) {
        guard countsPollTimer == nil else { return }
        countsPollTimer = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.refreshCounts(settings: settings) }
            }
    }

    /// Одним запросом wall.getById (список "owner_id_post_id" через запятую) подтягивает
    /// свежие счётчики для уже загруженных постов — вместо перезапроса всей страницы.
    /// OpenVK не шлёт LongPoll по лайкам/комментариям, опрос раз в минуту — единственный путь.
    func refreshCounts(settings: AppSettings) async {
        guard let token = settings.token, !items.isEmpty else { return }
        // ponytail: cap на глубокую прокрутку (не раздувать URL), поднять при жалобах.
        let ids = items.prefix(100).map(\.id).joined(separator: ",")
        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        guard let res: WallResponse = try? await client.call("wall.getById", params: ["posts": ids]) else { return }

        var byID: [String: Post] = [:]
        for p in res.items { byID[p.id] = p }
        guard !byID.isEmpty else { return }
        items = items.map { byID[$0.id] ?? $0 }
        persistCounts(byID)
    }

    /// Патчит счётчики прямо в уже сохранённом на диске кэше (Post не Encodable, полную
    /// модель не пересериализовать) — иначе обновлённые числа терялись бы при перезапуске.
    private func persistCounts(_ byID: [String: Post]) {
        guard let raw = loadCache(),
              var root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              var response = root["response"] as? [String: Any],
              var itemsJSON = response["items"] as? [[String: Any]] else { return }

        for i in itemsJSON.indices {
            guard let ownerID = itemsJSON[i]["owner_id"] as? Int,
                  let postID = itemsJSON[i]["id"] as? Int,
                  let post = byID["\(ownerID)_\(postID)"] else { continue }
            var likes = itemsJSON[i]["likes"] as? [String: Any] ?? [:]
            likes["count"] = post.likesCount
            likes["user_likes"] = post.userLikes ? 1 : 0
            itemsJSON[i]["likes"] = likes
            var comments = itemsJSON[i]["comments"] as? [String: Any] ?? [:]
            comments["count"] = post.commentsCount
            itemsJSON[i]["comments"] = comments
            var reposts = itemsJSON[i]["reposts"] as? [String: Any] ?? [:]
            reposts["count"] = post.repostsCount
            itemsJSON[i]["reposts"] = reposts
        }
        response["items"] = itemsJSON
        root["response"] = response
        guard let data = try? JSONSerialization.data(withJSONObject: root) else { return }
        saveCache(data)
    }

    /// Моя лента (друзья + сообщества) или общая лента всех записей.
    enum Kind: Hashable { case my, global }

    override var cacheKey: Kind { kind }
    override var cursorParamName: String { "start_from" }

    private(set) var kind: Kind = .my
    override var pageSize: Int { 25 }

    /// Ответ newsfeed.get/getGlobal: посты + профили/группы авторов + курсор следующей страницы.
    struct Response: Decodable {
        let items: [Post]
        let profiles: [User]?
        let groups: [Community]?
        let nextFrom: String?
        enum CodingKeys: String, CodingKey {
            case items, profiles, groups
            case nextFrom = "next_from"
        }
    }

    override var method: String { kind == .my ? "newsfeed.get" : "newsfeed.getGlobal" }

    override func params(cursor: String?) -> [String: String] {
        var p: [String: String] = [:]
        if let cursor, !cursor.isEmpty { p["start_from"] = cursor }
        return p
    }

    override func mergeAuthors(from response: Response) {
        for u in response.profiles ?? [] {
            authors[u.id] = WallViewModel.Author(name: u.fullName, avatar: u.avatarURL)
        }
        for g in response.groups ?? [] {
            authors[-g.groupID] = WallViewModel.Author(name: g.name, avatar: g.avatarURL)
        }
    }

    override func items(from response: Response) -> [Post] {
        response.items
    }

    override func nextCursor(from response: Response) -> String? {
        response.nextFrom
    }

    override func cacheURL(for key: Kind) -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(key == .my ? "feed_cache_my.json" : "feed_cache_global.json")
    }

    // MARK: - Compatibility with view (maps items -> posts)

    var posts: [Post] { items }

    func delete(_ post: Post, settings: AppSettings) async {
        guard let token = settings.token else { return }
        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        do {
            try await client.execute(
                "wall.delete",
                params: ["owner_id": String(post.ownerID), "post_id": String(post.postID)]
            )
            items.removeAll { $0.id == post.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// После редактирования — перечитывает одну запись (wall.getById) и подменяет её
    /// в ленте, без полного reload.
    func refreshPost(ownerID: Int, postID: Int, settings: AppSettings) async {
        guard let token = settings.token else { return }
        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        do {
            let res: WallResponse = try await client.call("wall.getById", params: ["posts": "\(ownerID)_\(postID)"])
            guard let updated = res.items.first, let idx = items.firstIndex(where: { $0.id == updated.id }) else { return }
            items[idx] = updated
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    /// Переключение «Моя лента»/«Все записи». Здесь список очищаем сразу —
    /// это явное действие пользователя (не жест refresh), старые посты не к месту.
    func switchTo(_ kind: Kind, settings: AppSettings) async {
        guard kind != self.kind else { return }
        self.kind = kind
        await switchKey(kind, settings: settings)
    }

    /// Стирает кэш ленты (при выходе из аккаунта).
    static func clearCache() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: base.appendingPathComponent("feed_cache_my.json"))
        try? FileManager.default.removeItem(at: base.appendingPathComponent("feed_cache_global.json"))
    }

    /// Фоновое обновление «моей ленты» (BGAppRefresh): тихо тянет первую страницу и кладёт
    /// в кэш, чтобы при следующем запуске пользователь сразу увидел почти свежие посты.
    func prefetchForBackground(settings: AppSettings) async {
        guard let token = settings.token else { return }
        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        if let raw = try? await client.rawResponse("newsfeed.get", params: ["count": "25", "extended": "1"]) {
            // Кэшируем только валидный ответ (с "response"), не ошибку.
            let data = Data(raw.utf8)
            if let _: Response = try? OVKClient.decode(data) {
                saveCache(data)
            }
        }
    }
}