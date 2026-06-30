import Foundation

/// Видеозапись (video.get). Воспроизведение пока не реализуем — показываем превью/название.
struct Video: Decodable, Identifiable, Hashable {
    let videoID: Int
    let ownerID: Int
    let title: String
    let duration: Int
    let imageURL: String?

    var id: String { "\(ownerID)_\(videoID)" }

    var thumbURL: URL? { imageURL.flatMap(URL.init(string:)) }

    var durationText: String {
        let m = duration / 60
        let s = duration % 60
        return String(format: "%d:%02d", m, s)
    }

    private struct ImageSize: Decodable { let url: String? }

    enum CodingKeys: String, CodingKey {
        case videoID = "id"
        case ownerID = "owner_id"
        case title
        case duration
        case image
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        videoID  = (try? c.decode(Int.self, forKey: .videoID)) ?? 0
        ownerID  = (try? c.decode(Int.self, forKey: .ownerID)) ?? 0
        title    = (try? c.decode(String.self, forKey: .title)) ?? ""
        duration = (try? c.decode(Int.self, forKey: .duration)) ?? 0
        let images = (try? c.decode([ImageSize].self, forKey: .image)) ?? []
        imageURL = images.last?.url   // последний — самый большой
    }
}
