import SwiftUI

/// Профиль текущего пользователя (users.get с нужными полями).
@MainActor
final class ProfileViewModel: ObservableObject {
    @Published private(set) var user: User?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    private var loaded = false

    private static let fields =
        "photo_200,photo_100,photo_50,status,screen_name,online,last_seen,city,about,bdate,sex,counters"

    func loadIfNeeded(userID: Int, settings: AppSettings) async {
        guard !loaded else { return }
        await load(userID: userID, settings: settings)
    }

    func load(userID: Int, settings: AppSettings) async {
        guard let token = settings.token else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let client = OVKClient(
            instance: settings.instance,
            token: token,
            apiVersion: settings.apiVersion
        )
        do {
            // user_ids=0 → текущий пользователь; ответ — массив в response.
            let users: [User] = try await client.call(
                "users.get",
                params: ["user_ids": String(userID), "fields": Self.fields]
            )
            user = users.first
            loaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
