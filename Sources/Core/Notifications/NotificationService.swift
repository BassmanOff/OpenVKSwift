import Foundation
import UserNotifications
import BackgroundTasks

/// Маршрут из уведомления: тап по баннеру → открыть нужный диалог.
/// AppDelegate кладёт сюда peerID, MainTabView/ConversationsView разруливают.
@MainActor
final class NotificationRouter: ObservableObject {
    static let shared = NotificationRouter()
    @Published var pendingPeerID: Int?
    /// Тап по баннеру активности → открыть «Ответы» (MainTabView переключает вкладку,
    /// NewsfeedView пушит ActivityView и сбрасывает флаг).
    @Published var pendingActivity = false
}

/// Локальные уведомления о новых сообщениях.
/// APNs-пушей нет (нет сертификата разработчика; дистрибуция TrollStore/SideStore),
/// поэтому уведомления рождаются на устройстве: из LongPoll (приложение открыто или
/// живёт в фоне с играющей музыкой) и из периодической фоновой проверки (BGAppRefresh).
enum NotificationService {
    /// Компоненты бейджа на иконке приложения. iOS 15 не умеет ставить бейдж
    /// отдельно от уведомления — он обновляется только при доставке, поэтому держим
    /// две части по отдельности и ставим их сумму при каждой доставке, чтобы
    /// активность и сообщения не затирали друг друга.
    private static var messageBadge = 0
    private static var activityBadge = 0
    private static var combinedBadge: NSNumber { NSNumber(value: messageBadge + activityBadge) }

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
        // Бейдж на иконке: сумма непрочитанных сообщений + активности (iOS 15 —
        // бейдж обновляется только вместе с доставкой уведомления, копим две компоненты).
        if let badge {
            messageBadge = badge
            content.badge = combinedBadge
        }
        let request = UNNotificationRequest(identifier: "msg\(messageID)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// ЕДИНАЯ обработка ответа notifications.get для переднего плана (ActivityViewModel)
    /// и фона (BackgroundRefresh): находит свежее против watermark'а «о чём уже показывали
    /// баннер» (activity_notified_date), двигает его и показывает баннер.
    ///
    /// ВАЖНО: watermark НЕ зависит от серверного last_viewed — тот двигается при markAsViewed
    /// (открытие «Ответов») и «съедал» баннеры об активности, пришедшей после. Бейджем
    /// заведует отдельная логика (ActivityViewModel.unreadCount на базе last_viewed).
    static func processActivity(_ res: NotificationsResponse, canBanner: Bool, activityCount: Int = 0) {
        let key = "activity_notified_date"
        let defaults = UserDefaults.standard
        let lastNotified = defaults.integer(forKey: key)
        let maxAll = res.items.map(\.date).max() ?? 0
        // Первый запуск (watermark пуст): фиксируем базовую линию БЕЗ баннера,
        // иначе показали бы «Новая активность (30)» на всю историю.
        guard lastNotified > 0 else {
            defaults.set(maxAll, forKey: key)
            return
        }
        let fresh = res.items.filter { $0.type != nil && $0.date > lastNotified }
        guard !fresh.isEmpty else { return }
        defaults.set(maxAll, forKey: key)
        // ponytail: компоненту активности держим актуальной независимо от показа
        // баннера (бейдж на иконке обновится при следующей доставке — и баннере, и сообщении).
        activityBadge = activityCount
        guard canBanner else { return }

        var names: [Int: String] = [:]
        for u in res.profiles ?? [] { names[u.id] = u.fullName }
        for g in res.groups ?? [] { names[-g.groupID] = g.name }
        notifyActivity(fresh: fresh, names: names, identifierDate: maxAll)
    }

    /// Показывает уведомление о новой активности («Ответы»). Общий код для фонового опроса
    /// (BackgroundRefresh) И переднего плана (ActivityViewModel), чтобы формат не разъезжался.
    static func notifyActivity(fresh: [ActivityNotification], names: [Int: String], identifierDate: Int, activityCount: Int = 0) {
        guard let latest = fresh.max(by: { $0.date < $1.date }) else { return }
        let actorName = latest.actorID.flatMap { names[$0] }
        let line = actorName.map { "\($0) \(latest.phrase)" } ?? latest.standalonePhrase
        let content = UNMutableNotificationContent()
        content.title = fresh.count > 1 ? "Новая активность (\(fresh.count))" : line
        content.body = latest.snippet ?? line
        content.sound = .default
        content.threadIdentifier = "activity"
        content.userInfo = ["activity": true]
        // Бейдж на иконке = активность + сообщения (combinedBadge).
        activityBadge = activityCount
        content.badge = combinedBadge
        let request = UNNotificationRequest(identifier: "activity_\(identifierDate)", content: content, trigger: nil)
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
        await NewsfeedViewModel().prefetchForBackground(settings: settings)

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

    /// Проверяет новую активность («Ответы») и уведомляет о ней локально
    /// (общая логика с передним планом — NotificationService.processActivity).
    @MainActor
    private static func checkActivity(client: OVKClient) async {
        guard let res: NotificationsResponse = try? await client.call(
            "notifications.get", params: ["count": "20"]
        ) else { return }
        // Непросмотренная активность (после watermark'а) — для бейджа на иконке.
        let lastNotified = UserDefaults.standard.integer(forKey: "activity_notified_date")
        let unread = res.items.filter { $0.type != nil && $0.date > lastNotified }.count
        NotificationService.processActivity(res, canBanner: true, activityCount: unread)
    }
}
