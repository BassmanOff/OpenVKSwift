import Foundation
import AVFoundation

/// Виртуальный HLS-стрим поверх удалённого MP4.
///
/// AVPlayer получает обычный http-URL плейлиста с локального сервера (127.0.0.1):
/// плейлист генерируется из индекса файла, а на запрос сегмента качается ОДИН
/// Range (~5 секунд файла — дорожки перемешаны покадрово, окно почти непрерывно)
/// и на лету ремуксится в MPEG-TS (TSMuxer). Честный стриминг с мгновенным
/// стартом и перемоткой; MP3-звук играется штатно (HLS поддерживает MPEG-1 audio в TS).
///
/// Транспорт — именно локальный HTTP (LocalHTTPServer), потому что медиасегменты
/// через AVAssetResourceLoader плеер НЕ принимает (CoreMedia -12881).
final class HLSStreamer {
    struct Segment {
        let index: Int
        let duration: Double
        let videoRange: Range<Int>   // индексы видеосэмплов
        let audioRange: Range<Int>   // индексы аудиосэмплов
        let byteRange: Range<Int>    // байты в исходном файле
    }

    private struct StreamError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let mp4: MP4Index
    private let remoteURL: URL
    private let segments: [Segment]
    private let session: URLSession
    private var server: LocalHTTPServer?

    // Кэш последних собранных сегментов (перемотка назад, повторные запросы плеера).
    private let cacheLock = NSLock()
    private var cache: [Int: Data] = [:]
    private var cacheOrder: [Int] = []
    private var inFlight: Set<Int> = [] // сегменты, что готовятся сейчас (не дублируем)

    var segmentCount: Int { segments.count }

    init(index: MP4Index, remoteURL: URL) {
        self.mp4 = index
        self.remoteURL = remoteURL
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: cfg)
        self.segments = Self.buildSegments(index: index)
    }

    /// Поднимает локальный HTTP-сервер; возвращает URL плейлиста для AVPlayer.
    func start() async throws -> URL {
        let server = try LocalHTTPServer { [weak self] path in
            await self?.route(path)
        }
        self.server = server
        let port = try await server.start()
        guard port > 0, let url = URL(string: "http://127.0.0.1:\(port)/playlist.m3u8") else {
            throw StreamError(message: "Локальный сервер не запустился")
        }
        Self.log("HTTP-сервер на порту \(port)")
        return url
    }

    func stop() {
        server?.stop()
        server = nil
    }

    deinit {
        server?.stop()
    }

    // MARK: - Маршрутизация

    private func route(_ path: String) async -> (contentType: String, data: Data)? {
        Self.log("GET \(path)")
        if path == "/playlist.m3u8" {
            let text = playlistText()
            Self.log("  отдаём плейлист (\(text.utf8.count) байт):\n\(text)")
            return ("application/vnd.apple.mpegurl", Data(text.utf8))
        }
        if path.hasPrefix("/seg"), path.hasSuffix(".ts"),
           let idx = Int(path.dropFirst(4).dropLast(3)),
           segments.indices.contains(idx) {
            if let cached = cachedSegment(idx) {
                prefetch(idx + 1) // следующий уже, скорее всего, готов
                return ("video/MP2T", cached)
            }

            do {
                let ts = try await buildSegmentData(idx)
                store(idx, ts)
                prefetch(idx + 1) // готовим следующий, пока играет этот
                return ("video/MP2T", ts)
            } catch {
                Self.log("сегмент \(idx): ошибка — \(error.localizedDescription)")
                return nil
            }
        }
        Self.log("  неизвестный ресурс — 404")
        return nil
    }

    // MARK: - Нарезка сегментов

    /// Границы — по ключевым кадрам, ближайшим к целевым ~5 секундам.
    private static func buildSegments(index: MP4Index) -> [Segment] {
        let video = index.video
        let vts = Double(video.timescale)
        let target = 5.0

        var boundaries: [Int] = [0]
        var lastTime = 0.0
        for (i, sample) in video.samples.enumerated() where i > 0 && sample.isSync {
            let t = Double(sample.dts) / vts
            if t - lastTime >= target {
                boundaries.append(i)
                lastTime = t
            }
        }
        boundaries.append(video.samples.count)

        var result: [Segment] = []
        var audioPointer = 0
        for bi in 0..<(boundaries.count - 1) {
            let vStart = boundaries[bi]
            let vEnd = boundaries[bi + 1]
            guard vStart < vEnd else { continue }
            let startTime = Double(video.samples[vStart].dts) / vts
            let endTime = vEnd < video.samples.count
                ? Double(video.samples[vEnd].dts) / vts
                : index.duration + 0.1

            var aStart = audioPointer
            var aEnd = audioPointer
            if let audio = index.audio {
                let ats = Double(audio.timescale)
                aStart = audioPointer
                while aEnd < audio.samples.count, Double(audio.samples[aEnd].dts) / ats < endTime {
                    aEnd += 1
                }
                audioPointer = aEnd
            }

            var lo = Int.max
            var hi = 0
            for s in video.samples[vStart..<vEnd] {
                lo = min(lo, s.offset)
                hi = max(hi, s.offset + s.size)
            }
            if let audio = index.audio {
                for s in audio.samples[aStart..<aEnd] {
                    lo = min(lo, s.offset)
                    hi = max(hi, s.offset + s.size)
                }
            }
            guard lo < hi else { continue }

            result.append(Segment(
                index: result.count,
                duration: max(endTime - startTime, 0.1),
                videoRange: vStart..<vEnd,
                audioRange: aStart..<aEnd,
                byteRange: lo..<hi
            ))
        }
        return result
    }

    private func playlistText() -> String {
        // TARGETDURATION обязан быть ≥ каждого EXTINF (иначе плеер отвергает плейлист).
        let target = max(1, Int((segments.map(\.duration).max() ?? 5).rounded(.up)))
        var text = "#EXTM3U\n"
        text += "#EXT-X-VERSION:3\n"
        text += "#EXT-X-TARGETDURATION:\(target)\n"
        text += "#EXT-X-MEDIA-SEQUENCE:0\n"
        text += "#EXT-X-PLAYLIST-TYPE:VOD\n"
        for segment in segments {
            text += String(format: "#EXTINF:%.3f,\n", segment.duration)
            text += "seg\(segment.index).ts\n"
        }
        text += "#EXT-X-ENDLIST\n"
        return text
    }

    /// Заранее готовит сегмент в фоне (следующий за текущим), чтобы плеер не ждал.
    private func prefetch(_ idx: Int) {
        guard segments.indices.contains(idx), beginPrefetch(idx) else { return }
        Task { [weak self] in
            guard let self else { return }
            let ts = try? await self.buildSegmentData(idx)
            self.finishPrefetch(idx, ts)
        }
    }

    // MARK: - Синхронный доступ к кэшу (lock/unlock нельзя вызывать из async — Swift 6)

    private func cachedSegment(_ idx: Int) -> Data? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cache[idx]
    }

    private func store(_ idx: Int, _ data: Data) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        storeInCache(idx, data)
    }

    /// Резервирует сегмент под фоновую подготовку; false — уже готов или готовится.
    private func beginPrefetch(_ idx: Int) -> Bool {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if cache[idx] != nil || inFlight.contains(idx) { return false }
        inFlight.insert(idx)
        return true
    }

    private func finishPrefetch(_ idx: Int, _ data: Data?) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        inFlight.remove(idx)
        if let data { storeInCache(idx, data) }
    }

    // MARK: - Сборка сегмента

    private func buildSegmentData(_ idx: Int) async throws -> Data {
        let segment = segments[idx]
        let bytes = try await fetchRange(remoteURL, segment.byteRange)
        let base = segment.byteRange.lowerBound
        let video = mp4.video
        let ptsBase: Int64 = 90000 // сдвиг на 1с — PCR/PTS всегда положительны

        var videoUnits: [TSMuxer.VideoUnit] = []
        videoUnits.reserveCapacity(segment.videoRange.count)
        for s in video.samples[segment.videoRange] {
            let lo = s.offset - base
            let hi = lo + s.size
            guard lo >= 0, hi <= bytes.count else {
                throw StreamError(message: "Сэмпл вне сегмента")
            }
            let dts90 = s.dts * 90000 / Int64(video.timescale) + ptsBase
            let pts90 = (s.dts + Int64(s.ctsOffset)) * 90000 / Int64(video.timescale) + ptsBase
            videoUnits.append(TSMuxer.VideoUnit(
                data: bytes.subdata(in: lo..<hi), pts: pts90, dts: dts90, isSync: s.isSync
            ))
        }

        var audioUnits: [TSMuxer.AudioUnit] = []
        if let audio = mp4.audio {
            audioUnits.reserveCapacity(segment.audioRange.count)
            for s in audio.samples[segment.audioRange] {
                let lo = s.offset - base
                let hi = lo + s.size
                guard lo >= 0, hi <= bytes.count else {
                    throw StreamError(message: "Аудиосэмпл вне сегмента")
                }
                let pts90 = s.dts * 90000 / Int64(audio.timescale) + ptsBase
                audioUnits.append(TSMuxer.AudioUnit(data: bytes.subdata(in: lo..<hi), pts: pts90))
            }
        }

        let ts = TSMuxer.mux(
            video: videoUnits, audio: audioUnits,
            sps: video.sps, pps: video.pps, nalLengthSize: video.nalLengthSize
        )
        Self.log("сегмент \(idx): \(videoUnits.count) кадров + \(audioUnits.count) аудио, \(bytes.count / 1024) КБ → TS \(ts.count / 1024) КБ")
        return ts
    }

    private func fetchRange(_ url: URL, _ range: Range<Int>) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 206, data.count == range.count else {
            throw StreamError(message: "Range-запрос сегмента не удался")
        }
        return data
    }

    private func storeInCache(_ idx: Int, _ data: Data) {
        cache[idx] = data
        cacheOrder.append(idx)
        while cacheOrder.count > 8 {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }

    private static func log(_ message: String) {
        print("[HLS] \(message)")
    }
}
