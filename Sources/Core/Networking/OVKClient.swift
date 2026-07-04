import Foundation

/// Клиент VK-совместимого API OpenVK.
/// Вызовы вида `{apiURL}/method/{method}?...&access_token=...&v=...`
struct OVKClient {
    static let userAgent = "OVK-iOS/0.1 (iPhone; iOS 15)"

    let instance: Instance
    let token: String?
    let apiVersion: String

    // OpenVK кладёт ошибку НЕ в объект `error`, а прямо на верхний уровень:
    // { "error_code": 5, "error_msg": "Not found", ... } (при HTTP 400).
    private struct Envelope<T: Decodable>: Decodable {
        let response: T?
        let errorCode: Int?
        let errorMsg: String?

        enum CodingKeys: String, CodingKey {
            case response
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
        // Кэш-бастер: перед api.openvk.org стоит кэширующий слой (он же ломал LongPoll),
        // из-за которого повторный GET мог отдавать УСТАРЕВШИЙ ответ — например, лайк,
        // поставленный в приложении, «пропадал» после перезапуска. Уникальный параметр
        // + no-cache гарантируют свежие данные (картинки кэшируются отдельно, не тут).
        items.append(URLQueryItem(name: "_ovk", value: String(Int.random(in: 0..<Int.max))))
        components.queryItems = items

        guard let url = components.url else { throw OVKError.badURL }

        var request = URLRequest(url: url)
        request.setValue(OVKClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw OVKError.network(error)
        }

        // ВАЖНО: OpenVK отдаёт ошибки API телом с HTTP 400 (header "Bad API Call"),
        // поэтому сначала пытаемся разобрать конверт, а не бросаем http-ошибку сразу.
        if let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data) {
            if let code = envelope.errorCode {
                throw OVKError.api(code: code, message: envelope.errorMsg ?? "Ошибка \(code)")
            }
            if let result = envelope.response {
                return result
            }
        }

        // Тело не разобралось как конверт.
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw OVKError.http(http.statusCode)
        }
        throw OVKError.empty
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
        // Кэш-бастер + no-cache: пишущие методы (likes.add и т.п.) не должны попадать
        // под кэширующий слой перед api.openvk.org (см. call выше).
        items.append(URLQueryItem(name: "_ovk", value: String(Int.random(in: 0..<Int.max))))
        components.queryItems = items
        guard let url = components.url else { throw OVKError.badURL }

        var request = URLRequest(url: url)
        request.setValue(OVKClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, _) = try await URLSession.shared.data(for: request)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Загружает картинку multipart-ом на upload_url (сервер загрузки фото). Возвращает сырой JSON-ответ.
    func uploadImage(_ imageData: Data, to url: URL, field: String = "photo") async throws -> Data {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(OVKClient.userAgent, forHTTPHeaderField: "User-Agent")

        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(field)\"; filename=\"photo.jpg\"\r\n")
        append("Content-Type: image/jpeg\r\n\r\n")
        body.append(imageData)
        append("\r\n--\(boundary)--\r\n")

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw OVKError.http(http.statusCode)
        }
        return data
    }

    private struct WallUploadServer: Decodable {
        let uploadURL: String
        enum CodingKeys: String, CodingKey { case uploadURL = "upload_url" }
    }
    private struct WallUploadResult: Decodable { let photo: String; let hash: String }

    /// Полный цикл загрузки фото на стену: upload server → multipart → saveWallPhoto → строка вложения.
    /// Используется и для постов, и для комментариев.
    func uploadWallPhoto(jpeg data: Data) async throws -> String? {
        let server: WallUploadServer = try await call("photos.getWallUploadServer")
        guard let url = URL(string: server.uploadURL) else { return nil }
        let responseData = try await uploadImage(data, to: url)
        let upload = try JSONDecoder().decode(WallUploadResult.self, from: responseData)
        let saved: [Photo] = try await call(
            "photos.saveWallPhoto",
            params: ["photo": upload.photo, "hash": upload.hash]
        )
        guard let photo = saved.first else { return nil }
        return "photo\(photo.ownerID)_\(photo.photoID)"
    }

    /// Выполняет метод, у которого важен только факт успеха (add/delete/bookmark возвращают скаляр).
    /// Бросает `OVKError.api`, если сервер вернул ошибку.
    func execute(_ method: String, params: [String: String] = [:]) async throws {
        let raw = try await rawResponse(method, params: params)
        // Ошибка OpenVK — на верхнем уровне (error_code/error_msg), а не в объекте error.
        struct ErrorOnly: Decodable {
            let errorCode: Int?
            let errorMsg: String?
            enum CodingKeys: String, CodingKey {
                case errorCode = "error_code"
                case errorMsg = "error_msg"
            }
        }
        guard let data = raw.data(using: .utf8) else { throw OVKError.empty }
        if let env = try? JSONDecoder().decode(ErrorOnly.self, from: data),
           let code = env.errorCode {
            throw OVKError.api(code: code, message: env.errorMsg ?? "Ошибка \(code)")
        }
        // Успех ДОЛЖЕН быть валидным JSON с ключом "response". Если сервер отдал HTML
        // (страница 500 Tracy) — это НЕ успех, иначе UI показывал бы «выполнено», хотя
        // действие не сохранилось (так «пропадали» лайки: likes.add крашится на сервере).
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["response"] != nil else {
            throw OVKError.empty
        }
    }
}
