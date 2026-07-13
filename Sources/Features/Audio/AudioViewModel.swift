import SwiftUI

@MainActor
final class AudioViewModel: ObservableObject {
    @Published private(set) var tracks: [Audio] = []
    @Published private(set) var albums: [Album] = []
    @Published private(set) var isLoading = false
    @Published private(set) var albumsLoading = false
    private var albumsLoaded = false
    @Published var errorMessage: String?
    /// Понятное объяснение для alert, когда трек не удалось воспроизвести.
    @Published var diagnostic: String?
    /// Сырой JSON того же запроса — на случай, если нужно прислать на анализ.
    @Published var diagnosticRaw: String?

    /// Кэш «Моей музыки» — чтобы список был виден и офлайн.
    private static let cacheURL: URL = {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("my_tracks_cache.json")
    }()

    func load(settings: AppSettings) async {
        guard let token = settings.token else { return }
        // Мгновенно показываем кэш, чтобы список был виден сразу (в т.ч. офлайн).
        if tracks.isEmpty, let cached = Self.loadCache() { tracks = cached }

        isLoading = tracks.isEmpty
        errorMessage = nil
        defer { isLoading = false }

        let client = OVKClient(
            instance: settings.instance,
            token: token,
            apiVersion: settings.apiVersion
        )
        do {
            let result: ItemsResponse<Audio> = try await client.call(
                "audio.get",
                params: ["count": "100"]
            )
            tracks = result.items
            Self.saveCache(result.items)
        } catch {
            if error.isCancellation { return }
            // Офлайн/ошибка: если есть кэш — оставляем его без ошибки, иначе показываем ошибку.
            if tracks.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    private static func saveCache(_ items: [Audio]) {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    private static func loadCache() -> [Audio]? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode([Audio].self, from: data)
    }

    /// Стирает дисковый кэш списка «Моей музыки» — отладка из настроек.
    static func clearCache() {
        try? FileManager.default.removeItem(at: cacheURL)
    }

    /// Загружает аудиозаписи конкретного пользователя (audio.get с owner_id).
    func load(ownerID: Int, settings: AppSettings) async {
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
            let result: ItemsResponse<Audio> = try await client.call(
                "audio.get",
                params: ["owner_id": String(ownerID), "count": "100"]
            )
            tracks = result.items
        } catch {
            if error.isCancellation { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Загружает альбомы/плейлисты владельца (audio.getPlaylists с owner_id).
    /// Используется, например, в аудиозаписях сообщества (переключатель Треки/Альбомы).
    func loadAlbums(ownerID: Int, settings: AppSettings, force: Bool = false) async {
        guard let token = settings.token else { return }
        if albumsLoaded && !force { return }
        albumsLoading = albums.isEmpty
        defer { albumsLoading = false }

        let client = OVKClient(
            instance: settings.instance,
            token: token,
            apiVersion: settings.apiVersion
        )
        do {
            let res: ItemsResponse<Album> = try await client.call(
                "audio.getPlaylists",
                params: ["owner_id": String(ownerID), "count": "100"]
            )
            albums = res.items
            albumsLoaded = true
        } catch {
            if error.isCancellation { return }
            // Тихо: вкладка «Альбомы» просто останется пустой.
        }
    }

    /// Загружает треки конкретного альбома (audio.get с owner_id + album_id).
    func load(album: Album, settings: AppSettings) async {
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
            let result: ItemsResponse<Audio> = try await client.call(
                "audio.get",
                params: [
                    "owner_id": String(album.ownerID),
                    "album_id": String(album.albumID),
                    "count": "100"
                ]
            )
            tracks = result.items
        } catch {
            if error.isCancellation { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Точечно перезапрашивает трек (для тех, что были «в обработке»).
    /// Если сервер закончил обработку — вернётся уже с url и заменит запись в списке.
    func retry(_ track: Audio, settings: AppSettings) async -> Audio? {
        guard let token = settings.token else { return nil }
        let client = OVKClient(
            instance: settings.instance,
            token: token,
            apiVersion: settings.apiVersion
        )
        do {
            // audio.getById отдаёт { count, items: [...] } (как и audio.get).
            let result: ItemsResponse<Audio> = try await client.call(
                "audio.getById",
                params: ["audios": track.id]
            )
            guard let fresh = result.items.first else { return nil }
            if let idx = tracks.firstIndex(where: { $0.id == fresh.id }) {
                tracks[idx] = fresh
            }
            return fresh
        } catch {
            return nil
        }
    }

    /// Возвращает сырой JSON `audio.getById` по треку (диагностика «обрабатываемых»).
    func fetchRaw(_ track: Audio, settings: AppSettings) async -> String {
        guard let token = settings.token else { return "Нет токена" }
        let client = OVKClient(
            instance: settings.instance,
            token: token,
            apiVersion: settings.apiVersion
        )
        do {
            return try await client.rawResponse("audio.getById", params: ["audios": track.id])
        } catch {
            return "Ошибка запроса: \(error.localizedDescription)"
        }
    }
}
