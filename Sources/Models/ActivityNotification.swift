import Foundation

/// Одно уведомление из notifications.get: лайк / коммент / упоминание / репост / запись на стене.
/// parent/feedback имеют РАЗНУЮ форму под каждый тип, поэтому декодим лениво (все поля опциональны).
struct ActivityNotification: Decodable, Identifiable, Equatable {
    let type: String?
    let date: Int
    let parent: NotifObject?
    let feedback: NotifObject?

    var id: String { "\(type ?? "?")|\(date)|\(actorID ?? 0)|\(parent?.id ?? 0)" }

    /// Кто совершил действие (лайкнул/прокомментировал/упомянул). Для лайка — в feedback.items.
    /// НЕ берём parent.from_id: для репоста/назначения это сам получатель (не тот, кто действовал),
    /// такие уведомления показываем без имени (standalonePhrase).
    var actorID: Int? { feedback?.fromID ?? feedback?.items?.first?.fromID }

    /// Короткий текст (текст коммента/записи) для превью.
    var snippet: String? {
        let t = (feedback?.text ?? parent?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Куда вести по тапу: запись на стене {owner}_{id}.
    var targetOwnerID: Int? { parent?.toID ?? feedback?.toID }
    var targetPostID: Int? { parent?.id ?? feedback?.id }

    enum CodingKeys: String, CodingKey { case type, date, parent, feedback }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        date = (try? c.decode(Int.self, forKey: .date)) ?? 0
        // try? — если форма parent/feedback неожиданная, просто nil (не рушим весь элемент).
        parent = (try? c.decodeIfPresent(NotifObject.self, forKey: .parent)) ?? nil
        feedback = (try? c.decodeIfPresent(NotifObject.self, forKey: .feedback)) ?? nil
    }

    /// Фраза действия для строки уведомления.
    var phrase: String {
        switch type {
        case "like_post":     return "оценил(а) вашу запись"
        case "copy_post":     return "поделился(ась) вашей записью"
        case "comment_post":  return "прокомментировал(а) вашу запись"
        case "comment_photo": return "прокомментировал(а) ваше фото"
        case "comment_video": return "прокомментировал(а) ваше видео"
        case "comment_note":  return "прокомментировал(а) вашу заметку"
        case "wall":          return "оставил(а) запись у вас на стене"
        case "wall_publish":  return "опубликовал(а) предложённую запись"
        case "make_you_admin": return "назначил(а) вас руководителем"
        case let t? where t.hasPrefix("mention"): return "упомянул(а) вас"
        case let t? where t.hasPrefix("comment"): return "прокомментировал(а)"
        default:              return "новое уведомление"
        }
    }

    /// Фраза для уведомлений БЕЗ автора (репост/назначение/публикация) — сервер не отдаёт «кто».
    var standalonePhrase: String {
        switch type {
        case "copy_post":      return "Вашей записью поделились"
        case "wall_publish":   return "Ваша предложённая запись опубликована"
        case "make_you_admin": return "Вас назначили руководителем сообщества"
        default:               return "Новое уведомление"
        }
    }

    /// SF-иконка типа.
    var icon: String {
        switch type {
        case "like_post":                       return "heart.fill"
        case "copy_post", "wall_publish":        return "arrowshape.turn.up.right.fill"
        case "wall":                             return "square.and.pencil"
        case let t? where t.hasPrefix("mention"): return "at"
        case let t? where t.hasPrefix("comment"): return "bubble.right.fill"
        case "make_you_admin":                   return "star.fill"
        default:                                 return "bell.fill"
        }
    }

    /// Отладочная строка с полями уведомления для диагностики навигации.
    var debugFields: String {
        let pId = parent?.id.map(String.init) ?? "nil"
        let pTo = parent?.toID.map(String.init) ?? "nil"
        let pFr = parent?.fromID.map(String.init) ?? "nil"
        let pOw = parent?.ownerID.map(String.init) ?? "nil"
        let fId = feedback?.id.map(String.init) ?? "nil"
        let fTo = feedback?.toID.map(String.init) ?? "nil"
        let fFr = feedback?.fromID.map(String.init) ?? "nil"
        let fOw = feedback?.ownerID.map(String.init) ?? "nil"
        let fIt = feedback?.items?.map { String($0.fromID ?? 0) }.joined(separator: ",") ?? "nil"
        let to = targetOwnerID.map(String.init) ?? "nil"
        let tp = targetPostID.map(String.init) ?? "nil"
        return "type=\(type ?? "nil") actor=\(actorID ?? -1) p{id=\(pId) to=\(pTo) fr=\(pFr) ow=\(pOw)} f{id=\(fId) to=\(fTo) fr=\(fFr) ow=\(fOw) items=[\(fIt)]} target(o=\(to) p=\(tp))"
    }
}

/// Универсальный объект parent/feedback уведомления — форма разная, все поля опциональны.
struct NotifObject: Decodable, Equatable {
    let id: Int?
    let fromID: Int?
    let toID: Int?
    let ownerID: Int?
    let text: String?
    let items: [ItemFrom]?

    struct ItemFrom: Decodable, Equatable {
        let fromID: Int?
        enum CodingKeys: String, CodingKey { case fromID = "from_id" }
    }
    enum CodingKeys: String, CodingKey {
        case id, text, items
        case fromID = "from_id"
        case toID = "to_id"
        case ownerID = "owner_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decodeIfPresent(Int.self, forKey: .id)
        fromID = try? c.decodeIfPresent(Int.self, forKey: .fromID)
        toID = try? c.decodeIfPresent(Int.self, forKey: .toID)
        ownerID = try? c.decodeIfPresent(Int.self, forKey: .ownerID)
        items = try? c.decodeIfPresent([ItemFrom].self, forKey: .items)
        // decodingHTMLEntities: text — снипет поста/коммента, сервер отдаёт его через
        // htmlspecialchars (TRichText::getText), как и в Post/Comment/Message.
        text = (try? c.decodeIfPresent(String.self, forKey: .text))?.decodingHTMLEntities
    }
}

/// Ответ notifications.get.
struct NotificationsResponse: Decodable {
    let items: [ActivityNotification]
    let profiles: [User]?
    let groups: [Community]?
    let lastViewed: Int?
    enum CodingKeys: String, CodingKey {
        case items, profiles, groups
        case lastViewed = "last_viewed"
    }
}
