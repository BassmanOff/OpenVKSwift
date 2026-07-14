import Foundation

/// Файл (docs.get/docs.search). Формат вложения — doc{owner}_{id}_{accessKey}:
/// в отличие от photo/audio/video, у документа есть access_key, без него
/// сервер (parseAttachments, withKey=true) не резолвит вложение.
struct Document: Codable, Identifiable, Hashable {
    let id: Int
    let ownerID: Int
    let title: String
    let size: Int
    let ext: String
    let url: String?
    let accessKey: String

    enum CodingKeys: String, CodingKey {
        case id, title, size, ext, url
        case ownerID = "owner_id"
        case accessKey = "access_key"
    }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
