import SwiftUI
import Combine

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
    @Published private(set) var lastViewed = 0

    private var offset = 0
    private let pageSize = 30
    private var loaded = false
    /// true, пока идёт reload — чтобы параллельные вызовы (периодический таймер + переход
    /// на вкладку + pull-to-refresh) не наслаивались и не гонялись за lastViewed.
    private var isReloading = false
    /// Периодический опрос «Ответов» (15с): таймер на Main RunLoop, независим от
    /// SwiftUI .task (бесконечные .task-циклы SwiftUI отменяет при переоценке body,
    /// из-за чего список не обновлялся автоматически). OpenVK не шлёт LongPoll по
    /// активности — опрос единственный путь.
    private var pollTimer: AnyCancellable?

    /// Бейдж на колокольчике: непросмотренные (после серверного last_viewed) + заявки в друзья.
    /// НЕ путать с watermark'ом баннеров (activity_notified_date в NotificationService):
    /// «показали баннер» ≠ «пользователь посмотрел». Бейдж гаснет только через markViewed.
    var unreadCount: Int {
        notifications.filter { $0.date > lastViewed }.count + friendRequests.count
    }

    /// true, пока экран «Ответы» на виду (ставит ActivityView) — баннеры о том,
    /// что пользователь и так сейчас видит, не показываем.
    var isBellVisible = false

    private func client(_ s: AppSettings) -> OVKClient? {
        guard let token = s.token else { return nil }
        return OVKClient(instance: s.instance, token: token, apiVersion: s.apiVersion)
    }

    func loadIfNeeded(settings: AppSettings) async {
        guard !loaded else { return }
        loaded = true
        startPolling(settings: settings)
        await reload(settings: settings)
    }

    /// Запускает периодический опрос (идемпотентно). Таймер переживает .task,
    /// поэтому авто-обновление «Ответов» не пропадает при переоценке body вкладки.
    private func startPolling(settings: AppSettings) {
        guard pollTimer == nil else { return }
        // .default откладывает опрос, пока List обрабатывает жест прокрутки.
        pollTimer = Timer.publish(every: 15, on: .main, in: .default)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.reload(settings: settings) }
            }
    }

    func reload(settings: AppSettings) async {
        guard let client = client(settings) else { return }
        // Реентрантность: несколько источников зовут reload (таймер каждые 30с, переход на
        // вкладку, pull-to-refresh, возврат из фона). Без гварда они гоняются за lastViewed.
        guard !isReloading else {
            print("[Notifications] \(debugNow()) reload пропущен (уже идёт)")
            return
        }
        isReloading = true
        defer { isReloading = false }

        let shouldShowLoading = notifications.isEmpty && friendRequests.isEmpty
        if isLoading != shouldShowLoading { isLoading = shouldShowLoading }
        if errorMessage != nil { errorMessage = nil }
        defer { if isLoading { isLoading = false } }

        // Уведомления и заявки в друзья — параллельно.
        async let notifsTask = fetchNotifications(client: client, offset: 0)
        async let requestsTask = fetchFriendRequests(client: client)
        let (notifs, requests) = await (notifsTask, requestsTask)
        mergeAuthors(
            profiles: (notifs?.profiles ?? []) + (requests ?? []),
            groups: notifs?.groups
        )

        if let notifs {
            let freshNotifications = notifs.items.filter { $0.type != nil }
            if notifications != freshNotifications { notifications = freshNotifications }
            // ВАЖНО: watermark только ВПЕРЁД. Берём максимум с серверным last_viewed,
            // чтобы просмотренное не всплыло заново (при задержке серверной обработки markAsViewed).
            let freshLastViewed = max(lastViewed, notifs.lastViewed ?? 0)
            if lastViewed != freshLastViewed { lastViewed = freshLastViewed }
            offset = pageSize
            let hasMore = notifs.items.count >= pageSize
            if canLoadMore != hasMore { canLoadMore = hasMore }
            // Баннеры + бейдж на иконке — ПОСЛЕ обновления списка/lastViewed,
            // чтобы unreadCount был актуальным.
            NotificationService.processActivity(notifs, canBanner: settings.notifyMessages && !isBellVisible, activityCount: unreadCount)
        } else if notifications.isEmpty {
            let message = lastFetchError ?? "Не удалось загрузить уведомления"
            if errorMessage != message { errorMessage = message }
        }
        if let requests {
            if friendRequests != requests { friendRequests = requests }
        }
        print("[Notifications] \(debugNow()) reload готов: notifs=\(notifications.count), заявок=\(friendRequests.count), lastViewed=\(lastViewed), unread=\(unreadCount)")
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
        // Парсим server last_viewed из ответа markAsViewed, чтобы бейдж погас
        // мгновенно (без полной перезагрузки, которая может быть заблокирована isReloading).
        struct MarkResponse: Decodable {
            let last_viewed: Int?
        }
        let resp: MarkResponse? = try? await client.call("notifications.markAsViewed", params: [:])
        if let serverLastViewed = resp?.last_viewed {
            lastViewed = serverLastViewed
        }
        print("[Badge] \(debugNow()) markViewed: lastViewed=\(lastViewed), unread=\(unreadCount)")
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
        var merged = authors
        for u in profiles ?? [] { merged[u.id] = WallViewModel.Author(name: u.fullName, avatar: u.avatarURL) }
        for g in groups ?? [] { merged[-g.groupID] = WallViewModel.Author(name: g.name, avatar: g.avatarURL) }
        if merged != authors { authors = merged }
    }

    /// Текст последней ошибки notifications.get (для показа пользователю вместо пустого экрана).
    /// Напр. «EventDB is disabled on this instance» (код 1289) — уведомлений на инстансе нет
    /// в принципе, это НЕ чинится в клиенте (ЛС работают через отдельный LongPoll, они живы).
    private var lastFetchError: String?

    private func fetchNotifications(client: OVKClient, offset: Int) async -> NotificationsResponse? {
        do {
            let res: NotificationsResponse = try await client.call("notifications.get", params: ["count": String(pageSize), "offset": String(offset)])
            lastFetchError = nil
            return res
        } catch {
            lastFetchError = error.localizedDescription
            #if DEBUG
            print("[Notifications] notifications.get failed: \(error)")
            #endif
            return nil
        }
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
