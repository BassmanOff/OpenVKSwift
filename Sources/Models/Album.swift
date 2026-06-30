import Foundation

/// Альбом/плейлист OpenVK (audio.searchAlbums / getPlaylists).
struct Album: Codable, Hashable, Identifiable {
    let albumID: Int
    let ownerID: Int
    let title: String
    let description: String
    let size: Int
    let coverURL: String?
    /// Добавлен ли альбом в «Мои плейлисты» текущего пользователя.
    let bookmarked: Bool

    var id: String { "\(ownerID)_\(albumID)" }

    var coverImageURL: URL? {
        guard let coverURL, !coverURL.isEmpty else { return nil }
        return URL(string: coverURL)
    }

    /// «12 треков» с правильным склонением.
    var sizeText: String {
        let mod10 = size % 10
        let mod100 = size % 100
        let word: String
        if mod10 == 1 && mod100 != 11 {
            word = "трек"
        } else if (2...4).contains(mod10) && !(12...14).contains(mod100) {
            word = "трека"
        } else {
            word = "треков"
        }
        return "\(size) \(word)"
    }

    enum CodingKeys: String, CodingKey {
        case albumID = "id"
        case ownerID = "owner_id"
        case title
        case description
        case size
        case coverURL = "cover_url"
        case bookmarked
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        albumID     = try c.decode(Int.self, forKey: .albumID)
        ownerID     = try c.decode(Int.self, forKey: .ownerID)
        title       = (try? c.decode(String.self, forKey: .title)) ?? ""
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        size        = (try? c.decode(Int.self, forKey: .size)) ?? 0
        coverURL    = try? c.decode(String.self, forKey: .coverURL)
        bookmarked  = (try? c.decode(Bool.self, forKey: .bookmarked)) ?? false
    }
}
