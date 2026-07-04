import Foundation

extension Error {
    /// Отмена запроса (URLError.cancelled / Swift CancellationError) — это НЕ настоящая ошибка.
    /// Возникает при pull-to-refresh и смене экрана, когда SwiftUI отменяет .task/.refreshable.
    /// Такие случаи нельзя показывать пользователю как «Сетевая ошибка: cancelled».
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if let urlError = self as? URLError, urlError.code == .cancelled { return true }
        // OVKClient оборачивает транспортные ошибки в OVKError.network — разворачиваем.
        if let ovk = self as? OVKError, case .network(let inner) = ovk { return inner.isCancellation }
        // На случай не-бриджнутого NSError (NSURLErrorDomain, code -999).
        let ns = self as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }
}
