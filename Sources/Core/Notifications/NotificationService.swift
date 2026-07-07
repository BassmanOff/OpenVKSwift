import Foundation
import UserNotifications
import BackgroundTasks

/// Маршрут из уведомления: тап по баннеру → открыть нужный диалог.
/// AppDelegate кладёт сюда peerID, MainTabView/ConversationsView разруливают.
@MainActor
final class NotificationRouter: ObservableObject {
    static let shared = NotificationRouter()
    @Published var pendingPeerID: Int?
}

/// Локальные уведомления о новых сообщениях.
/// APNs-пушей нет (нет сертификата разработчика; дистрибуция TrollStore/SideStore),
/// поэтому уведомления рождаются на устройстве: из LongPoll (приложение открыто или
/// живёт в фоне с играющей музыкой) и из периодической фоновой проверки (BGAppRefresh).
enum NotificationService {
    /// Запрашивает разрешение на уведомления (системный алерт показывается один раз).
    static func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Показывает уведомление о сообщении. identifier = msg{id}: повторная отправка
    /// того же сообщения (эхо LongPoll / фоновая проверка) заменяет, а не дублирует.
    static func notifyMessage(peerID: Int, messageID: Int, text: String, author: String?, badge: Int? = nil) {
        let content = UNMutableNotificationContent()
        content.title = author ?? "Новое сообщение"
        content.body = text.isEmpty ? "Новое сообщение" : text
        content.sound = .default
        content.threadIdentifier = "peer\(peerID)" // группировка по диалогам
        content.userInfo = ["peerID": peerID]
        // Бейдж на иконке при закрытом приложении (в фоне его ведёт ConversationsViewModel).
        if let badge { content.badge = NSNumber(value: badge) }
        let request = UNNotificationRequest(identifier: "msg\(messageID)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Периодическая фоновая проверка новых сообщений (когда приложение закрыто/заморожено).
/// iOS будит приложение по своему усмотрению (обычно раз в 15-60 минут) — это не мгновенно,
/// но единственный путь без APNs.
enum BackgroundRefresh {
    static let taskID = "com.ovkclient.app.refresh"
    /// Ключ: peerID → id последнего сообщения, о котором уже уведомляли (не дублируем).
    private static let notifiedKey = "msg_notified_last_ids"

    /// Регистрация обработчика — строго до конца didFinishLaunching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refresh)
        }
    }

    /// Просит iOS разбудить нас не раньше чем через 15 минут (фактически — когда захочет).
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule() // следующая проверка
        let work = Task { @MainActor in
            await check()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    /// Тянет первую страницу диалогов и уведомляет о непрочитанных входящих,
    /// про которые мы ещё не уведомляли и которые пользователь не видел.
    @MainActor
    private static func check() async {
        let settings = AppSettings()
        guard settings.isLoggedIn, let token = settings.token else { return }

        // Тихо обновляем кэш ленты — при следующем запуске посты будут почти свежими.
        await NewsfeedViewModel.prefetchForBackground(settings: settings)

        // Дальше — уведомления (если включены): активность («Ответы») + сообщения.
        guard settings.notifyMessages else { return }

        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)

        await checkActivity(client: client)
        guard let res: ConversationsResponse = try? await client.call(
            "messages.getConversations",
            params: ["count": "20", "extended": "1"]
        ) else { return }

        let defaults = UserDefaults.standard
        let seen = (defaults.dictionary(forKey: "msg_seen_last_ids") as? [String: Int]) ?? [:]
        var notified = (defaults.dictionary(forKey: notifiedKey) as? [String: Int]) ?? [:]

        var authors: [Int: String] = [:]
        for u in res.profiles ?? [] { authors[u.id] = u.fullName }

        // Все непросмотренные входящие (для бейджа на иконке) — сервер знает про ≤1 на диалог.
        let unreadTotal = res.items.reduce(0) { sum, convo in
            guard let last = convo.lastMessage, !last.isOut, convo.unreadCount > 0,
                  last.id > (seen[String(convo.peerID)] ?? 0) else { return sum }
            return sum + convo.unreadCount
        }

        for convo in res.items {
            guard let last = convo.lastMessage, !last.isOut, convo.unreadCount > 0 else { continue }
            let key = String(convo.peerID)
            guard last.id > (seen[key] ?? 0), last.id > (notified[key] ?? 0) else { continue }
            NotificationService.notifyMessage(
                peerID: convo.peerID,
                messageID: last.id,
                text: last.text,
                author: authors[convo.peerID],
                badge: unreadTotal
            )
            notified[key] = last.id
        }
        defaults.set(notified, forKey: notifiedKey)
    }

    /// Проверяет новую активность («Ответы») и уведомляет о ней локально.
    @MainActor
    private static func checkActivity(client: OVKClient) async {
        guard let res: NotificationsResponse = try? await client.call(
            "notifications.get", params: ["count": "20"]
        ) else { return }

        let defaults = UserDefaults.standard
        let lastNotified = defaults.integer(forKey: "activity_notified_date")
        // Не всплываем повторно и не трогаем уже просмотренное (серверный last_viewed).
        let baseline = max(lastNotified, res.lastViewed ?? 0)
        let fresh = res.items.filter { $0.type != nil && $0.date > baseline }
        let maxDate = res.items.map(\.date).max() ?? baseline

        guard !fresh.isEmpty else {
            defaults.set(max(lastNotified, maxDate), forKey: "activity_notified_date")
            return
        }

        var names: [Int: String] = [:]
        for u in res.profiles ?? [] { names[u.id] = u.fullName }
        for g in res.groups ?? [] { names[-g.groupID] = g.name }

        let latest = fresh.max(by: { $0.date < $1.date })!
        let actorName = latest.actorID.flatMap { names[$0] }
        let line = actorName.map { "\($0) \(latest.phrase)" } ?? latest.standalonePhrase
        let content = UNMutableNotificationContent()
        content.title = fresh.count > 1 ? "Новая активность (\(fresh.count))" : line
        content.body = latest.snippet ?? line
        content.sound = .default
        content.threadIdentifier = "activity"
        content.userInfo = ["activity": true]
        let request = UNNotificationRequest(
            identifier: "activity_\(maxDate)", content: content, trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)

        defaults.set(maxDate, forKey: "activity_notified_date")
    }
}
