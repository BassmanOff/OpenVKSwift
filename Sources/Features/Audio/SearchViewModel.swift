import SwiftUI

/// Глобальный поиск по музыке: треки (audio.search) + альбомы (audio.searchAlbums).
@MainActor
final class SearchViewModel: ObservableObject {
    @Published private(set) var tracks: [Audio] = []
    @Published private(set) var albums: [Album] = []
    @Published private(set) var isLoading = false
    /// Запрос короче минимума полнотекстового индекса OpenVK (3 символа) — искать бесполезно.
    @Published private(set) var tooShort = false
    @Published var errorMessage: String?

    /// Минимум символов для поиска: у MySQL/MariaDB FULLTEXT ft_min_word_len = 3–4,
    /// поэтому запросы из 1–2 символов не находят НИЧЕГО (это ограничение сервера, не бага).
    static let minQueryLength = 3

    func clear() {
        tracks = []
        albums = []
        errorMessage = nil
        tooShort = false
        isLoading = false
    }

    func run(query: String, settings: AppSettings) async {
        guard let token = settings.token else { return }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { clear(); return }

        // Короткий запрос — сразу подсказка, без запроса к серверу.
        if q.count < Self.minQueryLength {
            tracks = []; albums = []; errorMessage = nil; isLoading = false
            tooShort = true
            return
        }
        tooShort = false

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let client = OVKClient(
            instance: settings.instance,
            token: token,
            apiVersion: settings.apiVersion
        )

        var anyOK = false

        // Убираем спец-символы BOOLEAN MODE, чтобы не сломать запрос (`+ - * " ( ) ~ < > @ %`).
        let sanitized = q.components(separatedBy: CharacterSet(charactersIn: "+-*\"()~<>@%")).joined(separator: " ")
        let words = sanitized.split(separator: " ").filter { !$0.isEmpty }
        // Треки: audio.search использует FULLTEXT BOOLEAN MODE (поиск по целым словам),
        // поэтому добавляем wildcard `*` к каждому слову — тогда «jew» находит «jew3ss».
        let ftQuery = words.map { $0 + "*" }.joined(separator: " ")
        // На случай, если после чистки ничего не осталось — используем исходный запрос.
        let trackQuery = ftQuery.isEmpty ? q : ftQuery
        do {
            let res: ItemsResponse<Audio> = try await client.call(
                "audio.search",
                params: ["q": trackQuery, "count": "100"]
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
