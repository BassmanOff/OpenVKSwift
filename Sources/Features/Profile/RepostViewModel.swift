import SwiftUI

/// Репост записи: на стену (свою/сообщества) через wall.repost, либо ссылкой в ЛС
/// (API OpenVK не отдаёт вложения в ЛС обратно, поэтому шлём просто текстом-ссылкой).
@MainActor
final class RepostViewModel: ObservableObject {
    @Published var errorMessage: String?

    private func makeClient(_ settings: AppSettings) -> OVKClient? {
        guard let token = settings.token else { return nil }
        return OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
    }

    /// `groupID` — id сообщества (положительный) для репоста на стену сообщества, nil — на свою.
    /// На стену сообщества репостим от имени самого сообщества (as_group=1), как и обычная
    /// публикация по умолчанию делает при постинге на стену группы (см. NewPostView.postAsGroup).
    func repostToWall(post: Post, groupID: Int?, settings: AppSettings) async -> Bool {
        guard let client = makeClient(settings) else { return false }
        errorMessage = nil
        var params = ["object": "wall\(post.ownerID)_\(post.postID)"]
        if let groupID {
            params["group_id"] = String(groupID)
            params["as_group"] = "1"
        }
        do {
            try await client.execute("wall.repost", params: params)
            return true
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
            return false
        }
    }

    /// Отправляет ссылку на запись в ЛС (peerID == свой id — «Избранное»/себе).
    func sendLink(post: Post, peerID: Int, settings: AppSettings) async -> Bool {
        guard let client = makeClient(settings) else { return false }
        errorMessage = nil
        let link = "\(settings.instance.webURL.absoluteString)/wall\(post.ownerID)_\(post.postID)"
        do {
            let _: Int = try await client.call("messages.send", params: ["peer_id": String(peerID), "message": link])
            return true
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
            return false
        }
    }
}
