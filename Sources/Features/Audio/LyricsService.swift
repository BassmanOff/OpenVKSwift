import Foundation

/// Достаёт текст песни: сначала LRCLIB (синхронизированный), потом обычный LRCLIB,
/// потом — текст с OpenVK (без синхронизации). Кэширует результат (в т.ч. «не найдено»).
@MainActor
final class LyricsService {
    static let shared = LyricsService()

    private var memory: [String: Lyrics] = [:]
    private var diskLoaded = false
    private var diskLoadTask: Task<[String: Lyrics]?, Never>?

    private static let cacheURL: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("lyrics_cache.json")
    }()
    /// Один последовательный writer: новые снимки кэша не могут обогнать старые.
    private static let diskQueue = DispatchQueue(label: "org.openvk.lyrics-cache", qos: .utility)

    private let userAgent = "OpenVK-iOS (https://github.com/BassmanOff/OpenVKSwift)"

    /// Текст для трека. nil — не найдено (кэшируется, чтобы не дёргать сеть повторно).
    func lyrics(for track: Audio, settings: AppSettings) async -> Lyrics? {
        await loadDiskIfNeeded()
        guard !Task.isCancelled else { return nil }
        let key = Self.key(track)
        if let cached = memory[key] { return cached.isEmpty ? nil : cached }

        let found = await fetch(track: track, settings: settings)
        // Отменённый запрос (быстрое перелистывание треков) возвращает nil, НЕ проверив
        // источники — кэшировать такое как «не найдено» нельзя (кэш дисковый, навсегда).
        guard !Task.isCancelled else { return found }
        // «Не найдено» тоже кэшируем — пустым Lyrics.
        memory[key] = found ?? Lyrics(lines: [], synced: false, source: "none")
        saveDisk()
        return found
    }

    // MARK: - Источники

    /// Все источники — ПАРАЛЛЕЛЬНО, приоритет прежний: точный LRCLIB (синхронизированный) →
    /// поиск LRCLIB → текст OpenVK. Последовательный обход с системным таймаутом 60с давал
    /// минуту ожидания, если первый источник висел; теперь худший случай ≈ requestTimeout.
    private func fetch(track: Audio, settings: AppSettings) async -> Lyrics? {
        async let exact = lrclibGet(track)
        async let searched = lrclibSearch(track)
        async let openvk = openvkLyrics(track, settings)
        if let l = await exact { return l }
        if let l = await searched { return l }
        return await openvk
    }

    /// Максимум ожидания одного источника — дольше живые сервера не отвечают.
    private let requestTimeout: TimeInterval = 8

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
        req.timeoutInterval = requestTimeout
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
        req.timeoutInterval = requestTimeout
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

    private func loadDiskIfNeeded() async {
        guard !diskLoaded else { return }
        let task: Task<[String: Lyrics]?, Never>
        if let diskLoadTask {
            task = diskLoadTask
        } else {
            task = Task {
                await withCheckedContinuation { continuation in
                    Self.diskQueue.async {
                        let cached: [String: Lyrics]?
                        if let data = try? Data(contentsOf: Self.cacheURL) {
                            cached = try? JSONDecoder().decode([String: Lyrics].self, from: data)
                        } else {
                            cached = nil
                        }
                        continuation.resume(returning: cached)
                    }
                }
            }
            diskLoadTask = task
        }
        let cached = await task.value
        guard !diskLoaded else { return }
        if let cached { memory = cached }
        diskLoaded = true
        diskLoadTask = nil
    }

    private func saveDisk() {
        let snapshot = memory
        Self.diskQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: Self.cacheURL, options: .atomic)
            }
        }
    }

    /// Стирает кэш текстов (отладка из настроек).
    static func clearCache() {
        // sync редок (только явная очистка с последующим перезапуском), зато ждёт
        // уже поставленные записи и гарантирует, что они не создадут файл заново.
        diskQueue.sync { try? FileManager.default.removeItem(at: cacheURL) }
    }
}
