import Foundation
import CoreGraphics

/// Фотография VK-формата: набор размеров `sizes:[{type,url,width,height}]`.
struct Photo: Decodable, Identifiable, Hashable {
    let photoID: Int
    let ownerID: Int
    let sizes: [PhotoSize]

    var id: String { "\(ownerID)_\(photoID)" }

    struct PhotoSize: Decodable, Hashable {
        let type: String?
        let url: String?
        let width: Int?
        let height: Int?
    }

    /// Самый большой размер (для просмотра).
    var bestURL: URL? {
        let best = sizes.max { ($0.width ?? 0) < ($1.width ?? 0) }
        return best?.url.flatMap(URL.init(string:))
    }

    /// Размер для превью в сетке (наименьший с шириной ≥ 200, иначе самый большой).
    var thumbURL: URL? {
        let sorted = sizes.sorted { ($0.width ?? 0) < ($1.width ?? 0) }
        let pick = sorted.first { ($0.width ?? 0) >= 200 } ?? sorted.last
        return pick?.url.flatMap(URL.init(string:))
    }

    /// Соотношение сторон (ширина/высота) по самому большому размеру — чтобы не кадрировать фото.
    var aspectRatio: CGFloat? {
        let best = sizes.max { ($0.width ?? 0) < ($1.width ?? 0) }
        guard let w = best?.width, let h = best?.height, w > 0, h > 0 else { return nil }
        return CGFloat(w) / CGFloat(h)
    }

    enum CodingKeys: String, CodingKey {
        case photoID = "id"
        case ownerID = "owner_id"
        case sizes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        photoID = (try? c.decode(Int.self, forKey: .photoID)) ?? 0
        ownerID = (try? c.decode(Int.self, forKey: .ownerID)) ?? 0
        sizes   = (try? c.decode([PhotoSize].self, forKey: .sizes)) ?? []
    }

    /// Синтетическое фото аватарки — сервер не отдаёт её отдельным объектом Photo
    /// (только строкой URL в users.get), а открыть хотим в том же UIKit-просмотрщике,
    /// что и обычные фото. photoID=0 безопасен: используется только этим одиночным фото.
    static func avatar(ownerID: Int, url: URL) -> Photo {
        Photo(photoID: 0, ownerID: ownerID,
              sizes: [PhotoSize(type: "avatar", url: url.absoluteString, width: nil, height: nil)])
    }

    /// Синтетическое фото из голой ссылки (картинка-«вложение» в ЛС — API не отдаёт их
    /// объектом Photo). photoID из хэша URL, чтобы id был уникален (реестр миниатюр
    /// PhotoHeroCoordinator ключуется по id — одинаковые id склеили бы разные фото).
    static func remote(url: URL) -> Photo {
        Photo(photoID: abs(url.absoluteString.hashValue), ownerID: 0,
              sizes: [PhotoSize(type: "remote", url: url.absoluteString, width: nil, height: nil)])
    }

    private init(photoID: Int, ownerID: Int, sizes: [PhotoSize]) {
        self.photoID = photoID
        self.ownerID = ownerID
        self.sizes = sizes
    }
}
