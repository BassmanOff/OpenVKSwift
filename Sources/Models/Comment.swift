import Foundation

/// Комментарий (wall.getComments). Вложения разбираем в фото/аудио, как у постов.
struct Comment: Decodable, Identifiable, Hashable {
    let commentID: Int
    let fromID: Int
    let date: Int
    let text: String
    let photos: [Photo]
    let audios: [Audio]
    let videos: [Video]
    let likesCount: Int
    let userLikes: Bool
    let canDelete: Bool

    var id: Int { commentID }

    enum CodingKeys: String, CodingKey {
        case commentID = "id"
        case fromID = "from_id"
        case date, text, attachments, likes
        case canDelete = "can_delete"
        // board.getComments кладёт лайки на верхнем уровне (а не в объекте likes).
        case topCount = "count"
        case topUserLikes = "user_likes"
    }
    private enum LikesKeys: String, CodingKey { case count; case userLikes = "user_likes" }

    private struct Attachment: Decodable {
        let photo: Photo?
        let audio: Audio?
        let video: Video?
        enum CodingKeys: String, CodingKey { case type, photo, audio, video }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try? c.decode(String.self, forKey: .type)
            audio = try? c.decode(Audio.self, forKey: .audio)
            video = try? c.decode(Video.self, forKey: .video)
            if let wrapped = try? c.decode(Photo.self, forKey: .photo) {
                photo = wrapped
            } else if type == nil && audio == nil && video == nil {
                // В обсуждениях фото приходит «сырым» объектом (без обёртки {type, photo}).
                photo = try? Photo(from: decoder)
            } else {
                photo = nil
            }
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        commentID = (try? c.decode(Int.self, forKey: .commentID)) ?? 0
        fromID    = (try? c.decode(Int.self, forKey: .fromID)) ?? 0
        date      = (try? c.decode(Int.self, forKey: .date)) ?? 0
        text      = (try? c.decode(String.self, forKey: .text)) ?? ""
        canDelete = ((try? c.decode(Int.self, forKey: .canDelete)) ?? 0) == 1

        if let likes = try? c.nestedContainer(keyedBy: LikesKeys.self, forKey: .likes) {
            likesCount = (try? likes.decode(Int.self, forKey: .count)) ?? 0
            userLikes  = ((try? likes.decode(Int.self, forKey: .userLikes)) ?? 0) == 1
        } else {
            // формат обсуждений: count/user_likes на верхнем уровне
            likesCount = (try? c.decode(Int.self, forKey: .topCount)) ?? 0
            userLikes  = ((try? c.decode(Int.self, forKey: .topUserLikes)) ?? 0) == 1
        }

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
    }
}

/// Ответ wall.getComments (extended=1): комментарии + профили авторов.
/// groups сервер сейчас НЕ присылает (club id кладёт в profiles, где ищутся юзеры) —
/// поле оставлено на будущее, а имена групп дозапрашиваются отдельно (groups.getById).
struct CommentsResponse: Decodable {
    let count: Int?
    let items: [Comment]
    let profiles: [User]?
    let groups: [Community]?
}
