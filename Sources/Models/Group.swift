import Foundation

/// Сообщество (groups.get). Назван Community, чтобы не конфликтовать со SwiftUI.Group.
struct Community: Decodable, Identifiable, Hashable {
    let groupID: Int
    let name: String
    let screenName: String?
    let photo50: String?
    let photo100: String?
    let photo200: String?
    /// Оригинал аватарки (photo_max) — для полноэкранного просмотра.
    let photoMax: String?
    /// Является ли текущий пользователь администратором сообщества.
    let isAdmin: Bool
    let isMember: Bool
    let description: String?
    let membersCount: Int?

    var id: Int { groupID }

    var avatarURL: URL? {
        (photo200 ?? photo100 ?? photo50).flatMap(URL.init(string:))
    }

    /// Максимальное доступное качество аватарки (для просмотрщика).
    var fullAvatarURL: URL? {
        (photoMax ?? photo200 ?? photo100 ?? photo50).flatMap(URL.init(string:))
    }

    enum CodingKeys: String, CodingKey {
        case groupID = "id"
        case name
        case screenName = "screen_name"
        case photo50 = "photo_50"
        case photo100 = "photo_100"
        case photo200 = "photo_200"
        case photoMax = "photo_max"
        case isAdmin = "is_admin"
        case isMember = "is_member"
        case description
        case membersCount = "members_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groupID      = (try? c.decode(Int.self, forKey: .groupID)) ?? 0
        name         = (try? c.decode(String.self, forKey: .name)) ?? ""
        screenName   = try? c.decode(String.self, forKey: .screenName)
        photo50      = try? c.decode(String.self, forKey: .photo50)
        photo100     = try? c.decode(String.self, forKey: .photo100)
        photo200     = try? c.decode(String.self, forKey: .photo200)
        photoMax     = try? c.decode(String.self, forKey: .photoMax)
        isAdmin      = ((try? c.decode(Int.self, forKey: .isAdmin)) ?? 0) == 1
        isMember     = ((try? c.decode(Int.self, forKey: .isMember)) ?? 0) == 1
        description  = try? c.decode(String.self, forKey: .description)
        membersCount = try? c.decode(Int.self, forKey: .membersCount)
    }
}
