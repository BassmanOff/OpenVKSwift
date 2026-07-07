import SwiftUI

/// «Ответы» — сводка активности: уведомления (notifications.get: лайки/комменты/упоминания/
/// репосты/записи на стене) + входящие заявки в друзья (friends.getRequests).
@MainActor
final class ActivityViewModel: ObservableObject {
    @Published private(set) var notifications: [ActivityNotification] = []
    @Published private(set) var friendRequests: [User] = []
    /// id → имя/аватар (пользователи и сообщества-авторы активности).
    @Published private(set) var authors: [Int: WallViewModel.Author] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var canLoadMore = true
    @Published var errorMessage: String?
    private(set) var lastViewed = 0

    private var offset = 0
    private let pageSize = 30
    private var loaded = false

    /// Бейдж на колокольчике: новые уведомления (после last_viewed) + заявки в друзья.
    var unreadCount: Int {
        notifications.filter { $0.date > lastViewed }.count + friendRequests.count
    }

    private func client(_ s: AppSettings) -> OVKClient? {
        guard let token = s.token else { return nil }
        return OVKClient(instance: s.instance, token: token, apiVersion: s.apiVersion)
    }

    func loadIfNeeded(settings: AppSettings) async {
        guard !loaded else { return }
        loaded = true
        await reload(settings: settings)
    }

    func reload(settings: AppSettings) async {
        guard let client = client(settings) else { return }
        isLoading = notifications.isEmpty && friendRequests.isEmpty
        errorMessage = nil
        defer { isLoading = false }

        // Уведомления и заявки в друзья — параллельно.
        async let notifsTask = fetchNotifications(client: client, offset: 0)
        async let requestsTask = fetchFriendRequests(client: client)
        let (notifs, requests) = await (notifsTask, requestsTask)

        if let notifs {
            mergeAuthors(profiles: notifs.profiles, groups: notifs.groups)
            notifications = notifs.items.filter { $0.type != nil }
            lastViewed = notifs.lastViewed ?? lastViewed
            offset = pageSize
            canLoadMore = notifs.items.count >= pageSize
        } else if notifications.isEmpty {
            errorMessage = "Не удалось загрузить уведомления"
        }
        if let requests {
            for u in requests { authors[u.id] = WallViewModel.Author(name: u.fullName, avatar: u.avatarURL) }
            friendRequests = requests
        }
    }

    func loadMore(settings: AppSettings) async {
        guard !isLoading, canLoadMore, let client = client(settings), !notifications.isEmpty else { return }
        guard let notifs = await fetchNotifications(client: client, offset: offset) else { return }
        mergeAuthors(profiles: notifs.profiles, groups: notifs.groups)
        let existing = Set(notifications.map(\.id))
        let fresh = notifs.items.filter { $0.type != nil && !existing.contains($0.id) }
        notifications += fresh
        offset += pageSize
        if notifs.items.count < pageSize || fresh.isEmpty { canLoadMore = false }
    }

    /// Отмечает уведомления просмотренными (серверный last_viewed → бейдж гаснет и на других
    /// устройствах). Заявки в друзья остаются, пока их не примут/отклонят.
    func markViewed(settings: AppSettings) async {
        guard let client = client(settings) else { return }
        _ = try? await client.rawResponse("notifications.markAsViewed", params: [:])
        lastViewed = Int(Date().timeIntervalSince1970)
    }

    func accept(_ user: User, settings: AppSettings) async {
        guard let client = client(settings) else { return }
        friendRequests.removeAll { $0.id == user.id } // оптимистично
        _ = try? await client.rawResponse("friends.add", params: ["user_id": String(user.id)])
    }

    func decline(_ user: User, settings: AppSettings) async {
        guard let client = client(settings) else { return }
        friendRequests.removeAll { $0.id == user.id }
        _ = try? await client.rawResponse("friends.delete", params: ["user_id": String(user.id)])
    }

    // MARK: - Private

    private func mergeAuthors(profiles: [User]?, groups: [Community]?) {
        for u in profiles ?? [] { authors[u.id] = WallViewModel.Author(name: u.fullName, avatar: u.avatarURL) }
        for g in groups ?? [] { authors[-g.groupID] = WallViewModel.Author(name: g.name, avatar: g.avatarURL) }
    }

    private func fetchNotifications(client: OVKClient, offset: Int) async -> NotificationsResponse? {
        try? await client.call("notifications.get", params: ["count": String(pageSize), "offset": String(offset)])
    }

    private func fetchFriendRequests(client: OVKClient) async -> [User]? {
        struct R: Decodable { let items: [User]? }
        let r: R? = try? await client.call(
            "friends.getRequests",
            params: ["count": "100", "extended": "1", "fields": "photo_100,photo_50,screen_name,online"]
        )
        return r?.items
    }
}
