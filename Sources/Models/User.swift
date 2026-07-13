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
    var online: Bool
    let cityTitle: String?
    let about: String?
    /// var, а не let: для своего профиля добираем настоящую дату через account.getProfileInfo,
    /// т.к. users.get отдаёт null при дефолтной приватности дня рождения (баг сервера, см.
    /// ProfileViewModel.augmentOwnBirthday).
    var bdate: String?
    let sex: Int?
    let counters: Counters?
    /// Код платформы из last_seen.platform (VK: 2=iPhone, 4=Android, 7=web, 1=mobile). nil если оффлайн.
    var lastSeenPlatform: Int?
    /// Статус дружбы (API friend_status, уже переставлено сервером в users.get):
    /// 0 — нет, 1 — заявка отправлена (исходящая), 2 — заявка получена (входящая), 3 — друг.
    let friendStatus: Int?
    /// Трек, который слушает пользователь прямо сейчас (users.get?fields=status → status_audio).
    /// Не зависит от друзей/подписок — приходит вместе с обычной загрузкой профиля.
    let statusAudio: Audio?
    /// Верифицирован ли аккаунт на сервере (users.get?fields=verified → 0/1).
    let verified: Bool
    /// Доп. поля профиля (кнопка «Все данные» в ProfileView) — сервер отдаёт, только если
    /// запрошены в fields И видимы вызывающему (приватность музыки/интересов и т.п. — canView).
    let nickname: String?
    let music: String?
    let movies: String?
    let tv: String?
    let books: String?
    let games: String?
    let interests: String?
    let quotes: String?
    let telegram: String?
    let regDate: Int?

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

    /// «18 апреля 2002 (24 года)» — сервер отдаёт bdate как "D.M" (год скрыт настройками
    /// приватности) или "D.M.Y" (год показан), см. VKAPI/Handlers/Users.php::get case "bdate".
    /// Без года — без возраста, только дата.
    var birthdayDisplay: String? {
        guard let bdate else { return nil }
        // trim: account.getProfileInfo отдаёт день с ведущим ПРОБЕЛОМ (%e → " 5.04.2002"),
        // Int(" 5") без trim = nil, и дата молча пропадала.
        let parts = bdate.split(separator: ".").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 2, (1...12).contains(parts[1]), (1...31).contains(parts[0]) else { return nil }
        let day = parts[0], month = parts[1]
        var text = "\(day) \(Self.monthGenitive[month - 1])"
        guard parts.count >= 3 else { return text }
        let year = parts[2]

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        text += " \(year)"
        if let birthDate = cal.date(from: DateComponents(year: year, month: month, day: day)),
           let age = cal.dateComponents([.year], from: birthDate, to: Date()).year, age >= 0 {
            text += " (\(age) \(Self.ageWord(age)))"
        }
        return text
    }

    private static let monthGenitive = [
        "января", "февраля", "марта", "апреля", "мая", "июня",
        "июля", "августа", "сентября", "октября", "ноября", "декабря"
    ]

    private static func ageWord(_ n: Int) -> String {
        let mod10 = n % 10, mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return "год" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "года" }
        return "лет"
    }

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
        case friendStatus = "friend_status"
        case statusAudio = "status_audio"
        case verified, nickname, music, movies, tv, books, games, interests, quotes, telegram
        case regDate = "reg_date"
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
        friendStatus = try? c.decode(Int.self, forKey: .friendStatus)
        statusAudio = try? c.decode(Audio.self, forKey: .statusAudio)
        verified   = ((try? c.decode(Int.self, forKey: .verified)) ?? 0) == 1
        nickname   = try? c.decode(String.self, forKey: .nickname)
        music      = try? c.decode(String.self, forKey: .music)
        movies     = try? c.decode(String.self, forKey: .movies)
        tv         = try? c.decode(String.self, forKey: .tv)
        books      = try? c.decode(String.self, forKey: .books)
        games      = try? c.decode(String.self, forKey: .games)
        interests  = try? c.decode(String.self, forKey: .interests)
        quotes     = try? c.decode(String.self, forKey: .quotes)
        telegram   = try? c.decode(String.self, forKey: .telegram)
        regDate    = try? c.decode(Int.self, forKey: .regDate)
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
