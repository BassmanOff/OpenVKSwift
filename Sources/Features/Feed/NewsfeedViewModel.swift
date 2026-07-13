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
        await reload(settings: settings)
    }

    /// Загружает первую страницу. Старые посты остаются на экране до прихода свежих.
    func reload(settings: AppSettings) async {
        generation += 1
        let gen = generation
        errorMessage = nil
        isLoading = true
        defer { if gen == generation { isLoading = false } }

        do {
            let res = try await fetchPage(startFrom: nil, settings: settings)
            guard gen == generation else { return } // пришёл ответ устаревшего запроса
            mergeAuthors(res)
            posts = dedup(res.items)
            nextFrom = res.nextFrom
            canLoadMore = !(res.nextFrom ?? "").isEmpty && res.items.count >= pageSize
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
        return try await client.call(method, params: params)
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
