import Foundation

/// Решает, куда ведёт тап по уведомлению: профиль автора (аватар) или объект действия (тело).
/// Разные типы уведомлений содержат разные поля — для некоторых целей сервер не даёт достаточно
/// данных (например, для `make_you_admin` нет целевого объекта для открытия).
struct NotificationNavigationResolver {

    /// Куда ведёт тап по телу уведомления (не аватару).
    enum BodyDestination {
        /// Открыть пост/комментарий на стене: `openvk.org/wall{ownerID}_{postID}`.
        /// handlesOVKLinks перехватывает и открывает CommentsView.
        case wallPost(ownerID: Int, postID: Int)
        /// Лайк на комментарии: нужно резолвить post_id через wall.getComment(comment_id).
        /// commentID — виртуальный ID комментария (parent.id), commentAuthorID — автор коммента (parent.ownerID).
        case commentLike(commentID: Int, commentAuthorID: Int)
        /// Открыть профиль пользователя или сообщества.
        case profile(userID: Int)
        /// Сервер не предоставил достаточно данных для этого типа.
        case unsupported
    }

    /// Назначение для тапа по телу уведомления.
    /// Аватар всегда ведёт в `profile(actorID)` (если actorID есть).
    /// - Parameter currentUserID: id текущего пользователя. Для уведомлений о своём контенте
    ///   (like_post, comment_*, wall и т.д.) сервер не шлёт toID — владелец = сам пользователь.
    static func resolve(_ notif: ActivityNotification, currentUserID: Int? = nil) -> BodyDestination {
        guard let type = notif.type else {
            let dest = fallbackProfile(notif)
            log(notif, destination: "no type → \(debug(dest))")
            return dest
        }

        let result: BodyDestination

        switch type {
        // Все типы с постом/комментарием на стене: лайк, коммент, ответ на коммент,
        // упоминание в комменте, запись на стене, публикация предложенной записи.
        case "like_post", "comment_post", "comment_photo", "comment_video", "comment_note",
             "wall", "wall_publish":
            result = resolvePost(notif, currentUserID: currentUserID)

        // Репост записи
        case "copy_post":
            result = resolvePost(notif, currentUserID: currentUserID)

        // Упоминания (могут быть в комментариях, постах, сообщениях)
        case let t where t.hasPrefix("mention"):
            result = resolveMention(notif, currentUserID: currentUserID)

        // Назначение руководителем — нет целевого объекта.
        case "make_you_admin":
            result = .unsupported

        default:
            result = fallbackProfile(notif)
        }

        log(notif, destination: "type=\(type) → \(debug(result))")
        return result
    }

    /// Пост на стене: пытаемся достать ownerID и postID.
    /// OpenVK кладёт реальный owner_id в parent.ownerID (получен из Post API struct).
    /// parent.toID у like_post/comment_* — nil (сервер не заполняет).
    ///
    /// Приоритет owner: ownerID > toID > currentUserID > feedback.*
    /// Приоритет postID: parent.id > feedback.id
    ///
    /// ВАЖНО: currentUserID — последнее средство для уведомлений о своём контенте,
    /// где сервер считает владельца очевидным (но для сообществ он неверен).
    /// Для `mention*` owner может быть nil — не используем currentUserID (упоминание
    /// может быть в чужом посте; ждём логов).
    ///
    /// Специальный случай: "like_post" на комментарии.
    /// OpenVK использует один тип "like_post" И для постов, И для комментариев.
    /// Для комментария parent содержит Comment::toNotifApiStruct():
    ///   - parent.id = comment virtual_id (НЕ post_id)
    ///   - parent.owner_id = comment author ID (НЕ post owner)
    ///   - parent.to_id / parent.from_id = nil
    /// Признак: type == "like_post" && parent.id != nil && parent.ownerID != nil && parent.toID == nil
    /// Решаем через wall.getComment(comment_id) → получаем post_id и post_owner_id.
    private static func resolvePost(_ notif: ActivityNotification, currentUserID: Int? = nil) -> BodyDestination {
        #if DEBUG
        let pNil = notif.parent == nil ? "parent=nil " : ""
        let pOw = notif.parent?.ownerID.map { "parent.ownerID=\($0) " } ?? "parent.ownerID=nil "
        let pTo = notif.parent?.toID.map { "parent.toID=\($0) " } ?? "parent.toID=nil "
        let pFr = notif.parent?.fromID.map { "parent.fromID=\($0) " } ?? "parent.fromID=nil "
        let pId = notif.parent?.id.map { "parent.id=\($0) " } ?? "parent.id=nil "
        let fNil = notif.feedback == nil ? "feedback=nil " : ""
        let fOw = notif.feedback?.ownerID.map { "feedback.ownerID=\($0) " } ?? "feedback.ownerID=nil "
        let fTo = notif.feedback?.toID.map { "feedback.toID=\($0) " } ?? "feedback.toID=nil "
        let fId = notif.feedback?.id.map { "feedback.id=\($0) " } ?? "feedback.id=nil "
        print("[Notifications] resolvePost: \(pNil)\(pOw)\(pTo)\(pFr)\(pId)\(fNil)\(fOw)\(fTo)\(fId)")
        #endif

        guard let postID = notif.parent?.id, postID != 0 else {
            // parent.id не задан — произошёл сбой декодинга или беcсмысленный parent
            return .unsupported
        }

        // --- Специфичный случай: лайк на КОММЕНТАРИИ (type="like_post", но parent — это комментарий) ---
        // OpenVK для лайков на комменты использует тот же тип "like_post", что и для постов.
        // В Comment::toNotifApiStruct(): id=comment_id, owner_id=comment_author, to_id/from_id=nil.
        // Для постов Post::toNotifApiStruct(): id=virtual_id, to_id=wall_owner, from_id=post_author.
        // Если parent.toID == nil И parent.ownerID != nil — скорее всего это лайк на коммент.
        if notif.type == "like_post",
           notif.parent?.toID == nil,
           let commentID = notif.parent?.id,
           let commentAuthorID = notif.parent?.ownerID {
            #if DEBUG
            print("[Notifications] resolvePost: detected COMMENT LIKE — commentID=\(commentID) author=\(commentAuthorID), will use wall.getComment")
            #endif
            return .commentLike(commentID: commentID, commentAuthorID: commentAuthorID)
        }
        // ---------------------------------------------------------------

        // 1. parent.ownerID — реальный владелец поста из Post VK API struct
        if let owner = notif.parent?.ownerID {
            #if DEBUG
            print("[Notifications] resolvePost: owner=parent.ownerID(\(owner)) для postID=\(postID)")
            #endif
            return .wallPost(ownerID: owner, postID: postID)
        }
        // 2. parent.toID — запасной вариант (VK-совместимые API иногда шлют)
        if let owner = notif.parent?.toID {
            return .wallPost(ownerID: owner, postID: postID)
        }
        // 3. currentUserID — для своего контента (like_post/comment_*/wall на себе).
        //    Опасно: неверно для сообществ и чужих постов.
        if let uid = currentUserID {
            #if DEBUG
            print("[Notifications] resolvePost: owner=currentUser(\(uid)) для postID=\(postID)")
            #endif
            return .wallPost(ownerID: uid, postID: postID)
        }
        // 4. feedback (на случай, если parent не разобрался)
        if let owner = notif.feedback?.ownerID {
            return .wallPost(ownerID: owner, postID: postID)
        }
        if let owner = notif.feedback?.toID {
            return .wallPost(ownerID: owner, postID: postID)
        }
        // НЕ fallbackProfile: для type-известных уведомлений переход на профиль автора
        // по телу — это ошибка.
        return .unsupported
    }

    /// Упоминание: parent может быть nil (декорится в другую структуру).
    /// Пробуем feedback: {toID=владелец поста, id=commentID} или {toID=владелец, id=postID}.
    /// Если parent.id есть — используем resolvePost (как для других типов).
    private static func resolveMention(_ notif: ActivityNotification, currentUserID: Int? = nil) -> BodyDestination {
        // Если parent.id задан — обычный resolvePost (упоминание в комменте к посту).
        if notif.parent?.id != nil, notif.parent?.id != 0 {
            return resolvePost(notif, currentUserID: currentUserID)
        }
        // parent nil — данные в feedback. Пробуем feedback.toID + feedback.id как wall{owner}_{post}.
        guard let owner = notif.feedback?.toID, let postID = notif.feedback?.id, postID != 0 else {
            return .unsupported
        }
        #if DEBUG
        print("[Notifications] resolveMention: owner=feedback.toID(\(owner)) postID=feedback.id(\(postID))")
        #endif
        return .wallPost(ownerID: owner, postID: postID)
    }

    /// Запасной вариант: открыть профиль автора действия (если известен).
    private static func fallbackProfile(_ notif: ActivityNotification) -> BodyDestination {
        if let actor = notif.actorID {
            return .profile(userID: actor)
        }
        return .unsupported
    }

    private static func debug(_ dest: BodyDestination) -> String {
        switch dest {
        case .wallPost(let o, let p):      return "wallPost(\(o)_\(p))"
        case .commentLike(let c, let a):   return "commentLike(comment=\(c) author=\(a))"
        case .profile(let u):              return "profile(\(u))"
        case .unsupported:                 return "unsupported"
        }
    }

    private static func log(_ notif: ActivityNotification, destination: String) {
        #if DEBUG
        print("[Notifications] tap: \(notif.debugFields) destination=\(destination)")
        #endif
    }
}
