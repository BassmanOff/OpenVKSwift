import Foundation

/// Проверка обновлений по тегам GitHub-репозитория (TrollStore/SideStore — нет
/// централизованного стора с автообновлением, поэтому сверяемся с тегами вручную).
/// Теги вида «0.4.0» (без «v»), сравниваем как семвер.
enum UpdateChecker {
    private static let repo = "BassmanOff/OpenVKSwift"
    private static let tagsURL = URL(string: "https://api.github.com/repos/\(repo)/tags?per_page=30")!
    static let releasesPageURL = URL(string: "https://github.com/\(repo)/releases")!

    struct Result {
        let currentVersion: String
        let latestVersion: String?
        var isUpdateAvailable: Bool {
            guard let latest = latestVersion else { return false }
            return SemVer(latest).map { $0 > (SemVer(currentVersion) ?? SemVer(0, 0, 0)) } ?? false
        }
        /// Ссылка на конкретный тег на GitHub (страница релиза/тега).
        var releaseURL: URL {
            guard let latest = latestVersion else { return releasesPageURL }
            return URL(string: "https://github.com/\(repo)/releases/tag/\(latest)") ?? releasesPageURL
        }
    }

    private struct GitHubTag: Decodable { let name: String }

    private static let cacheKeyVersion = "update_check_latest_version"
    private static let cacheKeyAt = "update_check_last_at"
    private static let cacheTTL: TimeInterval = 3600 // не долбим GitHub API (лимит 60/час без токена)

    /// CFBundleShortVersionString — единая точка правды (ProfileView-бейдж и SettingsView
    /// читают одно и то же, вместо дублирования Bundle.main-чтения в двух местах).
    /// Значение приходит из project.yml (MARKETING_VERSION) при сборке — не трогать руками.
    /// Фолбэк "0.0.0" — недостижим в реальной сборке (только SwiftUI Previews без бандла).
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// `force: true` игнорирует часовой кэш (ручная кнопка «Проверить обновления»).
    static func check(currentVersion: String, force: Bool = false) async -> Result {
        let defaults = UserDefaults.standard
        if !force {
            let lastAt = defaults.double(forKey: cacheKeyAt)
            if lastAt > 0, Date().timeIntervalSince1970 - lastAt < cacheTTL,
               let cached = defaults.string(forKey: cacheKeyVersion) {
                return Result(currentVersion: currentVersion, latestVersion: cached)
            }
        }

        guard let latest = await fetchLatestTag() else {
            // Сеть недоступна/лимит исчерпан — отдаём последний известный результат, если есть.
            let cached = defaults.string(forKey: cacheKeyVersion)
            return Result(currentVersion: currentVersion, latestVersion: cached)
        }

        defaults.set(latest, forKey: cacheKeyVersion)
        defaults.set(Date().timeIntervalSince1970, forKey: cacheKeyAt)
        return Result(currentVersion: currentVersion, latestVersion: latest)
    }

    /// Самый свежий тег по семверу (GitHub отдаёт теги НЕ гарантированно отсортированными
    /// по версии — сортируем сами).
    private static func fetchLatestTag() async -> String? {
        var request = URLRequest(url: tagsURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let tags = try? JSONDecoder().decode([GitHubTag].self, from: data) else {
            return nil
        }
        return tags
            .compactMap { tag in SemVer(tag.name).map { (tag.name, $0) } }
            .max { $0.1 < $1.1 }?
            .0
    }
}

/// Минимальный семвер для сравнения тегов вида «0.4.0» / «1.2.3». Не-числовые
/// суффиксы (например «-beta») отбрасываются — теги в этом репозитории их не используют.
struct SemVer: Comparable {
    let major: Int, minor: Int, patch: Int

    init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major; self.minor = minor; self.patch = patch
    }

    init?(_ raw: String) {
        let trimmed = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        let parts = trimmed.split(separator: ".").prefix(3).map { Int($0) ?? 0 }
        guard !parts.isEmpty, trimmed.first?.isNumber == true else { return nil }
        major = parts[0]
        minor = parts.count > 1 ? parts[1] : 0
        patch = parts.count > 2 ? parts[2] : 0
    }

    static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
