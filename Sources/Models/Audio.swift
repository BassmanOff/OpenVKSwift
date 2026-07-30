import Foundation

struct Audio: Codable, Hashable, Identifiable {
    let audioID: Int
    let ownerID: Int
    /// Base64-id записи в БД, который использует отдельная веб-страница трека.
    let uniqueID: String?
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
    /// id для audio.getLyrics — приходит, только если у трека есть текст на OpenVK.
    let lyricsID: Int?

    /// Обложка трека = обложка его альбома (если трек к нему привязан).
    var coverURL: URL? { album?.coverImageURL }

    /// Уникальный ключ трека (для файлов загрузок и сравнения).
    var id: String { "\(ownerID)_\(audioID)" }
    var key: String { id }

    var playbackURL: URL? {
        guard let url, !url.isEmpty else { return nil }
        return URL(string: url)
    }

    /// Ссылка на страницу трека: на компьютере её можно открыть и добавить запись в коллекцию.
    func messageAttachmentText(webURL: URL) -> String {
        let pageID = uniqueID
            .flatMap { Data(base64Encoded: $0) }
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap(Int.init) ?? audioID
        return "\(webURL.appendingPathComponent("audio\(ownerID)_\(pageID)").absoluteString)\n\(artist) — \(title)"
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
        case uniqueID = "unique_id"
        case artist
        case title
        case duration
        case url
        case manifest
        case withdrawn
        case ready
        case added
        case album
        case lyricsID = "lyrics_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        audioID   = try c.decode(Int.self, forKey: .audioID)
        ownerID   = try c.decode(Int.self, forKey: .ownerID)
        uniqueID  = try? c.decode(String.self, forKey: .uniqueID)
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
        lyricsID  = try? c.decode(Int.self, forKey: .lyricsID)
    }

    /// Декодирует значение, которое может быть строкой или false/числом, как опциональную строку.
    private static func flexibleString(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        if let s = try? c.decode(String.self, forKey: key), !s.isEmpty { return s }
        return nil
    }
}

struct MessageAudioLink: Equatable {
    let url: URL
    let databaseID: Int
    let title: String
    let artist: String
}

/// Разбирает отправленную нами ссылку на страницу трека и подпись «исполнитель — название».
func messageAudioLink(in text: String) -> MessageAudioLink? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let lineBreak = trimmed.firstIndex(where: \.isNewline)
    let urlText = lineBreak.map { String(trimmed[..<$0]) } ?? trimmed
    let caption = lineBreak.map {
        String(trimmed[trimmed.index(after: $0)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    } ?? ""

    guard let url = URL(string: urlText), let host = url.host?.lowercased() else { return nil }
    let domains = ["openvk.org", "openvk.xyz", "vepurovk.xyz", "vepurovk.fun"]
    guard domains.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) else { return nil }

    let prefix = "/audio"
    guard url.path.hasPrefix(prefix) else { return nil }
    let ids = url.path.dropFirst(prefix.count).split(separator: "_", maxSplits: 1)
    guard ids.count == 2, Int(ids[0]) != nil, let databaseID = Int(ids[1]) else { return nil }

    if let separator = caption.range(of: " — ") {
        let artist = String(caption[..<separator.lowerBound])
        let title = String(caption[separator.upperBound...])
        return MessageAudioLink(
            url: url,
            databaseID: databaseID,
            title: title.isEmpty ? "Аудиозапись" : title,
            artist: artist
        )
    }
    return MessageAudioLink(
        url: url,
        databaseID: databaseID,
        title: caption.isEmpty ? "Аудиозапись" : caption,
        artist: ""
    )
}

/// Обёртка ответа VK-методов вида { count, items: [...] }.
struct ItemsResponse<T: Decodable>: Decodable {
    let count: Int
    let items: [T]
}
