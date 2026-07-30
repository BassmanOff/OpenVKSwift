import Foundation

enum OVKError: LocalizedError {
    case badURL
    case network(Error)
    case http(Int)
    case decoding(Error)
    case api(code: Int, message: String)
    case notAuthorized
    case empty

    static func apiResponseError(from data: Data) -> OVKError? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["error_code"] as? Int else { return nil }
        return .api(code: code, message: object["error_msg"] as? String ?? "Ошибка \(code)")
    }

    var errorDescription: String? {
        switch self {
        case .badURL:                return "Некорректный адрес запроса"
        case .network(let e):        return "Ошибка сети: \(e.localizedDescription)"
        case .http(let code):        return "Сервер вернул ошибку (HTTP \(code))"
        case .decoding:              return "Не удалось разобрать ответ сервера"
        case .api(_, let message):   return message
        case .notAuthorized:         return "Сессия истекла, войдите заново"
        case .empty:                 return "Пустой ответ сервера"
        }
    }
}
