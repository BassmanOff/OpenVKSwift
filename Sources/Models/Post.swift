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
    let likesCount: Int
    let userLikes: Bool
    let commentsCount: Int
    let repostsCount: Int
    /// Устройство, с которого опубликован пост (post_source.platform) — для значка «с iPhone» под постом.
    let platform: User.OnlinePlatform
    /// Пересланная запись (copy_history) — оригинал репоста с его текстом/вложениями.
    let repost: Repost?

    var id: String { "\(ownerID)_\(postID)" }

    /// Лёгкая копия пересланной записи (без рекурсии и счётчиков).
    struct Repost: Hashable {
        let fromID: Int
        let date: Int
        let text: String
        let photos: [Photo]
        let audios: [Audio]
    }

    // MARK: - Decoding

    enum CodingKeys: String, CodingKey {
        case postID = "id"
        case fromID = "from_id"
        case ownerID = "owner_id"
        case date, text, attachments, likes, comments, reposts
        case postSource = "post_source"
        case copyHistory = "copy_history"
    }
    private enum LikesKeys: String, CodingKey { case count; case userLikes = "user_likes" }
    private enum PostSourceKeys: String, CodingKey { case platform }
    private struct CountObj: Decodable { let count: Int? }

    private struct Attachment: Decodable {
        let photo: Photo?
        let audio: Audio?
        enum CodingKeys: String, CodingKey { case photo, audio }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            photo = try? c.decode(Photo.self, forKey: .photo)
            audio = try? c.decode(Audio.self, forKey: .audio)
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
        if var arr = try? c.nestedUnkeyedContainer(forKey: .attachments) {
            while !arr.isAtEnd {
                guard let att = try? arr.decode(Attachment.self) else { break }
                if let p = att.photo { ph.append(p) }
                if let a = att.audio { au.append(a) }
            }
        }
        photos = ph
        audios = au

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
            repost = Repost(fromID: first.fromID, date: first.date, text: first.text,
                            photos: first.photos, audios: first.audios)
        } else {
            repost = nil
        }
    }
}

/// Ответ wall.get с extended=1: посты + профили/группы авторов.
struct WallResponse: Decodable {
    let count: Int?
    let items: [Post]
    let profiles: [User]?
    let groups: [Community]?
}
