import UIKit

/// Возвращает свайп «назад», когда системная кнопка «Назад» скрыта своей (напр. в ChatView
/// показываем только шеврон). По умолчанию iOS отключает жест при кастомной кнопке — здесь
/// делаем контроллер делегатом жеста и разрешаем его, пока есть куда возвращаться.
extension UINavigationController: UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
