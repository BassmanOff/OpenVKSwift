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
    /// Фото уже опубликованной записи (при редактировании) — уже на сервере, грузить заново
    /// не нужно, в attachments идут по ref "photo{owner}_{id}", как аудио/видео/файлы.
    @Published var existingPhotos: [Photo] = []
    /// Голосование уже опубликованной записи — можно только оставить как есть или убрать
    /// целиком (редактирование вопроса/вариантов не поддерживаем, см. edit()).
    @Published var existingPoll: Poll?
    /// Максимум одно голосование на пост (как в VK/OpenVK). Создаётся на сервере только
    /// при публикации — см. publish().
    @Published var pollDraft: PollDraft?
    @Published var isPosting = false
    @Published var errorMessage: String?

    /// Сервер режет ОБЩУЮ строку attachments до maxAttachments, не по типам отдельно —
    /// поэтому считаем фото, треки, видео, файлы и голосование вместе.
    private var attachmentCount: Int {
        existingPhotos.count + images.count + audioTracks.count + videos.count + docs.count
            + (pollDraft != nil || existingPoll != nil ? 1 : 0)
    }

    /// Разрешено добавлять новое голосование, только если у поста ещё нет прикреплённого.
    var canAddPoll: Bool { existingPoll == nil }

    func removeExistingPhoto(at index: Int) {
        guard existingPhotos.indices.contains(index) else { return }
        existingPhotos.remove(at: index)
    }
    func removeExistingPoll() { existingPoll = nil }

    /// Заполняет черновик данными существующей записи — используется экраном редактирования.
    func loadForEdit(_ post: Post) {
        text = post.text
        existingPhotos = post.photos
        audioTracks = post.audios
        videos = post.videos
        docs = post.docs
        existingPoll = post.poll
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
        guard canAddPoll, pollDraft != nil || canAddMoreImages else { return }
        pollDraft = draft
    }
    func removePoll() { pollDraft = nil }

    /// Готовит строку attachments: существующие фото/голосование по ref, новые фото —
    /// с загрузкой на сервер, аудио/видео/файлы — по ref (уже на сервере). Общая часть
    /// publish() (wall.post) и edit() (wall.edit) — оба шлют одинаковый набор вложений.
    private func buildAttachments(client: OVKClient) async throws -> [String] {
        var attachments: [String] = []

        if let poll = existingPoll {
            attachments.append("poll\(poll.id)")
        } else if let draft = pollDraft {
            // Голосование создаём первым и абортим весь publish при ошибке — в отличие от
            // фото (пропускаем неудачные), пост "про голосование" без него бессмысленен.
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

        for photo in existingPhotos {
            attachments.append("photo\(photo.ownerID)_\(photo.photoID)")
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
        return attachments
    }

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
            let attachments = try await buildAttachments(client: client)
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

    /// Сохраняет изменения существующей записи (wall.edit). `fromGroup` — сохранить/снять
    /// признак «от имени сообщества» (иначе сервер на КАЖДОМ edit молча сбрасывает флаги
    /// поста в 0, см. Wall::edit — $post->setFlags($flags) выполняется безусловно).
    func edit(ownerID: Int, postID: Int, settings: AppSettings, fromGroup: Bool = false) async -> Bool {
        guard let token = settings.token, canPost else { return false }
        isPosting = true
        errorMessage = nil
        defer { isPosting = false }

        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        do {
            let attachments = try await buildAttachments(client: client)
            try await client.execute(
                "wall.edit",
                params: [
                    "owner_id": String(ownerID),
                    "post_id": String(postID),
                    "message": text,
                    "attachments": attachments.joined(separator: ","),
                    "from_group": fromGroup ? "1" : "0"
                ]
            )
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
