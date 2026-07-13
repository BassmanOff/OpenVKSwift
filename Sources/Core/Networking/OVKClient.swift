import Foundation

struct OVKClient {
    static let userAgent = "OVK-iOS/0.1 (iPhone; iOS 15)"

    let instance: Instance
    let token: String?
    let apiVersion: String

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

    func rawResponse(_ method: String, params: [String: String] = [:]) async throws -> String {
        let data = try await requestRaw(method, params: params)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// `.urlQueryAllowed` (использует и `queryItems=`) считает "+" валидным символом query
    /// и НЕ экранирует его — но сервер (PHP $_GET) трактует "+" как пробел по конвенции
    /// form-urlencoded. Результат: "+" в тексте сообщения/поста молча превращался в пробел.
    /// Экранируем вручную через percentEncodedQueryItems, которые Foundation уже не трогает.
    private static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "+&=")
        return set
    }()

    private func requestRaw(_ method: String, params: [String: String] = [:]) async throws -> Data {
        let endpoint = instance.apiURL
            .appendingPathComponent("method")
            .appendingPathComponent(method)

        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw OVKError.badURL
        }

        func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) ?? s }

        var items = params.map { URLQueryItem(name: $0.key, value: encode($0.value)) }
        items.append(URLQueryItem(name: "v", value: apiVersion))
        if let token { items.append(URLQueryItem(name: "access_token", value: encode(token))) }
        items.append(URLQueryItem(name: "_ovk", value: String(Int.random(in: 0..<Int.max))))
        components.percentEncodedQueryItems = items

        guard let url = components.url else { throw OVKError.badURL }

        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw OVKError.http(http.statusCode)
        }
        return data
    }

    /// Returns (rawData, decodedResponse?) — caller can cache raw data and decode lazily.
    func request<T: Decodable>(_ method: String, params: [String: String] = [:]) async throws -> (Data, T?) {
        let data = try await requestRaw(method, params: params)

        if let env = try? JSONDecoder().decode(Envelope<T>.self, from: data) {
            if let code = env.errorCode {
                throw OVKError.api(code: code, message: env.errorMsg ?? "Ошибка \(code)")
            }
            return (data, env.response)
        }
        throw OVKError.empty
    }

    static func decode<T: Decodable>(_ raw: Data) throws -> T {
        let env = try JSONDecoder().decode(Envelope<T>.self, from: raw)
        if let code = env.errorCode {
            throw OVKError.api(code: code, message: env.errorMsg ?? "Ошибка \(code)")
        }
        guard let r = env.response else { throw OVKError.empty }
        return r
    }

    func uploadImage(_ imageData: Data, to url: URL, field: String = "photo") async throws -> Data {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

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

    private struct WallUploadServer: Decodable { let uploadURL: String; enum CodingKeys: String, CodingKey { case uploadURL = "upload_url" } }
    private struct WallUploadResult: Decodable { let photo: String; let hash: String }

    func uploadWallPhoto(jpeg data: Data) async throws -> String? {
        let server: WallUploadServer = try await call("photos.getWallUploadServer")
        guard let url = URL(string: server.uploadURL) else { return nil }
        let responseData = try await uploadImage(data, to: url)
        let upload = try JSONDecoder().decode(WallUploadResult.self, from: responseData)
        let saved: [Photo] = try await call("photos.saveWallPhoto", params: ["photo": upload.photo, "hash": upload.hash])
        return saved.first.map { "photo\($0.ownerID)_\($0.photoID)" }
    }

    private struct OwnerUploadServer: Decodable { let uploadURL: String; enum CodingKeys: String, CodingKey { case uploadURL = "upload_url" } }
    private struct OwnerUploadResult: Decodable { let photo: String; let hash: String }

    /// Меняет фото профиля/сообщества: сохранённое через photos.saveOwnerPhoto автоматически
    /// становится текущим аватаром (сервер берёт последнее фото альбома аватарок).
    /// `ownerID`: 0 — свой профиль; отрицательный — сообщество (id клуба со знаком минус),
    /// сервер сам проверяет права через canBeModifiedBy (админ) — здесь только сама загрузка.
    func uploadOwnerPhoto(jpeg data: Data, ownerID: Int = 0) async throws {
        let server: OwnerUploadServer = try await call(
            "photos.getOwnerPhotoUploadServer", params: ["owner_id": String(ownerID)]
        )
        guard let url = URL(string: server.uploadURL) else { throw OVKError.empty }
        let responseData = try await uploadImage(data, to: url)
        let upload = try JSONDecoder().decode(OwnerUploadResult.self, from: responseData)
        try await execute("photos.saveOwnerPhoto", params: ["photo": upload.photo, "hash": upload.hash])
    }

    private struct SaveProfileInfoResult: Decodable {
        struct NameRequest: Decodable { let status: String }
        let nameRequest: NameRequest?
        enum CodingKeys: String, CodingKey { case nameRequest = "name_request" }
    }

    /// Основные поля профиля (account.saveProfileInfo). `sex`: 1=женский, 2=мужской (сервер
    /// поддерживает только эти два значения на запись, третьего «не указано» через API нет).
    /// `bdateVisibility`: 1=день+месяц, 2=+год. `home_town`/City сервер НЕ поддерживает
    /// редактирование через API — этот параметр пишет ДРУГОЕ поле (hometown), не то,
    /// что реально отображается в users.get (city) — колонки разные в БД, поэтому здесь нет
    /// параметра города вообще, чтобы не создавать видимость несуществующей возможности.
    func saveProfileInfo(
        firstName: String, lastName: String, screenName: String,
        sex: Int, bdate: String, bdateVisibility: Int,
        status: String, telegram: String
    ) async throws {
        let raw = try await rawResponse("account.saveProfileInfo", params: [
            "first_name": firstName, "last_name": lastName, "screen_name": screenName,
            "sex": String(sex), "bdate": bdate, "bdate_visibility": String(bdateVisibility),
            "status": status, "telegram": telegram
        ])
        guard let data = raw.data(using: .utf8) else { throw OVKError.empty }
        let result: SaveProfileInfoResult = try OVKClient.decode(data)
        if result.nameRequest?.status == "declined" {
            throw OVKError.api(code: 0, message: "Не удалось изменить имя — недопустимые символы")
        }
    }

    /// «О себе» и интересы (account.saveInterestsInfo) — отдельный метод на сервере,
    /// не пересекается с saveProfileInfo. Поля опциональные: nil = не слать вовсе.
    /// Это важно, потому что сервер сохраняет пустую строку "" как реальное значение
    /// (проверка `!is_null && !== current`), а шаблон профиля показывает поле по
    /// `{if !is_null(...)}` — то есть "" рисуется пустым блоком. Значит нетронутое пустое
    /// поле слать нельзя, иначе оно перезапишет null пустой строкой и «появится» на сайте.
    func saveInterestsInfo(
        about: String?, interests: String?, music: String?,
        movies: String?, tv: String?, books: String?, quote: String?, games: String?
    ) async throws {
        var params: [String: String] = [:]
        if let about { params["about"] = about }
        if let interests { params["interests"] = interests }
        if let music { params["fav_music"] = music }
        if let movies { params["fav_films"] = movies }
        if let tv { params["fav_shows"] = tv }
        if let books { params["fav_books"] = books }
        if let quote { params["fav_quote"] = quote }
        if let games { params["fav_games"] = games }
        guard !params.isEmpty else { return }   // нечего менять — не дёргаем сервер
        try await execute("account.saveInterestsInfo", params: params)
    }

    func call<T: Decodable>(_ method: String, params: [String: String] = [:]) async throws -> T {
        let data = try await requestRaw(method, params: params)
        return try OVKClient.decode(data)
    }

    /// Execute write/scalar method — validates success = JSON with "response" key.
    func execute(_ method: String, params: [String: String] = [:]) async throws {
        let raw = try await rawResponse(method, params: params)
        guard let data = raw.data(using: .utf8) else { throw OVKError.empty }
        // Check for error envelope first
        if let env = try? JSONDecoder().decode(Envelope<String>.self, from: data), let code = env.errorCode {
            throw OVKError.api(code: code, message: env.errorMsg ?? "Ошибка \(code)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["response"] != nil else { throw OVKError.empty }
    }
}