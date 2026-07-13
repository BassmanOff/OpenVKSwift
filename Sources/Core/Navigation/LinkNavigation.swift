import SwiftUI
import UIKit

/// Внутренние места назначения, распознаваемые из ссылок OpenVK.
enum LinkDestination: Identifiable, Hashable {
    case playlist(ownerID: Int, id: Int)
    case profile(userID: Int)
    case community(groupID: Int)
    case topic(groupID: Int, virtualID: Int)
    /// Короткий адрес (openvk.org/durov) — резолвится через utils.resolveScreenName.
    case screenName(String)
    /// Запись на стене (wall{owner}_{post}).
    case post(ownerID: Int, postID: Int)
    /// Фотография (photo{owner}_{id}).
    case photo(ownerID: Int, photoID: Int)
    /// Видеозапись (video{owner}_{id}).
    case video(ownerID: Int, videoID: Int)

    var id: String {
        switch self {
        case .playlist(let o, let i): return "playlist\(o)_\(i)"
        case .profile(let u):         return "id\(u)"
        case .community(let g):       return "club\(g)"
        case .topic(let g, let v):    return "topic\(g)_\(v)"
        case .screenName(let s):      return "sn_\(s)"
        case .post(let o, let p):       return "post\(o)_\(p)"
        case .photo(let o, let p):     return "photo\(o)_\(p)"
        case .video(let o, let v):     return "video\(o)_\(v)"
        }
    }
}

/// Хранит запрошенное из ссылки место назначения. ЕДИНЫЙ `destination` для ВСЕХ типов.
///
/// Две роли одного класса:
/// • ГЛОБАЛЬНЫЙ роутер (один на `MainTabView`): `open(_:activeTab:)` фиксирует ВКЛАДКУ, в чей
///   стек пушить (в момент тапа), — фоновый `NavigationLink` нужной вкладки пушит назначение,
///   поэтому таб-бар остаётся, работает свайп-назад (не модалка).
/// • ЛОКАЛЬНЫЙ роутер (`.handlesOVKLinks()` на модалках и рекурсивно на открытом экране):
///   `open(_)` без вкладки — пуш в ОКРУЖАЮЩИЙ NavigationView (модалки/цепочки ссылок).
@MainActor
final class LinkRouter: ObservableObject {
    @Published var destination: LinkDestination?
    /// Индекс вкладки, в чей стек пушим (только у глобального роутера; nil = локальный пуш).
    @Published var targetTab: Int?
    /// Счётчик «pop-to-root» по индексу вкладки: инкремент = повторный тап по активной вкладке.
    /// `GlobalLinkPush` внутри вкладки слушает свой ключ и схлопывает стек анимированно.
    @Published var resetTrigger: [Int: Int] = [:]

    /// Возвращает true, если ссылка распознана как внутренняя (и навигация запущена).
    @discardableResult
    func open(_ url: URL, activeTab: Int? = nil) -> Bool {
        // away.php?to=<url> — OpenVK-шный трекер-редирект внешних ссылок.
        // Вытаскиваем целевой URL и открываем его системно (браузер), не в приложении.
        if let host = url.host?.lowercased(), LinkParser.hosts.contains(host),
           url.path.contains("away.php"),
           let q = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let to = q.queryItems?.first(where: { $0.name == "to" })?.value,
           let toURL = URL(string: to) {
            UIApplication.shared.open(toURL)
            return true
        }
        guard let dest = LinkParser.parse(url) else { return false }
        targetTab = activeTab
        destination = dest
        return true
    }
}

/// Разбирает ссылки OpenVK (openvk.org / openvk.xyz / ovk.to) в места назначения.
enum LinkParser {
    fileprivate static let hosts: Set<String> = [
        "openvk.org", "www.openvk.org", "m.openvk.org",
        "openvk.xyz", "www.openvk.xyz",
        "ovk.to", "www.ovk.to"
    ]

    static func parse(_ url: URL) -> LinkDestination? {
        guard let host = url.host?.lowercased(), hosts.contains(host) else { return nil }
        var path = url.path
        if path.hasPrefix("/") { path.removeFirst() }

        if let m = match("^playlist(-?\\d+)_(\\d+)$", path), let o = Int(m[1]), let i = Int(m[2]) {
            return .playlist(ownerID: o, id: i)
        }
        if let m = match("^id(\\d+)$", path), let u = Int(m[1]) {
            return .profile(userID: u)
        }
        if let m = match("^(club|public|group|event)(\\d+)$", path), let g = Int(m[2]) {
            return .community(groupID: g)
        }
        if let m = match("^topic(\\d+)_(\\d+)$", path), let g = Int(m[1]), let v = Int(m[2]) {
            return .topic(groupID: g, virtualID: v)
        }
        // Записи на стене / фото / видео — в приложение (owner может быть отрицательным).
        if let m = match("^wall(-?\\d+)_(\\d+)$", path), let o = Int(m[1]), let p = Int(m[2]) {
            return .post(ownerID: o, postID: p)
        }
        if let m = match("^photo(-?\\d+)_(\\d+)$", path), let o = Int(m[1]), let p = Int(m[2]) {
            return .photo(ownerID: o, photoID: p)
        }
        if let m = match("^video(-?\\d+)_(\\d+)$", path), let o = Int(m[1]), let v = Int(m[2]) {
            return .video(ownerID: o, videoID: v)
        }
        // Короткие адреса (openvk.org/perezaliv) — в приложение через resolveScreenName.
        // Технические пути и медиа-ссылки (audios123, wall1_2, feed...) оставляем браузеру.
        if match("^[A-Za-z][A-Za-z0-9_.]{1,31}$", path) != nil, !isReserved(path) {
            return .screenName(path)
        }
        return nil
    }

    /// Пути, которые выглядят как короткий адрес, но им не являются.
    private static func isReserved(_ path: String) -> Bool {
        let exact: Set<String> = [
            "feed", "im", "settings", "search", "friends", "groups", "apps",
            "notifications", "login", "logout", "register", "support", "docs",
            "dev", "about", "privacy", "terms", "admin", "sandbox", "audios",
            "videos", "photos", "albums", "notes", "gifts", "market"
        ]
        if exact.contains(path.lowercased()) { return true }
        // Медиа-маршруты с числом: audios123, video1_2, wall-5_10, app3, page7...
        return match("^(audio|video|album|photo|wall|app|page|note|topic|poll|doc|graffiti)s?-?\\d", path) != nil
    }

    private static func match(_ pattern: String, _ string: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = string as NSString
        guard let m = re.firstMatch(in: string, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { idx in
            let r = m.range(at: idx)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
}

/// Кэш разбора текстов: NSDataDetector/NSRegularExpression дороги в СОЗДАНИИ
/// (миллисекунды), а тексты постов неизменны — держим инструменты статически
/// (они потокобезопасны) и запоминаем готовые AttributedString.
private enum LinkifyCache {
    static let mentionRegex = try? NSRegularExpression(
        pattern: "\\[((?:id|club|public|group|event)\\d+)\\|([^\\]]+)\\]"
    )
    static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// AttributedString — структура, NSCache хранит только классы; заворачиваем.
    final class Box {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    static let results: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 500
        return cache
    }()
}

/// Делает кликабельными URL-ы И упоминания вида `[id123|Имя]` / `[club45|Имя]`.
/// Собираем строку по кускам (NSString-подстроки), а НЕ маппим индексы в готовую AttributedString —
/// маппинг индексов ненадёжен (ломал/пропускал ссылки).
/// Результат кэшируется: вызывается в body каждой строки ленты при каждой пересборке.
func linkifiedText(_ text: String) -> AttributedString {
    if let cached = LinkifyCache.results.object(forKey: text as NSString) {
        return cached.value
    }
    let result = buildLinkifiedText(text)
    LinkifyCache.results.setObject(LinkifyCache.Box(result), forKey: text as NSString)
    return result
}

private func buildLinkifiedText(_ text: String) -> AttributedString {
    let ns = text as NSString
    let full = NSRange(location: 0, length: ns.length)
    // span: диапазон в исходной строке, отображаемый текст, целевой URL.
    var spans: [(range: NSRange, display: String, url: URL)] = []

    // Упоминания [id123|Имя], [club45|Имя], [public/group/event…|Имя] → ссылка на профиль/сообщество.
    if let re = LinkifyCache.mentionRegex {
        for m in re.matches(in: text, range: full) {
            let screen = ns.substring(with: m.range(at: 1))
            let name = ns.substring(with: m.range(at: 2))
            if let url = URL(string: "https://openvk.org/\(screen)") {
                spans.append((m.range, name, url))
            }
        }
    }

    // Обычные ссылки (пропускаем те, что пересекаются с упоминанием).
    if let detector = LinkifyCache.detector {
        for m in detector.matches(in: text, range: full) {
            guard let url = m.url else { continue }
            if spans.contains(where: { NSIntersectionRange($0.range, m.range).length > 0 }) { continue }
            spans.append((m.range, ns.substring(with: m.range), url))
        }
    }

    guard !spans.isEmpty else { return AttributedString(text) }
    spans.sort { $0.range.location < $1.range.location }

    var result = AttributedString()
    var cursor = 0
    for span in spans {
        if span.range.location < cursor { continue } // защита от пересечений
        if span.range.location > cursor {
            result += AttributedString(ns.substring(with: NSRange(location: cursor, length: span.range.location - cursor)))
        }
        var link = AttributedString(span.display)
        link.link = span.url
        link.foregroundColor = OVK.Palette.link
        result += link
        cursor = span.range.location + span.range.length
    }
    if cursor < ns.length {
        result += AttributedString(ns.substring(from: cursor))
    }
    return result
}
