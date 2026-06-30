import SwiftUI

/// Лайки записей (likes.add / likes.delete) с оптимистичным состоянием.
@MainActor
final class LikesManager: ObservableObject {
    private struct LikeState { var liked: Bool; var count: Int }
    @Published private var overrides: [String: LikeState] = [:]

    func isLiked(_ post: Post) -> Bool { overrides[post.id]?.liked ?? post.userLikes }
    func count(_ post: Post) -> Int { overrides[post.id]?.count ?? post.likesCount }

    func toggle(_ post: Post, settings: AppSettings) {
        let wasLiked = isLiked(post)
        let oldCount = count(post)
        let liked = !wasLiked
        overrides[post.id] = LikeState(liked: liked, count: max(oldCount + (liked ? 1 : -1), 0))

        Task {
            guard let token = settings.token else { return }
            let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
            do {
                try await client.execute(
                    liked ? "likes.add" : "likes.delete",
                    params: ["type": "post", "owner_id": String(post.ownerID), "item_id": String(post.postID)]
                )
            } catch {
                overrides[post.id] = LikeState(liked: wasLiked, count: oldCount) // откат
            }
        }
    }

    /// Лайк по двойному тапу — ставит лайк (но не снимает).
    func like(_ post: Post, settings: AppSettings) {
        guard !isLiked(post) else { return }
        toggle(post, settings: settings)
    }
}
