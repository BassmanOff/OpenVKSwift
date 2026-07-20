import SwiftUI

/// Добавление/удаление треков в «Мою музыку» и альбомов в «Мои плейлисты».
/// Состояние оптимистичное: UI меняется сразу, при ошибке откатываем.
@MainActor
final class LibraryManager: ObservableObject {
    @Published private var addedTracks: Set<String> = []
    @Published private var removedTracks: Set<String> = []
    @Published private var bookmarkedAlbums: Set<String> = []
    @Published private var unbookmarkedAlbums: Set<String> = []

    /// Короткое уведомление для тоста (что добавили/удалили или что не вышло).
    @Published var toast: String?

    private weak var downloads: AudioDownloadManager?
    func attach(downloads: AudioDownloadManager) { self.downloads = downloads }

    // MARK: - Состояние

    func isAdded(_ track: Audio) -> Bool {
        if removedTracks.contains(track.id) { return false }
        if addedTracks.contains(track.id) { return true }
        return track.added
    }

    func isBookmarked(_ album: Album) -> Bool {
        if unbookmarkedAlbums.contains(album.id) { return false }
        if bookmarkedAlbums.contains(album.id) { return true }
        return album.bookmarked
    }

    /// Разово подтягивает серверный список моих плейлистов, чтобы isBookmarked был верен
    /// даже когда сам Album пришёл без флага bookmarked (audio.getPlaylistById его не отдаёт —
    /// открытие плейлиста по ссылке иначе всегда показывало «не в плейлистах»).
    private var bookmarksHydrated = false
    func hydrateBookmarks(settings: AppSettings) async {
        guard !bookmarksHydrated, let token = settings.token else { return }
        bookmarksHydrated = true
        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        guard let res: ItemsResponse<Album> = try? await client.call(
            "audio.getPlaylists", params: ["owner_id": "0", "count": "100"]
        ) else { bookmarksHydrated = false; return } // не вышло — попробуем в следующий раз
        for album in res.items where album.bookmarked {
            if !unbookmarkedAlbums.contains(album.id) { bookmarkedAlbums.insert(album.id) }
        }
    }

    // MARK: - Действия

    func toggleTrack(_ track: Audio, settings: AppSettings) {
        let add = !isAdded(track)
        if add {
            addedTracks.insert(track.id); removedTracks.remove(track.id)
        } else {
            removedTracks.insert(track.id); addedTracks.remove(track.id)
        }
        Task {
            let ok = await perform(
                add ? "audio.add" : "audio.delete",
                params: ["audio_id": String(track.audioID), "owner_id": String(track.ownerID)],
                settings: settings
            )
            if ok {
                toast = add ? "Добавлено в мою музыку" : "Удалено из моей музыки"
                // Автозагрузка добавленного трека (если включено в настройках).
                if add, settings.autoDownloadMyTracks, track.isPlayable {
                    downloads?.download(track)
                }
            } else {
                // откат
                if add { addedTracks.remove(track.id) } else { removedTracks.remove(track.id) }
                toast = "Не удалось изменить «Мою музыку»"
            }
        }
    }

    func toggleAlbum(_ album: Album, settings: AppSettings) {
        let add = !isBookmarked(album)
        if add {
            bookmarkedAlbums.insert(album.id); unbookmarkedAlbums.remove(album.id)
        } else {
            unbookmarkedAlbums.insert(album.id); bookmarkedAlbums.remove(album.id)
        }
        Task {
            let ok = await perform(
                add ? "audio.bookmarkAlbum" : "audio.unBookmarkAlbum",
                params: ["id": String(album.albumID)],
                settings: settings
            )
            if ok {
                toast = add ? "Альбом добавлен в плейлисты" : "Альбом убран из плейлистов"
            } else {
                if add { bookmarkedAlbums.remove(album.id) } else { unbookmarkedAlbums.remove(album.id) }
                toast = "Не удалось изменить «Мои плейлисты»"
            }
        }
    }

    // MARK: - Private

    private func perform(_ method: String, params: [String: String], settings: AppSettings) async -> Bool {
        guard let token = settings.token else { return false }
        let client = OVKClient(
            instance: settings.instance,
            token: token,
            apiVersion: settings.apiVersion
        )
        do {
            try await client.execute(method, params: params)
            return true
        } catch {
            return false
        }
    }
}
