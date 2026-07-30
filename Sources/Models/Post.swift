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
    /// У поста бывает максимум одно вложение-голосование.
    let poll: Poll?
    let likesCount: Int
    let userLikes: Bool
    let commentsCount: Int
    let repostsCount: Int
    /// Устройство, с которого опубликован пост (post_source.platform) — для значка «с iPhone» под постом.
    let platform: User.OnlinePlatform
    /// Пересланная запись (copy_history) — оригинал репоста с его текстом/вложениями.
    let repost: Repost?
    /// Геометка записи, если она была передана при wall.post.
    let geo: Geo?
    /// Может ли текущий пользователь удалить запись.
    let canDelete: Bool
    /// Может ли текущий пользователь редактировать запись (свои посты — 7 дней, посты
    /// сообщества — пока есть права админа, без ограничения по времени).
    let canEdit: Bool
    /// Прикреплённые файлы (doc). В основной ленте не отображаются, но нужны при
    /// редактировании — иначе wall.edit заменит вложения без них (attachments — replace, не merge).
    let docs: [Document]

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
        let geo: Geo?

        fileprivate init(_ post: Post) {
            if let original = post.repost {
                self = original
            } else {
                ownerID = post.ownerID
                postID = post.postID
                fromID = post.fromID
                date = post.date
                text = post.text
                photos = post.photos
                audios = post.audios
                videos = post.videos
                geo = post.geo
            }
        }
    }

    struct Geo: Decodable, Hashable {
        let latitude: Double
        let longitude: Double
        let name: String

        private enum CodingKeys: String, CodingKey { case coordinates, name }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let coordinates = try c.decode(String.self, forKey: .coordinates)
                .split(separator: ",")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard coordinates.count == 2 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .coordinates, in: c, debugDescription: "Expected latitude,longitude"
                )
            }
            latitude = coordinates[0]
            longitude = coordinates[1]
            name = ((try? c.decode(String.self, forKey: .name)) ?? "Место").decodingHTMLEntities
        }
    }

    // MARK: - Decoding

    enum CodingKeys: String, CodingKey {
        case postID = "id"
        case fromID = "from_id"
        case ownerID = "owner_id"
        case date, text, attachments, likes, comments, reposts
        case postSource = "post_source"
        case copyHistory = "copy_history"
        case geo
        case canDelete = "can_delete"
        case canEdit = "can_edit"
    }
    private enum LikesKeys: String, CodingKey { case count; case userLikes = "user_likes" }
    private enum PostSourceKeys: String, CodingKey { case platform }
    private struct CountObj: Decodable { let count: Int? }

    private struct Attachment: Decodable {
        let photo: Photo?
        let audio: Audio?
        let video: Video?
        let poll: Poll?
        let doc: Document?
        enum CodingKeys: String, CodingKey { case photo, audio, video, poll, doc }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            photo = try? c.decode(Photo.self, forKey: .photo)
            audio = try? c.decode(Audio.self, forKey: .audio)
            video = try? c.decode(Video.self, forKey: .video)
            poll = try? c.decode(Poll.self, forKey: .poll)
            doc = try? c.decode(Document.self, forKey: .doc)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        postID  = (try? c.decode(Int.self, forKey: .postID)) ?? 0
        fromID  = (try? c.decode(Int.self, forKey: .fromID)) ?? 0
        ownerID = (try? c.decode(Int.self, forKey: .ownerID)) ?? 0
        date    = (try? c.decode(Int.self, forKey: .date)) ?? 0
        // decodingHTMLEntities: сервер отдаёт текст пропущенным через htmlspecialchars
        // (см. TRichText::getText) — без раскодирования "<"/">"/"&" показывались бы как есть.
        text    = ((try? c.decode(String.self, forKey: .text)) ?? "").decodingHTMLEntities

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
        var doc: [Document] = []
        var pollAtt: Poll?
        if var arr = try? c.nestedUnkeyedContainer(forKey: .attachments) {
            while !arr.isAtEnd {
                guard let att = try? arr.decode(Attachment.self) else { break }
                if let p = att.photo { ph.append(p) }
                if let a = att.audio { au.append(a) }
                if let v = att.video { vi.append(v) }
                if let d = att.doc { doc.append(d) }
                if let poll = att.poll, pollAtt == nil { pollAtt = poll } // максимум одно голосование на пост
            }
        }
        poll = pollAtt
        photos = ph
        audios = au
        videos = vi
        docs = doc

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
        geo = try? c.decode(Geo.self, forKey: .geo)

        let history = (try? c.decode([Post].self, forKey: .copyHistory)) ?? []
        if let first = history.first {
            repost = Repost(first)
        } else {
            repost = nil
        }

        canDelete = (try? c.decode(Bool.self, forKey: .canDelete))
            ?? (((try? c.decode(Int.self, forKey: .canDelete)) ?? 0) == 1)
        canEdit = (try? c.decode(Bool.self, forKey: .canEdit))
            ?? (((try? c.decode(Int.self, forKey: .canEdit)) ?? 0) == 1)
    }
}

enum PostDateText {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMM 'в' HH:mm"
        return formatter
    }()

    private static let dateWithYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMM yyyy 'в' HH:mm"
        return formatter
    }()

    static func string(_ timestamp: Int, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let calendar = Calendar.current
        let time = timeFormatter.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) {
            return "сегодня в \(time)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "вчера в \(time)"
        }
        let formatter = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            ? dateFormatter : dateWithYearFormatter
        return formatter.string(from: date).replacingOccurrences(of: ".", with: "")
    }
}

/// Ответ wall.get с extended=1: посты + профили/группы авторов.
struct WallResponse: Decodable {
    let count: Int?
    let items: [Post]
    let profiles: [User]?
    let groups: [Community]?
}
