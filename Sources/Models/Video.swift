import Foundation
import CoreGraphics

/// Видеозапись (video.get). Нативные — прямой mp4 (files.mp4_*), внешние (youtube) — ссылка плеера.
struct Video: Decodable, Identifiable, Hashable {
    let videoID: Int
    let ownerID: Int
    let title: String
    let duration: Int
    let imageURL: String?
    let width: Int?
    let height: Int?
    /// Прямой mp4 (для нативных видео) — максимальное качество (для стриминга).
    let mp4URL: String?
    /// mp4 умеренного качества — для конвейера подготовки (скачивается целиком,
    /// поэтому 720/480 сильно быстрее старта, чем 1080).
    let mp4ModerateURL: String?
    /// Ссылка плеера (для внешних/youtube, когда нет mp4).
    let playerURL: String?
    /// Платформа внешнего видео ("youtube" и т.п.); nil у нативных.
    let platform: String?

    var id: String { "\(ownerID)_\(videoID)" }
    var thumbURL: URL? { imageURL.flatMap(URL.init(string:)) }
    /// Прямой поток для AVPlayer (нативное видео).
    var streamURL: URL? { mp4URL.flatMap(URL.init(string:)) }
    /// Источник для конвейера подготовки (умеренное качество, полная загрузка).
    var pipelineURL: URL? { (mp4ModerateURL ?? mp4URL).flatMap(URL.init(string:)) }
    /// Ссылка для веб-плеера (внешнее видео).
    var embedURL: URL? { playerURL.flatMap(URL.init(string:)) }

    var aspectRatio: CGFloat? {
        guard let w = width, let h = height, w > 0, h > 0 else { return nil }
        return CGFloat(w) / CGFloat(h)
    }

    var durationText: String {
        let m = duration / 60
        let s = duration % 60
        return String(format: "%d:%02d", m, s)
    }

    private struct ImageSize: Decodable { let url: String? }

    enum CodingKeys: String, CodingKey {
        case videoID = "id"
        case ownerID = "owner_id"
        case title, duration, image, width, height, files, player, platform
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        videoID  = (try? c.decode(Int.self, forKey: .videoID)) ?? 0
        ownerID  = (try? c.decode(Int.self, forKey: .ownerID)) ?? 0
        title    = (try? c.decode(String.self, forKey: .title)) ?? ""
        duration = (try? c.decode(Int.self, forKey: .duration)) ?? 0
        width    = try? c.decode(Int.self, forKey: .width)
        height   = try? c.decode(Int.self, forKey: .height)

        let images = (try? c.decode([ImageSize].self, forKey: .image)) ?? []
        imageURL = images.last?.url

        // files: { "mp4_480": "...", ... } — берём максимальное доступное качество.
        let files = (try? c.decode([String: String].self, forKey: .files)) ?? [:]
        mp4URL = ["mp4_1080", "mp4_720", "mp4_480", "mp4_360", "mp4_240"]
            .compactMap { files[$0] }
            .first { !$0.isEmpty }
        // Для полной загрузки предпочитаем умеренное качество (экрану телефона хватает).
        mp4ModerateURL = ["mp4_720", "mp4_480", "mp4_360", "mp4_1080", "mp4_240"]
            .compactMap { files[$0] }
            .first { !$0.isEmpty }

        playerURL = try? c.decode(String.self, forKey: .player)
        platform  = try? c.decode(String.self, forKey: .platform)
    }
}
