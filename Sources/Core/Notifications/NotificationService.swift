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
    static func notifyMessage(peerID: Int, messageID: Int, text: String, author: String?) {
        let content = UNMutableNotificationContent()
        content.title = author ?? "Новое сообщение"
        content.body = text.isEmpty ? "Новое сообщение" : text
        content.sound = .default
        content.threadIdentifier = "peer\(peerID)" // группировка по диалогам
        content.userInfo = ["peerID": peerID]
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
        guard settings.isLoggedIn, settings.notifyMessages, let token = settings.token else { return }

        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        guard let res: ConversationsResponse = try? await client.call(
            "messages.getConversations",
            params: ["count": "20", "extended": "1"]
        ) else { return }

        let defaults = UserDefaults.standard
        let seen = (defaults.dictionary(forKey: "msg_seen_last_ids") as? [String: Int]) ?? [:]
        var notified = (defaults.dictionary(forKey: notifiedKey) as? [String: Int]) ?? [:]

        var authors: [Int: String] = [:]
        for u in res.profiles ?? [] { authors[u.id] = u.fullName }

        for convo in res.items {
            guard let last = convo.lastMessage, !last.isOut, convo.unreadCount > 0 else { continue }
            let key = String(convo.peerID)
            guard last.id > (seen[key] ?? 0), last.id > (notified[key] ?? 0) else { continue }
            NotificationService.notifyMessage(
                peerID: convo.peerID,
                messageID: last.id,
                text: last.text,
                author: authors[convo.peerID]
            )
            notified[key] = last.id
        }
        defaults.set(notified, forKey: notifiedKey)
    }
}
