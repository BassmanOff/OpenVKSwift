import SwiftUI

/// Список друзей пользователя (friends.get возвращает объекты пользователей с нужными полями).
@MainActor
final class FriendsViewModel: ObservableObject {
    @Published private(set) var friends: [User] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    private var loaded = false

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
            // user_id=0 → друзья текущего пользователя; поля для аватара и онлайн-устройства.
            let res: ItemsResponse<User> = try await client.call(
                "friends.get",
                params: ["user_id": String(userID), "fields": "photo_100,photo_50,online,last_seen,screen_name", "count": "1000"]
            )
            friends = res.items
            loaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
