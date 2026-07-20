import Foundation

/// Пост + профили/группы авторов (extended=1), см. `post(extended:)`.
struct ResolvedPost {
    let post: Post
    let profiles: [User]
    let groups: [Community]
}

/// Единая точка получения ОДНОГО объекта OpenVK по id — сообщество/фото/видео/плейлист/пост.
/// Раньше это было 7 отдельных копий (5 loader-view в LinkDestinationView.swift + два метода
/// RepostCache в PostRow.swift), каждая заново собирала клиента, проверяла токен и вела свой кэш.
/// Публичный интерфейс — 5 маленьких методов; вся повторяющаяся механика (клиент/токен/кэш/
/// повтор неудач/дедупликация параллельных запросов) — в приватном `fetch`.
@MainActor
final class ObjectResolver {
    static let shared = ObjectResolver()
    private init() {}

    private var communityCache: [Int: Community] = [:]
    private var photoCache: [String: Photo] = [:]
    private var videoCache: [String: Video] = [:]
    private var playlistCache: [String: Album] = [:]
    private var postCache: [String: ResolvedPost] = [:]

    /// Ключи вида "тип:id" — общий набор вместо пяти однотипных Set.
    private var failedKeys: Set<String> = []
    /// Параллельные запросы одного и того же объекта ждут ОДНУ сетевую попытку, а не плодят
    /// дубли (ни одна из 7 прежних копий так не умела).
    private var inFlight: [String: Task<Any?, Never>] = [:]

    /// Стирает всё — личный кэш, чистится при выходе из аккаунта (см. RootView) и из
    /// отладочных настроек (см. SettingsView).
    func clear() {
        communityCache = [:]
        photoCache = [:]
        videoCache = [:]
        playlistCache = [:]
        postCache = [:]
        failedKeys = []
        inFlight = [:]
    }

    func community(id: Int, settings: AppSettings) async -> Community? {
        if let hit = communityCache[id] { return hit }
        guard let result: Community = await fetch(
            key: "community:\(id)", method: "groups.getById",
            params: ["group_id": String(id), "fields": "description,members_count,photo_200,photo_100,is_admin,is_member"],
            settings: settings, extract: { (items: [Community]) in items.first }
        ) else { return nil }
        communityCache[id] = result
        return result
    }

    func photo(ownerID: Int, photoID: Int, settings: AppSettings) async -> Photo? {
        let ref = "\(ownerID)_\(photoID)"
        if let hit = photoCache[ref] { return hit }
        guard let result: Photo = await fetch(
            key: "photo:\(ref)", method: "photos.getById", params: ["photos": ref],
            settings: settings, extract: { (items: [Photo]) in items.first }
        ) else { return nil }
        photoCache[ref] = result
        return result
    }

    func video(ownerID: Int, videoID: Int, settings: AppSettings) async -> Video? {
        let ref = "\(ownerID)_\(videoID)"
        if let hit = videoCache[ref] { return hit }
        guard let result: Video = await fetch(
            key: "video:\(ref)", method: "video.get", params: ["videos": ref],
            settings: settings, extract: { (items: [Video]) in items.first }
        ) else { return nil }
        videoCache[ref] = result
        return result
    }

    func playlist(ownerID: Int, id: Int, settings: AppSettings) async -> Album? {
        let ref = "\(ownerID)_\(id)"
        if let hit = playlistCache[ref] { return hit }
        guard let result: Album = await fetch(
            key: "playlist:\(ref)", method: "audio.getPlaylistById",
            params: ["owner_id": String(ownerID), "playlist_id": String(id)],
            settings: settings, extract: { (album: Album) in album }
        ) else { return nil }
        playlistCache[ref] = result
        return result
    }

    /// `extended` — тянуть ли profiles/groups (автора). Стоит серверу доп. запроса на автора/
    /// группу (см. Wall.php::getById), поэтому только когда автор реально нужен вызывающему —
    /// репост-цитате в ленте он не нужен, карточке ссылки в ЛС нужен.
    func post(ownerID: Int, postID: Int, extended: Bool, settings: AppSettings) async -> ResolvedPost? {
        let ref = "\(ownerID)_\(postID)"
        let key = extended ? "post_ext:\(ref)" : "post:\(ref)"
        if let hit = postCache[key] { return hit }
        var params = ["posts": ref]
        if extended { params["extended"] = "1" }
        guard let result: ResolvedPost = await fetch(
            key: key, method: "wall.getById", params: params, settings: settings,
            extract: { (res: WallResponse) in
                res.items.first.map { ResolvedPost(post: $0, profiles: res.profiles ?? [], groups: res.groups ?? []) }
            }
        ) else { return nil }
        postCache[key] = result
        return result
    }

    /// Общая механика: собрать клиента, проверить токен, вызвать метод, применить `extract`
    /// к сырому декоду — а неудачу (сеть, декод, extract вернул nil) запомнить в failedKeys,
    /// чтобы не долбить сервер повторно тем же битым запросом.
    private func fetch<Raw: Decodable, Result>(
        key: String, method: String, params: [String: String], settings: AppSettings,
        extract: @escaping (Raw) -> Result?
    ) async -> Result? {
        if failedKeys.contains(key) { return nil }
        guard let token = settings.token else { return nil }

        if let running = inFlight[key] {
            return await running.value as? Result
        }

        let task = Task<Any?, Never> { [weak self] in
            let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
            do {
                let raw: Raw = try await client.call(method, params: params)
                guard let result = extract(raw) else {
                    self?.failedKeys.insert(key)
                    return nil
                }
                return result
            } catch {
                if !error.isCancellation { self?.failedKeys.insert(key) }
                return nil
            }
        }
        inFlight[key] = task
        let value = await task.value
        inFlight[key] = nil
        return value as? Result
    }
}
