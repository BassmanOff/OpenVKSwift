import SwiftUI

@MainActor
final class CommentsViewModel: ObservableObject {
    @Published private(set) var comments: [Comment] = []
    @Published private(set) var authors: [Int: WallViewModel.Author] = [:]
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    // Ввод нового комментария
    @Published var text = ""
    @Published var images: [UIImage] = []
    @Published var isSending = false

    var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty
    }

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

    /// Комментарии от имени групп: from_id < 0, но сервер НЕ кладёт группы в extended-ответ
    /// getComments — дозапрашиваем имена/аватарки одним groups.getById.
    private func loadGroupAuthors(client: OVKClient) async {
        let clubIDs = Set(comments.map { $0.fromID }.filter { $0 < 0 }.map { -$0 })
            .filter { authors[-$0] == nil }
        guard !clubIDs.isEmpty else { return }
        let ids = clubIDs.map(String.init).joined(separator: ",")
        let clubs: [Community]? = try? await client.call(
            "groups.getById",
            params: ["group_ids": ids, "fields": "photo_100,photo_50"]
        )
        for g in clubs ?? [] {
            authors[-g.groupID] = WallViewModel.Author(name: g.name, avatar: g.avatarURL)
        }
    }

    func send(ownerID: Int, postID: Int, settings: AppSettings) async {
        guard let client = client(settings), canSend, !isSending else { return }
        isSending = true
        defer { isSending = false }
        do {
            var attachments: [String] = []
            for image in images {
                if let data = image.jpegData(compressionQuality: 0.9),
                   let att = try await client.uploadWallPhoto(jpeg: data) {
                    attachments.append(att)
                }
            }
            try await client.execute(
                "wall.createComment",
                params: [
                    "owner_id": String(ownerID),
                    "post_id": String(postID),
                    "message": text,
                    "attachments": attachments.joined(separator: ",")
                ]
            )
            text = ""
            images = []
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
