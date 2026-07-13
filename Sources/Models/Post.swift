import Foundation

/// Запись на стене (wall.get). Вложения разбираем в фото и аудио (остальные пока игнорируем).
struct Post: Decodable, Identifiable, Hashable {
    let postID: Int
    let fromID: Int
    let ownerID: Int
    let date: Int
    let text: String
    let photos: [Photo]
    let audios: [Audio]
    let videos: [Video]
    let likesCount: Int
    let userLikes: Bool
    let commentsCount: Int
    let repostsCount: Int
    /// Устройство, с которого опубликован пост (post_source.platform) — для значка «с iPhone» под постом.
    let platform: User.OnlinePlatform
    /// Пересланная запись (copy_history) — оригинал репоста с его текстом/вложениями.
    let repost: Repost?
    /// Может ли текущий пользователь удалить запись.
    let canDelete: Bool

    var id: String { "\(ownerID)_\(postID)" }

    /// Лёгкая копия пересланной записи (без рекурсии и счётчиков).
    /// ownerID/postID нужны для дозагрузки оригинала (copy_history в API OpenVK
    /// содержит только фото — видео/аудио добираем через wall.getById).
    struct Repost: Hashable {
        let ownerID: Int
        let postID: Int
        let fromID: Int
        let date: Int
        let text: String
        let photos: [Photo]
        let audios: [Audio]
        let videos: [Video]
    }

    // MARK: - Decoding

    enum CodingKeys: String, CodingKey {
        case postID = "id"
        case fromID = "from_id"
        case ownerID = "owner_id"
        case date, text, attachments, likes, comments, reposts
        case postSource = "post_source"
        case copyHistory = "copy_history"
        case canDelete = "can_delete"
    }
    private enum LikesKeys: String, CodingKey { case count; case userLikes = "user_likes" }
    private enum PostSourceKeys: String, CodingKey { case platform }
    private struct CountObj: Decodable { let count: Int? }

    private struct Attachment: Decodable {
        let photo: Photo?
        let audio: Audio?
        let video: Video?
        enum CodingKeys: String, CodingKey { case photo, audio, video }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            photo = try? c.decode(Photo.self, forKey: .photo)
            audio = try? c.decode(Audio.self, forKey: .audio)
            video = try? c.decode(Video.self, forKey: .video)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        postID  = (try? c.decode(Int.self, forKey: .postID)) ?? 0
        fromID  = (try? c.decode(Int.self, forKey: .fromID)) ?? 0
        ownerID = (try? c.decode(Int.self, forKey: .ownerID)) ?? 0
        date    = (try? c.decode(Int.self, forKey: .date)) ?? 0
        text    = (try? c.decode(String.self, forKey: .text)) ?? ""

        if let likes = try? c.nestedContainer(keyedBy: LikesKeys.self, forKey: .likes) {
            likesCount = (try? likes.decode(Int.self, forKey: .count)) ?? 0
            userLikes  = ((try? likes.decode(Int.self, forKey: .userLikes)) ?? 0) == 1
        } else {
            likesCount = 0; userLikes = false
        }
        commentsCount = (try? c.decode(CountObj.self, forKey: .comments))?.count ?? 0
        repostsCount = (try? c.decode(CountObj.self, forKey: .reposts))?.count ?? 0

        var ph: [Photo] = []
        var au: [Audio] = []
        var vi: [Video] = []
        if var arr = try? c.nestedUnkeyedContainer(forKey: .attachments) {
            while !arr.isAtEnd {
                guard let att = try? arr.decode(Attachment.self) else { break }
                if let p = att.photo { ph.append(p) }
                if let a = att.audio { au.append(a) }
                if let v = att.video { vi.append(v) }
            }
        }
        photos = ph
        audios = au
        videos = vi

        var plat: User.OnlinePlatform = .none
        if let ps = try? c.nestedContainer(keyedBy: PostSourceKeys.self, forKey: .postSource),
           let str = try? ps.decode(String.self, forKey: .platform) {
            switch str {
            case "iphone": plat = .iphone
            case "android": plat = .android
            case "mobile": plat = .mobile
            default: plat = .none
            }
        }
        platform = plat

        let history = (try? c.decode([Post].self, forKey: .copyHistory)) ?? []
        if let first = history.first {
            repost = Repost(ownerID: first.ownerID, postID: first.postID,
                            fromID: first.fromID, date: first.date, text: first.text,
                            photos: first.photos, audios: first.audios, videos: first.videos)
        } else {
            repost = nil
        }

        canDelete = ((try? c.decode(Int.self, forKey: .canDelete)) ?? 0) == 1
    }
}

/// Ответ wall.get с extended=1: посты + профили/группы авторов.
struct WallResponse: Decodable {
    let count: Int?
    let items: [Post]
    let profiles: [User]?
    let groups: [Community]?
}
