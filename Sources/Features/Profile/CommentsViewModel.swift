import SwiftUI

@MainActor
final class CommentsViewModel: ObservableObject {
    @Published private(set) var comments: [Comment] = []
    @Published private(set) var authors: [Int: WallViewModel.Author] = [:]
    @Published private(set) var post: Post?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    /// Скорректированный id автора коммента (отрицательный для групп, в т.ч. для
    /// on-behalf-коммов, у которых сервер кладёт группу в profiles как DELETED-стаб —
    /// после loadGroupAuthors такие id попадают сюда).
    func effectiveAuthorID(_ comment: Comment) -> Int {
        if comment.fromID < 0 { return comment.fromID }
        if clubIDs.contains(comment.fromID) { return -comment.fromID }
        return comment.fromID
    }

    // Ввод нового комментария
    @Published var text = ""
    @Published var images: [UIImage] = []
    @Published var audioTracks: [Audio] = []
    @Published var videos: [Video] = []
    @Published var docs: [Document] = []
    @Published var isSending = false
    @Published var commentAsGroup = false
    /// Не nil, только если пост лежит на стене сообщества И текущий пользователь — админ
    /// этого сообщества (wall.createComment реально применяет from_group ТОЛЬКО в этом
    /// случае — см. Wall.php createComment: $club резолвится из target-стены поста,
    /// а не из произвольного group_id, так что «от имени группы» доступно только на
    /// постах, которые сами лежат на стене этой группы).
    @Published private(set) var adminGroupName: String?

    /// Comment extends Post на сервере — тот же parseAttachments (общий срез на 10,
    /// не по типам) и тот же postSizes.maxSize (60000) из Post::setContent.
    static let maxAttachments = NewPostViewModel.maxAttachments
    static let maxTextLength = NewPostViewModel.maxTextLength
    private var attachmentCount: Int { images.count + audioTracks.count + videos.count + docs.count }
    var canAddMoreAttachments: Bool { attachmentCount < Self.maxAttachments }

    var canSend: Bool {
        (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachmentCount > 0)
            && text.count <= Self.maxTextLength
    }

    func addImage(_ image: UIImage) {
        guard canAddMoreAttachments else { return }
        images.append(image)
    }
    func addAudio(_ track: Audio) {
        guard canAddMoreAttachments, !audioTracks.contains(where: { $0.id == track.id }) else { return }
        audioTracks.append(track)
    }
    func removeAudio(at index: Int) { guard audioTracks.indices.contains(index) else { return }; audioTracks.remove(at: index) }

    func addVideo(_ video: Video) {
        guard canAddMoreAttachments, !videos.contains(where: { $0.id == video.id }) else { return }
        videos.append(video)
    }
    func removeVideo(at index: Int) { guard videos.indices.contains(index) else { return }; videos.remove(at: index) }

    func addDoc(_ doc: Document) {
        guard canAddMoreAttachments, !docs.contains(where: { $0.id == doc.id }) else { return }
        docs.append(doc)
    }
    func removeDoc(at index: Int) { guard docs.indices.contains(index) else { return }; docs.remove(at: index) }

    /// Подставляет упоминание автора в поле ввода (ответ на комментарий).
    /// Формат `[id123|Имя]` / `[club45|Имя]` OpenVK превращает в ссылку-упоминание.
    func prefillReply(to authorID: Int, name: String?) {
        let screen = authorID >= 0 ? "id\(authorID)" : "club\(-authorID)"
        let display = name ?? screen
        text = "[\(screen)|\(display)], "
    }

    private func client(_ settings: AppSettings) -> OVKClient? {
        guard let token = settings.token else { return nil }
        return OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
    }

    /// Проверяет, можно ли комментировать ЭТОТ пост от имени сообщества (см. adminGroupName).
    func loadGroupIdentity(ownerID: Int, settings: AppSettings) async {
        guard ownerID < 0, let client = client(settings) else { return }
        let groups: [Community]? = try? await client.call(
            "groups.getById",
            params: ["group_id": String(-ownerID), "fields": "is_admin"]
        )
        if let g = groups?.first, g.isAdmin {
            adminGroupName = g.name
        }
    }

    /// Id клубов из extended-ответа (для определения on-behalf коммов, у которых from_id > 0).
    /// Пополняется в `load` (из groups) и в `loadGroupAuthors` (после успешного groups.getById).
    @Published private var clubIDs: Set<Int> = []

    func load(ownerID: Int, postID: Int, settings: AppSettings) async {
        guard let client = client(settings) else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let res: CommentsResponse = try await client.call(
                "wall.getComments",
                params: [
                    "owner_id": String(ownerID),
                    "post_id": String(postID),
                    "count": "100",
                    "need_likes": "1",
                    "sort": "asc",
                    "extended": "1"
                ]
            )
            clubIDs = Set((res.groups ?? []).map { $0.groupID })
            for u in res.profiles ?? [] {
                authors[u.id] = WallViewModel.Author(name: u.fullName, avatar: u.avatarURL)
            }
            for g in res.groups ?? [] {
                authors[-g.groupID] = WallViewModel.Author(name: g.name, avatar: g.avatarURL)
            }
            comments = res.items
            await loadGroupAuthors(client: client)
        } catch {
            if error.isCancellation { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Пытается загрузить комментарии с запасными вариантами postID/ownerID.
    /// Полезно когда сервер кладёт неверный ID в parent.id (например, comment_id вместо post_id).
    func loadWithFallbacks(ownerID: Int, postID: Int, fallbackIDs: [Int], settings: AppSettings) async {
        await load(ownerID: ownerID, postID: postID, settings: settings)
        if comments.isEmpty && errorMessage == nil {
            for altID in fallbackIDs {
                if altID == postID { continue }
                #if DEBUG
                print("[Comments] fallback: trying postID=\(altID) ownerID=\(ownerID)")
                #endif
                await load(ownerID: ownerID, postID: altID, settings: settings)
                if !comments.isEmpty || errorMessage != nil { break }
            }
        }
    }

    /// Устанавливает пост напрямую (когда он уже есть у вызывающего кода).
    func setPost(_ post: Post) {
        self.post = post
    }

    /// Загружает пост через wall.getById для отображения в шапке комментариев.
    /// Используется когда пост не передан вызывающим кодом (например, из ActivityView).
    func loadPost(ownerID: Int, postID: Int, settings: AppSettings) async {
        guard let client = client(settings) else { return }
        do {
            let res: WallResponse = try await client.call(
                "wall.getById",
                params: ["posts": "\(ownerID)_\(postID)"]
            )
            if let fetchedPost = res.items.first {
                self.post = fetchedPost
                for u in res.profiles ?? [] {
                    authors[u.id] = WallViewModel.Author(name: u.fullName, avatar: u.avatarURL)
                }
                for g in res.groups ?? [] {
                    authors[-g.groupID] = WallViewModel.Author(name: g.name, avatar: g.avatarURL)
                }
            }
        } catch {
            if error.isCancellation { return }
            // Тихо игнорируем — комментарии полезны и без поста
        }
    }

    /// Подгружает профиль текущего пользователя в authors, если его там ещё нет.
    /// Нужен потому что wall.getById / wall.getComments НЕ включают профиль текущего
    /// пользователя в массив profiles (сервер считает его «известным»).
    func loadCurrentUser(settings: AppSettings) async {
        guard let userID = settings.userID, authors[userID] == nil,
              let client = client(settings) else { return }
        let users: [User]? = try? await client.call(
            "users.get",
            params: ["user_ids": String(userID), "fields": "photo_200,photo_100,photo_50"]
        )
        if let user = users?.first {
            authors[user.id] = WallViewModel.Author(name: user.fullName, avatar: user.avatarURL)
        }
    }

    /// Подгружает профили всех необходимых авторов для отображения поста:
    /// текущего пользователя + автора поста (если это разные люди).
    /// Вызывается после setPost, чтобы authors dict был заполнен до рендера PostRow.
    ///
    /// ВАЖНО: автор поста может быть сообществом (from_id < 0) — такие id нельзя слать
    /// в users.get: сервер вернёт стаб «DELETED» (шапка поста в комментариях показывала
    /// DELETED вместо имени группы). Отрицательные id резолвим через groups.getById.
    func loadPostAuthors(settings: AppSettings) async {
        guard let client = client(settings) else { return }
        var userIDs = Set<Int>()
        var groupIDs = Set<Int>()
        if let userID = settings.userID, authors[userID] == nil {
            userIDs.insert(userID)
        }
        if let post, authors[post.fromID] == nil {
            if post.fromID < 0 {
                groupIDs.insert(-post.fromID)
            } else {
                userIDs.insert(post.fromID)
            }
        }
        if !userIDs.isEmpty {
            let ids = userIDs.map(String.init).joined(separator: ",")
            let users: [User]? = try? await client.call(
                "users.get",
                params: ["user_ids": ids, "fields": "photo_200,photo_100,photo_50"]
            )
            for u in users ?? [] {
                authors[u.id] = WallViewModel.Author(name: u.fullName, avatar: u.avatarURL)
            }
        }
        if !groupIDs.isEmpty {
            let ids = groupIDs.map(String.init).joined(separator: ",")
            let clubs: [Community]? = try? await client.call(
                "groups.getById",
                params: ["group_ids": ids, "fields": "photo_200,photo_100,photo_50"]
            )
            for g in clubs ?? [] {
                authors[-g.groupID] = WallViewModel.Author(name: g.name, avatar: g.avatarURL)
            }
        }
    }

    /// Комментарии от имени групп: from_id < 0, но сервер НЕ кладёт группы в extended-ответ
    /// getComments — дозапрашиваем имена/аватарки одним groups.getById.
    ///
    /// Дополнительно: сервер (wall.getComments после правок 52a8961) для on-behalf коммов
    /// кладёт группу в `profiles` со стабом `first_name="DELETED"`, а не в `groups`. Такой
    /// положительный from_id с именем "DELETED" пробуем резолвнуть через groups.getById —
    /// если клуб существует, переезжаем автора в `authors[-groupID]` (имя/аватар группы)
    /// и в `clubIDs` (effectiveAuthorID вернёт отрицательный id → тап → /club{id}).
    private func loadGroupAuthors(client: OVKClient) async {
        var need = Set(comments.map { $0.fromID }.filter { $0 < 0 }.map { -$0 })
            .filter { authors[-$0] == nil }
        let deletedPositiveIDs = Set(comments.map { $0.fromID }.filter { $0 > 0 }
            .filter { authors[$0]?.name == "DELETED " || authors[$0]?.name == "DELETED" })
        need.formUnion(deletedPositiveIDs)
        guard !need.isEmpty else { return }
        let ids = need.map(String.init).joined(separator: ",")
        let clubs: [Community]? = try? await client.call(
            "groups.getById",
            params: ["group_ids": ids, "fields": "photo_100,photo_50"]
        )
        for g in clubs ?? [] {
            authors[-g.groupID] = WallViewModel.Author(name: g.name, avatar: g.avatarURL)
            if deletedPositiveIDs.contains(g.groupID) {
                authors.removeValue(forKey: g.groupID)
                clubIDs.insert(g.groupID)
            }
        }
    }

    func send(ownerID: Int, postID: Int, settings: AppSettings) async {
        guard let client = client(settings), canSend, !isSending else { return }
        isSending = true
        defer { isSending = false }
        do {
            var attachments: [String] = []
            for image in images {
                if let data = image.normalizedOrientation().jpegData(compressionQuality: 0.9),
                   let att = try await client.uploadWallPhoto(jpeg: data) {
                    attachments.append(att)
                }
            }
            for track in audioTracks {
                attachments.append("audio\(track.ownerID)_\(track.audioID)")
            }
            for video in videos {
                attachments.append("video\(video.ownerID)_\(video.videoID)")
            }
            for doc in docs {
                attachments.append("doc\(doc.ownerID)_\(doc.id)_\(doc.accessKey)")
            }
            try await client.execute(
                "wall.createComment",
                params: [
                    "owner_id": String(ownerID),
                    "post_id": String(postID),
                    "message": text,
                    "attachments": attachments.joined(separator: ","),
                    "from_group": (commentAsGroup && adminGroupName != nil) ? "1" : "0"
                ]
            )
            text = ""
            images = []
            audioTracks = []
            videos = []
            docs = []
            await load(ownerID: ownerID, postID: postID, settings: settings)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ comment: Comment, settings: AppSettings) async {
        guard let client = client(settings) else { return }
        do {
            try await client.execute("wall.deleteComment", params: ["comment_id": String(comment.commentID)])
            comments.removeAll { $0.id == comment.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
