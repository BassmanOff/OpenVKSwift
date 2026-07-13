import SwiftUI

/// Стена пользователя (wall.get, extended=1) с подгрузкой по мере прокрутки.
@MainActor
final class WallViewModel: CachedListViewModel<WallViewModel.WallResponse, Post, Int> {

    struct Author: Codable { let name: String; let avatar: URL? } // Codable — для кэша диалогов

    override var cursorParamName: String { "offset" }
    var ownerID: Int

    var posts: [Post] { items }

    init(ownerID: Int) {
        self.ownerID = ownerID
        super.init(pageSize: 20)
    }

    override var cacheKey: Int { ownerID }
    override var method: String { "wall.get" }

    override func params(cursor: String?) -> [String: String] {
        var p = ["owner_id": String(ownerID)]
        if let cursor { p["offset"] = cursor }
        return p
    }

    /// Ответ wall.get extended=1: посты + профили/группы авторов + count.
    struct WallResponse: Decodable {
        let items: [Post]
        let profiles: [User]?
        let groups: [Community]?
        let count: Int
    }

    override func mergeAuthors(from response: WallResponse) {
        for u in response.profiles ?? [] {
            authors[u.id] = Author(name: u.fullName, avatar: u.avatarURL)
        }
        for g in response.groups ?? [] {
            authors[-g.groupID] = Author(name: g.name, avatar: g.avatarURL)
        }
    }

    override func items(from response: WallResponse) -> [Post] {
        response.items
    }

    override func nextCursor(from response: WallResponse) -> String? {
        response.items.count < pageSize ? nil : String(offset + response.items.count)
    }

    var offset: Int = 0

    func loadIfNeeded(ownerID: Int, settings: AppSettings) async {
        self.ownerID = ownerID
        await loadIfNeeded(settings: settings)
    }

    func reload(ownerID: Int, settings: AppSettings) async {
        self.ownerID = ownerID
        offset = 0
        await reload(settings: settings)
    }

    func loadMore(ownerID: Int, settings: AppSettings) async {
        self.ownerID = ownerID
        await loadMore(settings: settings)
    }

    // MARK: - Дисковый кэш первой страницы стены

    override func cacheURL(for key: Int) -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("wall_cache_\(key).json")
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
            items.removeAll { $0.id == post.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}