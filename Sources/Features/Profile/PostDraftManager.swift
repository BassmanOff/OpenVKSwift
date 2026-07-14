import SwiftUI

/// Снимок несохранённой записи. ЕДИНСТВЕННЫЙ на всё приложение — последний
/// закрытый композер с содержимым перезаписывает предыдущий (как «свёрнутое»
/// приложение в Telegram: одно за раз).
struct PostDraft: Codable {
    var ownerID: Int
    /// Название сообщества (постим на стену группы). nil = личная стена.
    var groupName: String?
    var postAsGroup: Bool
    var signed: Bool
    var text: String
    /// Фото как JPEG (base64 внутри JSON) — несколько снимков в одном атомарном
    /// файле проще, чем каталог с картинками рядом.
    var imagesJPEG: [Data]
    var audioTracks: [Audio]
    var videos: [VideoRef]
    var docs: [Document]
    var pollDraft: PollDraft?

    /// Минимум, нужный композеру от видео: строка вложения (превью+название)
    /// и ref для wall.post. Полный Video не Encodable (кастомный init(from:)
    /// под серверный формат files/image — симметричный encode пришлось бы
    /// подделывать под формат сервера).
    struct VideoRef: Codable {
        var videoID: Int
        var ownerID: Int
        var title: String
        var imageURL: String?
    }
}

extension Video {
    /// Восстановление из черновика: только поля, нужные строке вложения композера
    /// (превью, название, ref) — остальное черновику не требуется.
    init(ref: PostDraft.VideoRef) {
        videoID = ref.videoID
        ownerID = ref.ownerID
        title = ref.title
        imageURL = ref.imageURL
        duration = 0
        width = nil
        height = nil
        mp4URL = nil
        mp4ModerateURL = nil
        playerURL = nil
        platform = nil
    }
}

/// Черновик поста: живёт в памяти + на диске (переживает перезапуск).
/// Чип над таб-баром (MainTabView) показывается, пока draft != nil.
@MainActor
final class PostDraftManager: ObservableObject {
    @Published private(set) var draft: PostDraft?

    init() {
        draft = Self.load()
    }

    // ponytail: синхронная запись (с base64 фото) на главном потоке — раз на
    // закрытие композера; вынести в фоновый Task, если черновик из 10 фото
    // начнёт подтормаживать dismiss.
    func save(_ d: PostDraft) {
        draft = d
        if let data = try? JSONEncoder().encode(d) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    func clear() {
        draft = nil
        try? FileManager.default.removeItem(at: Self.fileURL)
    }

    private static let fileURL: URL = {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("post_draft.json")
    }()

    private static func load() -> PostDraft? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(PostDraft.self, from: data)
    }
}
