import SwiftUI

/// Стена пользователя (wall.get, extended=1) с подгрузкой по мере прокрутки.
@MainActor
final class WallViewModel: ObservableObject {
    struct Author: Codable { let name: String; let avatar: URL? } // Codable — для кэша диалогов

    @Published private(set) var posts: [Post] = []
    @Published private(set) var authors: [Int: Author] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var canLoadMore = true
    @Published var errorMessage: String?

    private var offset = 0
    private let pageSize = 20
    private var loaded = false

    func loadIfNeeded(ownerID: Int, settings: AppSettings) async {
        guard !loaded else { return }
        await reload(ownerID: ownerID, settings: settings)
    }

    /// НЕ очищает посты заранее — старые видны, пока не пришла свежая первая страница
    /// (иначе на refresh список мигает «Записей пока нет»).
    func reload(ownerID: Int, settings: AppSettings) async {
        offset = 0
        canLoadMore = true
        loaded = true
        // Мгновенно показываем закэшированную стену — не ждём сеть при запуске.
        if posts.isEmpty { applyCache(ownerID: ownerID) }
        await loadMore(ownerID: ownerID, settings: settings, replace: true)
    }

    /// Подставляет закэшированную первую страницу стены (только для показа; сеть заменит).
    private func applyCache(ownerID: Int) {
        guard let data = Self.loadCache(ownerID: ownerID),
              let res: WallResponse = try? OVKClient.decode(data) else { return }
        for u in res.profiles ?? [] { authors[u.id] = Author(name: u.fullName, avatar: u.avatarURL) }
        for g in res.groups ?? [] { authors[-g.groupID] = Author(name: g.name, avatar: g.avatarURL) }
        posts = res.items
    }

    func loadMore(ownerID: Int, settings: AppSettings, replace: Bool = false) async {
        guard !isLoading, canLoadMore, let token = settings.token else { return }
        isLoading = true
        defer { isLoading = false }

        let client = OVKClient(
            instance: settings.instance,
            token: token,
            apiVersion: settings.apiVersion
        )
        do {
            // Первую страницу тянем «сырой» — чтобы закэшировать исходный JSON.
            let raw = Data(try await client.rawResponse(
                "wall.get",
                params: [
                    "owner_id": String(ownerID),
                    "offset": String(offset),
                    "count": String(pageSize),
                    "extended": "1"
                ]
            ).utf8)
            let res: WallResponse = try OVKClient.decode(raw)
            for u in res.profiles ?? [] {
                authors[u.id] = Author(name: u.fullName, avatar: u.avatarURL)
            }
            for g in res.groups ?? [] {
                authors[-g.groupID] = Author(name: g.name, avatar: g.avatarURL)
            }
            if replace {
                posts = res.items
                Self.saveCache(raw, ownerID: ownerID) // кэшируем только первую страницу
            } else {
                posts += res.items
            }
            offset += res.items.count
            if res.items.count < pageSize { canLoadMore = false }
        } catch {
            if error.isCancellation { return } // отмена при refresh/смене экрана — не ошибка
            // Кэш/старые посты остаются; ошибку показываем только на пустом экране.
            if posts.isEmpty { errorMessage = error.localizedDescription }
            canLoadMore = false
        }
    }

    // MARK: - Дисковый кэш первой страницы стены

    private static func cacheURL(ownerID: Int) -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("wall_cache_\(ownerID).json")
    }

    private static func saveCache(_ raw: Data, ownerID: Int) {
        try? raw.write(to: cacheURL(ownerID: ownerID), options: .atomic)
    }

    private static func loadCache(ownerID: Int) -> Data? {
        try? Data(contentsOf: cacheURL(ownerID: ownerID))
    }

    /// Стирает все кэши стен (при выходе из аккаунта).
    static func clearCache() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let files = (try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("wall_cache_") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Удаляет запись (wall.delete) и убирает её из списка.
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
}
