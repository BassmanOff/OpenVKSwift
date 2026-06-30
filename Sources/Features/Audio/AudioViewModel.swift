import SwiftUI

@MainActor
final class AudioViewModel: ObservableObject {
    @Published private(set) var tracks: [Audio] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    /// Понятное объяснение для alert, когда трек не удалось воспроизвести.
    @Published var diagnostic: String?
    /// Сырой JSON того же запроса — на случай, если нужно прислать на анализ.
    @Published var diagnosticRaw: String?

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
            let result: ItemsResponse<Audio> = try await client.call(
                "audio.get",
                params: ["count": "100"]
            )
            tracks = result.items
        } catch {
            errorMessage = error.localizedDescription
        }
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
            errorMessage = error.localizedDescription
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
