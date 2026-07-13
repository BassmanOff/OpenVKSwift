import UIKit
import UserNotifications

/// Управляет разрешёнными ориентациями (портрет по умолчанию, ландшафт для видео),
/// регистрирует фоновую проверку сообщений и обрабатывает тапы по уведомлениям.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Фоновая проверка сообщений: регистрация обязана случиться до конца запуска.
        BackgroundRefresh.register()
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Тап по уведомлению: сообщение (peerID) → нужный диалог, активность → «Ответы».
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 didReceive response: UNNotificationResponse,
                                 withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if let peer = userInfo["peerID"] as? Int {
            Task { @MainActor in
                NotificationRouter.shared.pendingPeerID = peer
            }
        } else if userInfo["activity"] != nil {
            Task { @MainActor in
                NotificationRouter.shared.pendingActivity = true
            }
        }
        completionHandler()
    }

    /// Показ уведомлений, когда приложение активно (в фоне экрана).
    /// По умолчанию iOS гасит баннер при открытом приложении — явно
    /// разрешаем баннер + звук (как Telegram/VK). Бейдж на иконке
    /// обновляется системой независимо от этих опций.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 willPresent notification: UNNotification,
                                 withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }

    /// Разрешить/запретить ландшафт (на время видео). При запрете — вернуть в портрет.
    static func setVideoOrientation(_ enabled: Bool) {
        orientationLock = enabled ? [.portrait, .landscapeLeft, .landscapeRight] : .portrait
        if !enabled { forceRotate(to: .portrait) }
    }

    /// Принудительно повернуть экран (работает даже при блокировке автоповорота в Пункте управления).
    static func forceRotate(to orientation: UIInterfaceOrientation) {
        let mask: UIInterfaceOrientationMask = orientation.isLandscape
            ? [.landscapeLeft, .landscapeRight]
            : .portrait
        // Разрешаем целевую ориентацию, иначе система откажет.
        if orientation.isLandscape {
            orientationLock = [.portrait, .landscapeLeft, .landscapeRight]
        }

        if #available(iOS 16.0, *) {
            let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
            scene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
            scene?.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        } else {
            UIDevice.current.setValue(orientation.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }
}
