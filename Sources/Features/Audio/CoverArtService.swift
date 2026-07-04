import Foundation

/// Подбирает обложки для треков без обложки в OpenVK — через публичный iTunes Search API.
/// Кэширует результат (в т.ч. промахи) на диск, чтобы не дёргать сеть повторно.
@MainActor
final class CoverArtService {
    static let shared = CoverArtService()

    private var cache: [String: String] = [:]   // key -> url ("" = искали, не нашли)
    private let cacheURL: URL

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheURL = base.appendingPathComponent("cover_art_cache.json")
        if let data = try? Data(contentsOf: cacheURL),
           let map = try? JSONDecoder().decode([String: String].self, from: data) {
            cache = map
        }
    }

    /// Обложка для трека: сначала берём из OpenVK (album), иначе ищем в iTunes.
    func cover(artist: String, title: String) async -> URL? {
        let key = "\(artist)|\(title)".lowercased()
        if let cached = cache[key] {
            return cached.isEmpty ? nil : URL(string: cached)
        }
        let url = await fetchFromiTunes(artist: artist, title: title)
        cache[key] = url?.absoluteString ?? ""
        save()
        return url
    }

    private func fetchFromiTunes(artist: String, title: String) async -> URL? {
        let term = "\(artist) \(title)".trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty,
              let q = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(q)&media=music&entity=song&limit=1")
        else { return nil }

        guard let data = try? await URLSession.shared.data(from: url).0 else { return nil }
        struct Response: Decodable {
            struct Item: Decodable { let artworkUrl100: String? }
            let results: [Item]
        }
        guard let resp = try? JSONDecoder().decode(Response.self, from: data),
              let art = resp.results.first?.artworkUrl100 else { return nil }
        // iTunes отдаёт 100x100 — апскейлим до 600x600.
        return URL(string: art.replacingOccurrences(of: "100x100", with: "600x600"))
    }

    private func save() {
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    /// Стирает кэш обложек (память + диск) — отладка из настроек.
    func clearCache() {
        cache = [:]
        try? FileManager.default.removeItem(at: cacheURL)
    }
}
