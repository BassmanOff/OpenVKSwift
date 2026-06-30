import Foundation

/// Сообщество (groups.get). Назван Community, чтобы не конфликтовать со SwiftUI.Group.
struct Community: Decodable, Identifiable, Hashable {
    let groupID: Int
    let name: String
    let screenName: String?
    let photo50: String?
    let photo100: String?
    let photo200: String?

    var id: Int { groupID }

    var avatarURL: URL? {
        (photo200 ?? photo100 ?? photo50).flatMap(URL.init(string:))
    }

    enum CodingKeys: String, CodingKey {
        case groupID = "id"
        case name
        case screenName = "screen_name"
        case photo50 = "photo_50"
        case photo100 = "photo_100"
        case photo200 = "photo_200"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groupID    = (try? c.decode(Int.self, forKey: .groupID)) ?? 0
        name       = (try? c.decode(String.self, forKey: .name)) ?? ""
        screenName = try? c.decode(String.self, forKey: .screenName)
        photo50    = try? c.decode(String.self, forKey: .photo50)
        photo100   = try? c.decode(String.self, forKey: .photo100)
        photo200   = try? c.decode(String.self, forKey: .photo200)
    }
}
