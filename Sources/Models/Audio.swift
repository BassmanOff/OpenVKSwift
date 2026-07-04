import Foundation

struct Audio: Codable, Hashable, Identifiable {
    let audioID: Int
    let ownerID: Int
    let artist: String
    let title: String
    let duration: Int
    /// Прямой MP3-URL. У OpenVK приходит строкой ИЛИ `false` (Bool) —
    /// `false` для треков, что ещё не готовы / изъяты / отданы только через DASH.
    let url: String?
    /// MPEG-DASH манифест (для защищённых треков; играется отдельно через ClearKey).
    let manifest: String?
    /// Снят по копирайту — не воспроизводится нигде (даже на сайте OpenVK).
    let withdrawn: Bool
    /// Готов к воспроизведению (обработан сервером и не снят).
    let ready: Bool
    /// Добавлен ли трек в «Мою музыку» текущего пользователя.
    let added: Bool
    /// Альбом, к которому привязан трек (если есть) — отсюда берём обложку.
    let album: Album?

    /// Обложка трека = обложка его альбома (если трек к нему привязан).
    var coverURL: URL? { album?.coverImageURL }

    /// Уникальный ключ трека (для файлов загрузок и сравнения).
    var id: String { "\(ownerID)_\(audioID)" }
    var key: String { id }

    var playbackURL: URL? {
        guard let url, !url.isEmpty else { return nil }
        return URL(string: url)
    }

    /// Можно ли воспроизвести «как есть» (есть прямой MP3).
    var isPlayable: Bool { playbackURL != nil }

    /// Трек ещё обрабатывается сервером — можно повторить попытку позже (как «приманка» на сайте).
    var isProcessing: Bool { !ready && !withdrawn && !isPlayable }

    var durationText: String {
        let m = duration / 60
        let s = duration % 60
        return String(format: "%d:%02d", m, s)
    }

    enum CodingKeys: String, CodingKey {
        case audioID = "id"
        case ownerID = "owner_id"
        case artist
        case title
        case duration
        case url
        case manifest
        case withdrawn
        case ready
        case added
        case album
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        audioID   = try c.decode(Int.self, forKey: .audioID)
        ownerID   = try c.decode(Int.self, forKey: .ownerID)
        artist    = (try? c.decode(String.self, forKey: .artist)) ?? ""
        title     = (try? c.decode(String.self, forKey: .title)) ?? ""
        duration  = (try? c.decode(Int.self, forKey: .duration)) ?? 0
        // OpenVK отдаёт url/manifest строкой или false — берём строку, иначе nil.
        url       = Audio.flexibleString(c, .url)
        manifest  = Audio.flexibleString(c, .manifest)
        withdrawn = (try? c.decode(Bool.self, forKey: .withdrawn)) ?? false
        ready     = (try? c.decode(Bool.self, forKey: .ready)) ?? true
        added     = (try? c.decode(Bool.self, forKey: .added)) ?? false
        album     = try? c.decode(Album.self, forKey: .album)
    }

    /// Декодирует значение, которое может быть строкой или false/числом, как опциональную строку.
    private static func flexibleString(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        if let s = try? c.decode(String.self, forKey: key), !s.isEmpty { return s }
        return nil
    }
}

/// Обёртка ответа VK-методов вида { count, items: [...] }.
struct ItemsResponse<T: Decodable>: Decodable {
    let count: Int
    let items: [T]
}
