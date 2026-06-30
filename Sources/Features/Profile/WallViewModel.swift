import SwiftUI

/// Стена пользователя (wall.get, extended=1) с подгрузкой по мере прокрутки.
@MainActor
final class WallViewModel: ObservableObject {
    struct Author { let name: String; let avatar: URL? }

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

    func reload(ownerID: Int, settings: AppSettings) async {
        offset = 0
        canLoadMore = true
        posts = []
        authors = [:]
        loaded = true
        await loadMore(ownerID: ownerID, settings: settings)
    }

    func loadMore(ownerID: Int, settings: AppSettings) async {
        guard !isLoading, canLoadMore, let token = settings.token else { return }
        isLoading = true
        defer { isLoading = false }

        let client = OVKClient(
            instance: settings.instance,
            token: token,
            apiVersion: settings.apiVersion
        )
        do {
            let res: WallResponse = try await client.call(
                "wall.get",
                params: [
                    "owner_id": String(ownerID),
                    "offset": String(offset),
                    "count": String(pageSize),
                    "extended": "1"
                ]
            )
            for u in res.profiles ?? [] {
                authors[u.id] = Author(name: u.fullName, avatar: u.avatarURL)
            }
            for g in res.groups ?? [] {
                authors[-g.groupID] = Author(name: g.name, avatar: g.avatarURL)
            }
            posts += res.items
            offset += res.items.count
            if res.items.count < pageSize { canLoadMore = false }
        } catch {
            errorMessage = error.localizedDescription
            canLoadMore = false
        }
    }
}
