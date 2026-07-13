import SwiftUI

/// Лайки записей (likes.add / likes.delete) с оптимистичным состоянием.
@MainActor
final class LikesManager: ObservableObject {
    private struct LikeState { var liked: Bool; var count: Int }
    @Published private var overrides: [String: LikeState] = [:]
    @Published private var commentOverrides: [Int: LikeState] = [:]

    func isLiked(_ post: Post) -> Bool { overrides[post.id]?.liked ?? post.userLikes }
    func count(_ post: Post) -> Int { overrides[post.id]?.count ?? post.likesCount }

    // MARK: - Лайки комментариев (likes.add type=comment; owner_id сервером игнорируется, ключ = id коммента)

    func isLiked(comment: Comment) -> Bool { commentOverrides[comment.commentID]?.liked ?? comment.userLikes }
    func count(comment: Comment) -> Int { commentOverrides[comment.commentID]?.count ?? comment.likesCount }

    func toggle(comment: Comment, ownerID: Int, settings: AppSettings) {
        let wasLiked = isLiked(comment: comment)
        let oldCount = count(comment: comment)
        let liked = !wasLiked
        commentOverrides[comment.commentID] = LikeState(liked: liked, count: max(oldCount + (liked ? 1 : -1), 0))

        Task {
            let ok = await Self.send(
                liked ? "likes.add" : "likes.delete",
                params: ["type": "comment", "owner_id": String(ownerID), "item_id": String(comment.commentID)],
                settings: settings
            )
            if !ok { commentOverrides[comment.commentID] = LikeState(liked: wasLiked, count: oldCount) }
        }
    }

    func toggle(_ post: Post, settings: AppSettings) {
        let wasLiked = isLiked(post)
        let oldCount = count(post)
        let liked = !wasLiked
        overrides[post.id] = LikeState(liked: liked, count: max(oldCount + (liked ? 1 : -1), 0))

        Task {
            let ok = await Self.send(
                liked ? "likes.add" : "likes.delete",
                params: ["type": "post", "owner_id": String(post.ownerID), "item_id": String(post.postID)],
                settings: settings
            )
            if !ok { overrides[post.id] = LikeState(liked: wasLiked, count: oldCount) }
        }
    }

    /// Выполняет like-запрос. Успехом считаем ТОЛЬКО валидный JSON с "response":
    /// если сервер отдал HTML (страница 500) или error_code — откатываем лайк.
    /// (Так вскрылся серверный баг OpenVK: likes.add временно крашился 500-ми.)
    private static func send(_ method: String, params: [String: String], settings: AppSettings) async -> Bool {
        guard let token = settings.token else { return false }
        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        do {
            let raw = try await client.rawResponse(method, params: params)
            guard let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            return obj["error_code"] == nil && obj["response"] != nil
        } catch {
            return false
        }
    }

    /// Лайк по двойному тапу — ставит лайк (но не снимает).
    func like(_ post: Post, settings: AppSettings) {
        guard !isLiked(post) else { return }
        toggle(post, settings: settings)
    }
}
