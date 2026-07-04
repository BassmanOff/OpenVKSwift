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

    /// Тап по уведомлению — открываем нужный диалог (peerID лежит в userInfo).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let peer = response.notification.request.content.userInfo["peerID"] as? Int {
            Task { @MainActor in
                NotificationRouter.shared.pendingPeerID = peer
            }
        }
        completionHandler()
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
