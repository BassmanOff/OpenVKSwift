import Foundation

/// Авторизация по логину/паролю через эндпоинт `/token` (direct auth, как у VK).
///
/// Важно: токен запрашиваем у API-домена (`instance.apiURL`), а НЕ у веб-домена.
/// У openvk.org веб-домен закрыт антиботом greyweb (JS-челлендж, 403),
/// а `api.openvk.org` отдаёт и /token, и /method без челленджа.
struct AuthService {
    let instance: Instance

    struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Int?
        let userID: Int

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case userID = "user_id"
        }
    }

    /// Эндпоинт /token у OpenVK отдаёт ошибки в VK-стиле ({error_code, error_msg}),
    /// но на всякий случай поддерживаем и OAuth-форму ({error, error_description}).
    private struct TokenErrorBody: Decodable {
        let error: String?
        let errorDescription: String?
        let errorCode: Int?
        let errorMsg: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
            case errorCode = "error_code"
            case errorMsg = "error_msg"
        }

        var message: String? { errorMsg ?? errorDescription ?? error }
    }

    func signIn(username: String,
                password: String,
                code: String? = nil,
                // `openvk_ios` распознаётся сервером как iOS → статус «онлайн с iPhone».
                clientName: String = "openvk_ios") async throws -> TokenResponse {
        let endpoint = instance.apiURL.appendingPathComponent("token")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw OVKError.badURL
        }

        var items = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password),
            URLQueryItem(name: "grant_type", value: "password"),
            URLQueryItem(name: "client_name", value: clientName)
        ]
        if let code, !code.isEmpty {
            items.append(URLQueryItem(name: "code", value: code))
        }
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

        let decoder = JSONDecoder()
        if let token = try? decoder.decode(TokenResponse.self, from: data) {
            return token
        }
        if let body = try? decoder.decode(TokenErrorBody.self, from: data),
           let message = body.message {
            throw OVKError.api(code: body.errorCode ?? 0, message: message)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw OVKError.http(http.statusCode)
        }
        throw OVKError.empty
    }
}
