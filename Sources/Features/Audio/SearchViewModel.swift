import SwiftUI

/// Глобальный поиск по музыке: треки (audio.search) + альбомы (audio.searchAlbums).
@MainActor
final class SearchViewModel: ObservableObject {
    @Published private(set) var tracks: [Audio] = []
    @Published private(set) var albums: [Album] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    func clear() {
        tracks = []
        albums = []
        errorMessage = nil
        isLoading = false
    }

    func run(query: String, settings: AppSettings) async {
        guard let token = settings.token else { return }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { clear(); return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let client = OVKClient(
            instance: settings.instance,
            token: token,
            apiVersion: settings.apiVersion
        )

        var anyOK = false

        // Треки: audio.search использует FULLTEXT BOOLEAN MODE (поиск по целым словам),
        // поэтому добавляем wildcard `*` к каждому слову — тогда «jew» находит «jew3ss».
        let ftQuery = q.split(separator: " ").map { $0 + "*" }.joined(separator: " ")
        do {
            let res: ItemsResponse<Audio> = try await client.call(
                "audio.search",
                params: ["q": ftQuery, "count": "100"]
            )
            if Task.isCancelled { return }
            tracks = res.items
            anyOK = true
        } catch {
            if Task.isCancelled { return }
            tracks = []
        }

        // Альбомы: метод audio.searchAlbums ждёт параметр `query`, drop_private=1 убирает null-элементы.
        do {
            let res: ItemsResponse<Album> = try await client.call(
                "audio.searchAlbums",
                params: ["query": q, "limit": "50", "drop_private": "1"]
            )
            if Task.isCancelled { return }
            albums = res.items
            anyOK = true
        } catch {
            if Task.isCancelled { return }
            albums = []
        }

        if !anyOK {
            errorMessage = "Не удалось выполнить поиск"
        }
    }
}
