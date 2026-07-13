import Foundation

/// Извлекает аудиодорожку из MP4-контейнера, НЕ декодируя её.
///
/// Зачем: нативные видео OpenVK кодируются сервером как H.264 + **MP3** внутри MP4
/// (ffmpeg `-c:v libx264 -c:a libmp3lame`). AVFoundation играет такое видео без звука —
/// MP3-в-MP4 он не декодирует. Но MP3-кадры самодостаточны (каждый несёт свой заголовок),
/// поэтому простая конкатенация сэмплов дорожки в порядке следования = валидный .mp3-файл,
/// который системе уже по зубам.
///
/// Парсер читает только структуры контейнера (box-дерево ISO BMFF + таблицы сэмплов stbl),
/// файл мапится в память (mappedIfSafe) — большие видео не загружаются в RAM целиком.
enum MP4AudioExtractor {
    enum ExtractError: LocalizedError, Equatable {
        /// В контейнере действительно нет звуковой дорожки (немое видео — не ошибка).
        case noAudioTrack
        /// Контейнер повреждён/не распознан.
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .noAudioTrack:       return "В файле нет аудиодорожки"
            case .malformed(let msg): return msg
            }
        }
    }

    /// Возвращает сырую аудиодорожку (байты MP3-потока) первого звукового трека.
    static func extractAudio(from fileURL: URL) throws -> Data {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let ranges = try audioSampleRanges(in: data)
        var out = Data()
        out.reserveCapacity(ranges.reduce(0) { $0 + $1.count })
        for range in ranges {
            guard range.lowerBound >= 0, range.upperBound <= data.count else {
                throw ExtractError.malformed("Сэмпл выходит за пределы файла")
            }
            out.append(data.subdata(in: range))
        }
        guard !out.isEmpty else { throw ExtractError.malformed("Дорожка пуста") }
        return out
    }

    /// Карта аудиодорожки: АБСОЛЮТНЫЕ диапазоны байтов сэмплов в исходном файле.
    /// `data` — либо весь файл, либо только moov-бокс (скачанный Range-запросом,
    /// данные должны начинаться с заголовка moov или содержать его на верхнем уровне);
    /// смещения чанков (stco/co64) в любом случае абсолютные — от начала файла.
    static func audioSampleRanges(in data: Data) throws -> [Range<Int>] {
        guard let moov = firstBox("moov", in: data, range: 0..<data.count) else {
            throw ExtractError.malformed("Контейнер не распознан (нет moov)")
        }

        // Перебираем trak-и в поисках звукового (hdlr == "soun").
        var cursor = moov.payload.lowerBound
        while cursor < moov.payload.upperBound {
            guard let box = parseBox(data, at: cursor, limit: moov.payload.upperBound) else { break }
            cursor = box.end
            guard box.type == "trak",
                  let mdia = firstBox("mdia", in: data, range: box.payload),
                  let hdlr = firstBox("hdlr", in: data, range: mdia.payload),
                  hdlr.payload.count >= 12,
                  fourCC(data, at: hdlr.payload.lowerBound + 8) == "soun",
                  let minf = firstBox("minf", in: data, range: mdia.payload),
                  let stbl = firstBox("stbl", in: data, range: minf.payload)
            else { continue }
            return try collectSampleRanges(data: data, stbl: stbl)
        }
        throw ExtractError.noAudioTrack
    }

    // MARK: - Таблицы сэмплов

    /// Диапазоны всех сэмплов дорожки в порядке следования, по чанкам:
    /// stco/co64 — смещения чанков в файле, stsc — сколько сэмплов в каждом чанке,
    /// stsz — размер каждого сэмпла. Внутри чанка сэмплы лежат подряд.
    private static func collectSampleRanges(data: Data, stbl: Box) throws -> [Range<Int>] {
        guard let stsz = firstBox("stsz", in: data, range: stbl.payload),
              let stsc = firstBox("stsc", in: data, range: stbl.payload)
        else { throw ExtractError.malformed("Таблицы сэмплов не найдены") }

        // stsz: [ver/flags:4][uniformSize:4][count:4][sizes: u32 × count]
        let szBase = stsz.payload.lowerBound
        guard stsz.payload.count >= 12 else { throw ExtractError.malformed("stsz повреждён") }
        let uniformSize = Int(readU32(data, szBase + 4))
        let sampleCount = Int(readU32(data, szBase + 8))
        guard sampleCount > 0 else { throw ExtractError.malformed("Пустая дорожка") }
        if uniformSize == 0 {
            guard stsz.payload.count >= 12 + sampleCount * 4 else {
                throw ExtractError.malformed("stsz усечён")
            }
        }
        func sampleSize(_ i: Int) -> Int {
            uniformSize != 0 ? uniformSize : Int(readU32(data, szBase + 12 + i * 4))
        }

        // Смещения чанков: stco (u32) или co64 (u64).
        var chunkOffsets: [Int] = []
        if let stco = firstBox("stco", in: data, range: stbl.payload) {
            let base = stco.payload.lowerBound
            guard stco.payload.count >= 8 else { throw ExtractError.malformed("stco повреждён") }
            let n = Int(readU32(data, base + 4))
            guard stco.payload.count >= 8 + n * 4 else { throw ExtractError.malformed("stco усечён") }
            chunkOffsets = (0..<n).map { Int(readU32(data, base + 8 + $0 * 4)) }
        } else if let co64 = firstBox("co64", in: data, range: stbl.payload) {
            let base = co64.payload.lowerBound
            guard co64.payload.count >= 8 else { throw ExtractError.malformed("co64 повреждён") }
            let n = Int(readU32(data, base + 4))
            guard co64.payload.count >= 8 + n * 8 else { throw ExtractError.malformed("co64 усечён") }
            chunkOffsets = (0..<n).map { Int(readU64(data, base + 8 + $0 * 8)) }
        } else {
            throw ExtractError.malformed("Смещения чанков не найдены")
        }

        // stsc: [ver/flags:4][count:4] + записи (firstChunk, samplesPerChunk, descIndex) × u32.
        // Записи описывают «с чанка N — по M сэмплов» до следующей записи.
        let scBase = stsc.payload.lowerBound
        guard stsc.payload.count >= 8 else { throw ExtractError.malformed("stsc повреждён") }
        let runCount = Int(readU32(data, scBase + 4))
        guard stsc.payload.count >= 8 + runCount * 12 else { throw ExtractError.malformed("stsc усечён") }
        struct Run { let firstChunk: Int; let samplesPerChunk: Int }
        var runs: [Run] = []
        runs.reserveCapacity(runCount)
        for i in 0..<runCount {
            let e = scBase + 8 + i * 12
            runs.append(Run(firstChunk: Int(readU32(data, e)), samplesPerChunk: Int(readU32(data, e + 4))))
        }

        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(sampleCount)
        var sampleIndex = 0
        for (chunkIdx, chunkOffset) in chunkOffsets.enumerated() {
            let chunkNumber = chunkIdx + 1
            // Актуальная запись stsc: последняя с firstChunk <= текущего (записи отсортированы).
            let perChunk = runs.last(where: { $0.firstChunk <= chunkNumber })?.samplesPerChunk ?? 0
            var offset = chunkOffset
            var s = 0
            while s < perChunk && sampleIndex < sampleCount {
                let size = sampleSize(sampleIndex)
                guard size > 0, offset >= 0 else {
                    throw ExtractError.malformed("Повреждённая таблица сэмплов")
                }
                ranges.append(offset..<offset + size)
                offset += size
                sampleIndex += 1
                s += 1
            }
            if sampleIndex >= sampleCount { break }
        }
        guard !ranges.isEmpty else { throw ExtractError.malformed("Дорожка пуста") }
        return ranges
    }

    // MARK: - Box-дерево ISO BMFF

    private struct Box {
        let type: String
        let payload: Range<Int> // содержимое (после заголовка)
        let end: Int            // конец бокса целиком
    }

    /// Разбирает заголовок бокса: [size:4][type:4], size==1 → 64-битный размер следом,
    /// size==0 → до конца области.
    private static func parseBox(_ data: Data, at offset: Int, limit: Int) -> Box? {
        guard offset + 8 <= limit else { return nil }
        var size = Int(readU32(data, offset))
        let type = fourCC(data, at: offset + 4)
        var headerSize = 8
        if size == 1 {
            guard offset + 16 <= limit else { return nil }
            size = Int(readU64(data, offset + 8))
            headerSize = 16
        } else if size == 0 {
            size = limit - offset
        }
        guard size >= headerSize, offset + size <= limit else { return nil }
        return Box(type: type, payload: (offset + headerSize)..<(offset + size), end: offset + size)
    }

    private static func firstBox(_ type: String, in data: Data, range: Range<Int>) -> Box? {
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            guard let box = parseBox(data, at: cursor, limit: range.upperBound) else { return nil }
            if box.type == type { return box }
            cursor = box.end
        }
        return nil
    }

    // MARK: - Чтение big-endian

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        var v: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &v) { data.copyBytes(to: $0, from: offset..<offset + 4) }
        return UInt32(bigEndian: v)
    }

    private static func readU64(_ data: Data, _ offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= data.count else { return 0 }
        var v: UInt64 = 0
        _ = withUnsafeMutableBytes(of: &v) { data.copyBytes(to: $0, from: offset..<offset + 8) }
        return UInt64(bigEndian: v)
    }

    private static func fourCC(_ data: Data, at offset: Int) -> String {
        guard offset >= 0, offset + 4 <= data.count else { return "" }
        return String(bytes: data.subdata(in: offset..<offset + 4), encoding: .ascii) ?? ""
    }
}
