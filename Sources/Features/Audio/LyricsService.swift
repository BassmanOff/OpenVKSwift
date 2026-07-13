import Foundation

/// Достаёт текст песни: сначала LRCLIB (синхронизированный), потом обычный LRCLIB,
/// потом — текст с OpenVK (без синхронизации). Кэширует результат (в т.ч. «не найдено»).
@MainActor
final class LyricsService {
    static let shared = LyricsService()

    private var memory: [String: Lyrics] = [:]
    private var diskLoaded = false

    private static let cacheURL: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("lyrics_cache.json")
    }()

    private let userAgent = "OpenVK-iOS (https://github.com/BassmanOff/OpenVKSwift)"

    /// Текст для трека. nil — не найдено (кэшируется, чтобы не дёргать сеть повторно).
    func lyrics(for track: Audio, settings: AppSettings) async -> Lyrics? {
        loadDiskIfNeeded()
        let key = Self.key(track)
        if let cached = memory[key] { return cached.isEmpty ? nil : cached }

        let found = await fetch(track: track, settings: settings)
        // «Не найдено» тоже кэшируем — пустым Lyrics.
        memory[key] = found ?? Lyrics(lines: [], synced: false, source: "none")
        saveDisk()
        return found
    }

    // MARK: - Источники

    private func fetch(track: Audio, settings: AppSettings) async -> Lyrics? {
        if let l = await lrclibGet(track) { return l }
        if let l = await lrclibSearch(track) { return l }
        if let l = await openvkLyrics(track, settings) { return l }
        return nil
    }

    /// LRCLIB /api/get — точное совпадение по исполнителю/названию/длительности.
    private func lrclibGet(_ track: Audio) async -> Lyrics? {
        guard var comps = URLComponents(string: "https://lrclib.net/api/get") else { return nil }
        var q = [
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "track_name", value: track.title),
        ]
        if track.duration > 0 { q.append(URLQueryItem(name: "duration", value: String(track.duration))) }
        if let album = track.album?.title, !album.isEmpty { q.append(URLQueryItem(name: "album_name", value: album)) }
        comps.queryItems = q
        guard let url = comps.url, let item = await request(url) else { return nil }
        return lyrics(from: item)
    }

    /// LRCLIB /api/search — нестрогий поиск, берём ближайший по длительности с синхронизацией.
    private func lrclibSearch(_ track: Audio) async -> Lyrics? {
        guard var comps = URLComponents(string: "https://lrclib.net/api/search") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist),
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let items = try? JSONDecoder().decode([LRCLibItem].self, from: data), !items.isEmpty
        else { return nil }

        let synced = items.filter { !($0.syncedLyrics ?? "").isEmpty }
        let best = synced.min {
            abs(($0.duration ?? 0) - Double(track.duration)) < abs(($1.duration ?? 0) - Double(track.duration))
        }
        if let best, let l = lyrics(from: best) { return l }
        if let plain = items.first(where: { !($0.plainLyrics ?? "").isEmpty }) { return lyrics(from: plain) }
        return nil
    }

    /// Текст с самого OpenVK (audio.getLyrics) — только обычный, без таймкодов.
    private func openvkLyrics(_ track: Audio, _ settings: AppSettings) async -> Lyrics? {
        guard let lyricsID = track.lyricsID, let token = settings.token else { return nil }
        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        struct R: Decodable { let text: String? }
        guard let r: R = try? await client.call("audio.getLyrics", params: ["lyrics_id": String(lyricsID)]),
              let text = r.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        return Lyrics.plain(text, source: "OpenVK")
    }

    // MARK: - Вспомогательное

    private struct LRCLibItem: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
        let instrumental: Bool?
        let duration: Double?
    }

    private func request(_ url: URL) async -> LRCLibItem? {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let item = try? JSONDecoder().decode(LRCLibItem.self, from: data)
        else { return nil }
        return item
    }

    private func lyrics(from item: LRCLibItem) -> Lyrics? {
        if item.instrumental == true { return nil }
        if let synced = item.syncedLyrics, !synced.isEmpty, let l = Lyrics.synced(synced, source: "LRCLIB") {
            return l
        }
        if let plain = item.plainLyrics, !plain.isEmpty {
            return Lyrics.plain(plain, source: "LRCLIB")
        }
        return nil
    }

    private static func key(_ track: Audio) -> String {
        "\(track.artist.lowercased())|\(track.title.lowercased())|\(track.duration)"
    }

    // MARK: - Дисковый кэш

    private func loadDiskIfNeeded() {
        guard !diskLoaded else { return }
        diskLoaded = true
        if let data = try? Data(contentsOf: Self.cacheURL),
           let dict = try? JSONDecoder().decode([String: Lyrics].self, from: data) {
            memory = dict
        }
    }

    private func saveDisk() {
        if let data = try? JSONEncoder().encode(memory) {
            try? data.write(to: Self.cacheURL, options: .atomic)
        }
    }

    /// Стирает кэш текстов (отладка из настроек).
    static func clearCache() {
        try? FileManager.default.removeItem(at: cacheURL)
    }
}
