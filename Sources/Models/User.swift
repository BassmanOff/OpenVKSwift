import Foundation

struct User: Decodable, Identifiable, Hashable {
    let id: Int
    let firstName: String
    let lastName: String
    let photo200: String?
    let photo100: String?
    let photo50: String?
    /// Оригинал аватарки (photo_max) — для полноэкранного просмотра.
    let photoMax: String?
    let screenName: String?
    let status: String?
    let online: Bool
    let cityTitle: String?
    let about: String?
    let bdate: String?
    let sex: Int?
    let counters: Counters?
    /// Код платформы из last_seen.platform (VK: 2=iPhone, 4=Android, 7=web, 1=mobile). nil если оффлайн.
    let lastSeenPlatform: Int?

    enum OnlinePlatform {
        case iphone, android, mobile, web, none

        /// Есть ли для платформы иконка устройства (у веб/оффлайн — нет, как в VK).
        var hasIcon: Bool {
            switch self {
            case .iphone, .android, .mobile: return true
            case .web, .none:                return false
            }
        }
    }

    /// Платформа, с которой пользователь сейчас онлайн (для иконки устройства).
    var onlinePlatform: OnlinePlatform {
        guard online else { return .none }
        switch lastSeenPlatform {
        case 2:        return .iphone
        case 4:        return .android
        case 7:        return .web
        case .some:    return .mobile   // 1 и прочие коды
        case .none:    return .none     // онлайн, но платформа неизвестна
        }
    }

    var fullName: String { "\(firstName) \(lastName)" }

    var avatarURL: URL? {
        guard let s = photo200 ?? photo100 ?? photo50 else { return nil }
        return URL(string: s)
    }

    /// Максимальное доступное качество аватарки (для просмотрщика).
    var fullAvatarURL: URL? {
        guard let s = photoMax ?? photo200 ?? photo100 ?? photo50 else { return nil }
        return URL(string: s)
    }

    struct Counters: Decodable, Hashable {
        let friends: Int?
        let photos: Int?
        let videos: Int?
        let audios: Int?
        let groups: Int?
        let followers: Int?
        let albums: Int?
        let notes: Int?
    }

    enum CodingKeys: String, CodingKey {
        case id, status, about, bdate, sex, counters, online, city
        case firstName = "first_name"
        case lastName = "last_name"
        case photo200 = "photo_200"
        case photo100 = "photo_100"
        case photo50 = "photo_50"
        case photoMax = "photo_max"
        case screenName = "screen_name"
        case lastSeen = "last_seen"
    }

    private enum CityKeys: String, CodingKey { case title }
    private enum LastSeenKeys: String, CodingKey { case platform }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id         = (try? c.decode(Int.self, forKey: .id)) ?? 0
        firstName  = (try? c.decode(String.self, forKey: .firstName)) ?? ""
        lastName   = (try? c.decode(String.self, forKey: .lastName)) ?? ""
        photo200   = try? c.decode(String.self, forKey: .photo200)
        photo100   = try? c.decode(String.self, forKey: .photo100)
        photo50    = try? c.decode(String.self, forKey: .photo50)
        photoMax   = try? c.decode(String.self, forKey: .photoMax)
        screenName = try? c.decode(String.self, forKey: .screenName)
        status     = try? c.decode(String.self, forKey: .status)
        // online присутствует (=1) только когда пользователь онлайн, иначе ключа нет.
        online     = ((try? c.decode(Int.self, forKey: .online)) ?? 0) == 1
        about      = try? c.decode(String.self, forKey: .about)
        bdate      = try? c.decode(String.self, forKey: .bdate)
        sex        = try? c.decode(Int.self, forKey: .sex)
        counters   = try? c.decode(Counters.self, forKey: .counters)
        if let cityC = try? c.nestedContainer(keyedBy: CityKeys.self, forKey: .city) {
            cityTitle = try? cityC.decode(String.self, forKey: .title)
        } else {
            cityTitle = nil
        }
        if let lsC = try? c.nestedContainer(keyedBy: LastSeenKeys.self, forKey: .lastSeen) {
            lastSeenPlatform = try? lsC.decode(Int.self, forKey: .platform)
        } else {
            lastSeenPlatform = nil
        }
    }
}
