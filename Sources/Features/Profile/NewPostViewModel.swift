import SwiftUI

@MainActor
final class NewPostViewModel: ObservableObject {
    /// Сервер (bootstrap.php parseAttachments) обрезает вложения до этого числа МОЛЧА —
    /// без ошибки, лишние фото просто теряются. Не даём столько прикрепить вообще.
    static let maxAttachments = 10
    /// Post::setContent — LengthException при превышении (postSizes.maxSize, дефолт сервера).
    static let maxTextLength = 60000

    @Published var text = ""
    @Published var images: [UIImage] = []
    @Published var audioTracks: [Audio] = []
    @Published var videos: [Video] = []
    @Published var docs: [Document] = []
    /// Максимум одно голосование на пост (как в VK/OpenVK). Создаётся на сервере только
    /// при публикации — см. publish().
    @Published var pollDraft: PollDraft?
    @Published var isPosting = false
    @Published var errorMessage: String?

    /// Сервер режет ОБЩУЮ строку attachments до maxAttachments, не по типам отдельно —
    /// поэтому считаем фото, треки, видео, файлы и голосование вместе.
    private var attachmentCount: Int {
        images.count + audioTracks.count + videos.count + docs.count + (pollDraft != nil ? 1 : 0)
    }

    var canPost: Bool {
        (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachmentCount > 0)
            && text.count <= Self.maxTextLength
            && (pollDraft?.isValid ?? true)
    }
    var canAddMoreImages: Bool { attachmentCount < Self.maxAttachments }

    func addImage(_ image: UIImage) {
        guard canAddMoreImages else { return }
        images.append(image)
    }
    func removeImage(at index: Int) { guard images.indices.contains(index) else { return }; images.remove(at: index) }

    func addAudio(_ track: Audio) {
        guard canAddMoreImages, !audioTracks.contains(where: { $0.id == track.id }) else { return }
        audioTracks.append(track)
    }
    func removeAudio(at index: Int) { guard audioTracks.indices.contains(index) else { return }; audioTracks.remove(at: index) }

    func addVideo(_ video: Video) {
        guard canAddMoreImages, !videos.contains(where: { $0.id == video.id }) else { return }
        videos.append(video)
    }
    func removeVideo(at index: Int) { guard videos.indices.contains(index) else { return }; videos.remove(at: index) }

    func addDoc(_ doc: Document) {
        guard canAddMoreImages, !docs.contains(where: { $0.id == doc.id }) else { return }
        docs.append(doc)
    }
    func removeDoc(at index: Int) { guard docs.indices.contains(index) else { return }; docs.remove(at: index) }

    func setPoll(_ draft: PollDraft) {
        guard pollDraft != nil || canAddMoreImages else { return }
        pollDraft = draft
    }
    func removePoll() { pollDraft = nil }

    /// Загружает вложения и публикует запись. Возвращает true при успехе.
    /// `fromGroup`/`signed` — публикация от имени сообщества (см. wall.post: флаг реально
    /// применяется сервером только когда ownerID — стена самого сообщества и вызывающий
    /// её админ; в остальных случаях сервер молча игнорирует флаг и постит от вас лично).
    func publish(ownerID: Int, settings: AppSettings, fromGroup: Bool = false, signed: Bool = false) async -> Bool {
        guard let token = settings.token, canPost else { return false }
        isPosting = true
        errorMessage = nil
        defer { isPosting = false }

        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        do {
            var attachments: [String] = []

            // Голосование создаём первым и абортим весь publish при ошибке — в отличие от
            // фото (пропускаем неудачные), пост "про голосование" без него бессмысленен.
            if let draft = pollDraft {
                let answersJSON = String(data: try JSONEncoder().encode(draft.trimmedAnswers), encoding: .utf8) ?? "[]"
                let poll: Poll = try await client.call("polls.create", params: [
                    "question": draft.question.trimmingCharacters(in: .whitespacesAndNewlines),
                    "add_answers": answersJSON,
                    "is_anonymous": draft.isAnonymous ? "1" : "0",
                    "is_multiple": draft.isMultiple ? "1" : "0",
                    "disable_unvote": draft.disableUnvote ? "1" : "0"
                ])
                // Формат ссылки на голосование — БЕЗ owner_id, в отличие от остальных типов:
                // Polls::get(int $id) на сервере принимает только один аргумент, лишние
                // (owner/access_key), которые шлёт parseAttachments (withKey:true), молча
                // отбрасываются PHP — реально используется только первый сегмент как id.
                attachments.append("poll\(poll.id)")
            }

            for image in images {
                if let data = image.normalizedOrientation().jpegData(compressionQuality: 0.9),
                   let att = try await client.uploadWallPhoto(jpeg: data) {
                    attachments.append(att)
                }
            }
            // Трек/видео уже существуют на сервере — просто ссылка, без загрузки файла.
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
                "wall.post",
                params: [
                    "owner_id": String(ownerID),
                    "message": text,
                    "attachments": attachments.joined(separator: ","),
                    "from_group": fromGroup ? "1" : "0",
                    "signed": signed ? "1" : "0"
                ]
            )
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
