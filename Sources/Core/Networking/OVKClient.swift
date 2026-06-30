import Foundation

/// Клиент VK-совместимого API OpenVK.
/// Вызовы вида `{apiURL}/method/{method}?...&access_token=...&v=...`
struct OVKClient {
    static let userAgent = "OVK-iOS/0.1 (iPhone; iOS 15)"

    let instance: Instance
    let token: String?
    let apiVersion: String

    private struct Envelope<T: Decodable>: Decodable {
        let response: T?
        let error: APIErrorBody?
    }

    private struct APIErrorBody: Decodable {
        let errorCode: Int
        let errorMsg: String

        enum CodingKeys: String, CodingKey {
            case errorCode = "error_code"
            case errorMsg = "error_msg"
        }
    }

    func call<T: Decodable>(_ method: String, params: [String: String] = [:]) async throws -> T {
        let endpoint = instance.apiURL
            .appendingPathComponent("method")
            .appendingPathComponent(method)

        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw OVKError.badURL
        }

        var items = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "v", value: apiVersion))
        if let token { items.append(URLQueryItem(name: "access_token", value: token)) }
        components.queryItems = items

        guard let url = components.url else { throw OVKError.badURL }

        var request = URLRequest(url: url)
        request.setValue(OVKClient.userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw OVKError.network(error)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw OVKError.http(http.statusCode)
        }

        let envelope: Envelope<T>
        do {
            envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        } catch {
            throw OVKError.decoding(error)
        }

        if let err = envelope.error {
            if err.errorCode == 5 { throw OVKError.notAuthorized }
            throw OVKError.api(code: err.errorCode, message: err.errorMsg)
        }
        guard let result = envelope.response else { throw OVKError.empty }
        return result
    }

    /// Сырой JSON-ответ метода целиком — для диагностики (например, что сервер отдаёт по «обрабатываемому» треку).
    func rawResponse(_ method: String, params: [String: String] = [:]) async throws -> String {
        let endpoint = instance.apiURL
            .appendingPathComponent("method")
            .appendingPathComponent(method)
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw OVKError.badURL
        }
        var items = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "v", value: apiVersion))
        if let token { items.append(URLQueryItem(name: "access_token", value: token)) }
        components.queryItems = items
        guard let url = components.url else { throw OVKError.badURL }

        var request = URLRequest(url: url)
        request.setValue(OVKClient.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Выполняет метод, у которого важен только факт успеха (add/delete/bookmark возвращают скаляр).
    /// Бросает `OVKError.api`, если сервер вернул ошибку.
    func execute(_ method: String, params: [String: String] = [:]) async throws {
        let raw = try await rawResponse(method, params: params)
        struct ErrorOnly: Decodable {
            struct Body: Decodable {
                let errorCode: Int
                let errorMsg: String
                enum CodingKeys: String, CodingKey {
                    case errorCode = "error_code"
                    case errorMsg = "error_msg"
                }
            }
            let error: Body?
        }
        if let data = raw.data(using: .utf8),
           let env = try? JSONDecoder().decode(ErrorOnly.self, from: data),
           let err = env.error {
            throw OVKError.api(code: err.errorCode, message: err.errorMsg)
        }
    }
}
