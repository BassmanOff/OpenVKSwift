import SwiftUI

/// Плейлисты текущего пользователя (созданные + добавленные альбомы) — audio.getPlaylists.
@MainActor
final class PlaylistsViewModel: ObservableObject {
    @Published private(set) var albums: [Album] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    private var loaded = false

    func loadIfNeeded(settings: AppSettings) async {
        guard !loaded else { return }
        await load(settings: settings)
    }

    func load(settings: AppSettings) async {
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
            // owner_id=0 → плейлисты текущего пользователя.
            let res: ItemsResponse<Album> = try await client.call(
                "audio.getPlaylists",
                params: ["owner_id": "0", "count": "100"]
            )
            albums = res.items
            loaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
