import Foundation

/// Полный индекс MP4-файла по его moov: сэмплы обеих дорожек с таймингами,
/// ключевые кадры, параметры H.264 (SPS/PPS). Строится из moov-данных,
/// скачанных одним Range-запросом — сам файл не нужен.
/// Используется HLS-стримером для нарезки сегментов и ремукса в MPEG-TS.
struct MP4Index {
    struct VideoSample {
        let offset: Int      // абсолютное смещение в файле
        let size: Int
        let dts: Int64       // в timescale дорожки
        let ctsOffset: Int   // composition offset (B-кадры)
        let isSync: Bool     // ключевой кадр (граница сегмента)
    }

    struct AudioSample {
        let offset: Int
        let size: Int
        let dts: Int64
    }

    struct VideoTrack {
        let timescale: Int
        let nalLengthSize: Int   // из avcC (обычно 4)
        let sps: [Data]
        let pps: [Data]
        let samples: [VideoSample]
    }

    struct AudioTrack {
        let timescale: Int
        let samples: [AudioSample]
    }

    let video: VideoTrack
    let audio: AudioTrack?
    /// Длительность видео в секундах.
    var duration: Double {
        guard let last = video.samples.last else { return 0 }
        return Double(last.dts) / Double(video.timescale)
    }

    enum IndexError: LocalizedError {
        case malformed(String)
        case unsupportedCodec(String)
        var errorDescription: String? {
            switch self {
            case .malformed(let m):        return m
            case .unsupportedCodec(let c): return "Неподдерживаемый видеокодек: \(c)"
            }
        }
    }

    // MARK: - Построение

    /// `moovData` должен начинаться с заголовка moov (или содержать его на верхнем уровне).
    static func build(moovData data: Data) throws -> MP4Index {
        guard let moov = firstBox("moov", in: data, range: 0..<data.count) else {
            throw IndexError.malformed("moov не найден")
        }

        var video: VideoTrack?
        var audio: AudioTrack?

        var cursor = moov.payload.lowerBound
        while cursor < moov.payload.upperBound {
            guard let box = parseBox(data, at: cursor, limit: moov.payload.upperBound) else { break }
            cursor = box.end
            guard box.type == "trak",
                  let mdia = firstBox("mdia", in: data, range: box.payload),
                  let hdlr = firstBox("hdlr", in: data, range: mdia.payload),
                  hdlr.payload.count >= 12,
                  let mdhd = firstBox("mdhd", in: data, range: mdia.payload),
                  let minf = firstBox("minf", in: data, range: mdia.payload),
                  let stbl = firstBox("stbl", in: data, range: minf.payload)
            else { continue }

            let handler = fourCC(data, at: hdlr.payload.lowerBound + 8)
            let timescale = try parseTimescale(data, mdhd: mdhd)

            if handler == "vide", video == nil {
                video = try parseVideoTrack(data, stbl: stbl, timescale: timescale)
            } else if handler == "soun", audio == nil {
                audio = try parseAudioTrack(data, stbl: stbl, timescale: timescale)
            }
        }

        guard let video else { throw IndexError.malformed("Видеодорожка не найдена") }
        return MP4Index(video: video, audio: audio)
    }

    // MARK: - Дорожки

    private static func parseVideoTrack(_ data: Data, stbl: Box, timescale: Int) throws -> VideoTrack {
        // stsd → avc1 → avcC (SPS/PPS + длина NAL-префикса).
        guard let stsd = firstBox("stsd", in: data, range: stbl.payload),
              stsd.payload.count >= 16 else {
            throw IndexError.malformed("stsd не найден")
        }
        let entryStart = stsd.payload.lowerBound + 8       // ver/flags(4) + count(4)
        let entrySize = Int(readU32(data, entryStart))
        let format = fourCC(data, at: entryStart + 4)
        guard format == "avc1" || format == "avc3" else {
            throw IndexError.unsupportedCodec(format)
        }
        // Внутри visual sample entry дочерние боксы начинаются после 8+78 байт заголовков.
        let childrenStart = entryStart + 8 + 78
        let entryEnd = min(entryStart + entrySize, stsd.payload.upperBound)
        guard childrenStart < entryEnd,
              let avcC = firstBox("avcC", in: data, range: childrenStart..<entryEnd) else {
            throw IndexError.malformed("avcC не найден")
        }
        let (nalLen, sps, pps) = try parseAVCC(data, avcC: avcC)

        let base = try sampleTable(data, stbl: stbl)
        let ctts = parseCTTS(data, stbl: stbl, sampleCount: base.count)
        let sync = parseSTSS(data, stbl: stbl)

        var samples: [VideoSample] = []
        samples.reserveCapacity(base.count)
        for (i, s) in base.enumerated() {
            samples.append(VideoSample(
                offset: s.offset, size: s.size, dts: s.dts,
                ctsOffset: ctts?[i] ?? 0,
                isSync: sync?.contains(i + 1) ?? true // нет stss = все ключевые
            ))
        }
        return VideoTrack(timescale: timescale, nalLengthSize: nalLen, sps: sps, pps: pps, samples: samples)
    }

    private static func parseAudioTrack(_ data: Data, stbl: Box, timescale: Int) throws -> AudioTrack {
        let base = try sampleTable(data, stbl: stbl)
        let samples = base.map { AudioSample(offset: $0.offset, size: $0.size, dts: $0.dts) }
        return AudioTrack(timescale: timescale, samples: samples)
    }

    // MARK: - Таблицы сэмплов (stsz/stsc/stco/stts)

    private struct BaseSample {
        let offset: Int
        let size: Int
        let dts: Int64
    }

    private static func sampleTable(_ data: Data, stbl: Box) throws -> [BaseSample] {
        guard let stsz = firstBox("stsz", in: data, range: stbl.payload),
              let stsc = firstBox("stsc", in: data, range: stbl.payload),
              let stts = firstBox("stts", in: data, range: stbl.payload)
        else { throw IndexError.malformed("Таблицы сэмплов неполные") }

        // stsz
        let szBase = stsz.payload.lowerBound
        guard stsz.payload.count >= 12 else { throw IndexError.malformed("stsz повреждён") }
        let uniformSize = Int(readU32(data, szBase + 4))
        let sampleCount = Int(readU32(data, szBase + 8))
        guard sampleCount > 0 else { throw IndexError.malformed("Пустая дорожка") }
        if uniformSize == 0 {
            guard stsz.payload.count >= 12 + sampleCount * 4 else { throw IndexError.malformed("stsz усечён") }
        }
        func sampleSize(_ i: Int) -> Int {
            uniformSize != 0 ? uniformSize : Int(readU32(data, szBase + 12 + i * 4))
        }

        // stco / co64
        var chunkOffsets: [Int] = []
        if let stco = firstBox("stco", in: data, range: stbl.payload) {
            let base = stco.payload.lowerBound
            let n = Int(readU32(data, base + 4))
            guard stco.payload.count >= 8 + n * 4 else { throw IndexError.malformed("stco усечён") }
            chunkOffsets = (0..<n).map { Int(readU32(data, base + 8 + $0 * 4)) }
        } else if let co64 = firstBox("co64", in: data, range: stbl.payload) {
            let base = co64.payload.lowerBound
            let n = Int(readU32(data, base + 4))
            guard co64.payload.count >= 8 + n * 8 else { throw IndexError.malformed("co64 усечён") }
            chunkOffsets = (0..<n).map { Int(readU64(data, base + 8 + $0 * 8)) }
        } else {
            throw IndexError.malformed("Смещения чанков не найдены")
        }

        // stsc
        let scBase = stsc.payload.lowerBound
        let runCount = Int(readU32(data, scBase + 4))
        guard stsc.payload.count >= 8 + runCount * 12 else { throw IndexError.malformed("stsc усечён") }
        struct Run { let firstChunk: Int; let samplesPerChunk: Int }
        var runs: [Run] = []
        runs.reserveCapacity(runCount)
        for i in 0..<runCount {
            let e = scBase + 8 + i * 12
            runs.append(Run(firstChunk: Int(readU32(data, e)), samplesPerChunk: Int(readU32(data, e + 4))))
        }

        // stts → длительности (dts накапливается)
        let ttBase = stts.payload.lowerBound
        let ttCount = Int(readU32(data, ttBase + 4))
        guard stts.payload.count >= 8 + ttCount * 8 else { throw IndexError.malformed("stts усечён") }
        var durations: [Int] = []
        durations.reserveCapacity(sampleCount)
        outer: for i in 0..<ttCount {
            let e = ttBase + 8 + i * 8
            let count = Int(readU32(data, e))
            let delta = Int(readU32(data, e + 4))
            for _ in 0..<count {
                durations.append(delta)
                if durations.count >= sampleCount { break outer }
            }
        }
        while durations.count < sampleCount { durations.append(durations.last ?? 0) }

        // Сборка: чанки → смещения сэмплов; dts по stts.
        var samples: [BaseSample] = []
        samples.reserveCapacity(sampleCount)
        var sampleIndex = 0
        var dts: Int64 = 0
        for (chunkIdx, chunkOffset) in chunkOffsets.enumerated() {
            let chunkNumber = chunkIdx + 1
            let perChunk = runs.last(where: { $0.firstChunk <= chunkNumber })?.samplesPerChunk ?? 0
            var offset = chunkOffset
            var s = 0
            while s < perChunk && sampleIndex < sampleCount {
                let size = sampleSize(sampleIndex)
                guard size > 0, offset >= 0 else { throw IndexError.malformed("Повреждённая таблица сэмплов") }
                samples.append(BaseSample(offset: offset, size: size, dts: dts))
                dts += Int64(durations[sampleIndex])
                offset += size
                sampleIndex += 1
                s += 1
            }
            if sampleIndex >= sampleCount { break }
        }
        guard samples.count == sampleCount else { throw IndexError.malformed("Сэмплы не сходятся с таблицами") }
        return samples
    }

    /// ctts → composition offset на каждый сэмпл (nil, если бокса нет).
    private static func parseCTTS(_ data: Data, stbl: Box, sampleCount: Int) -> [Int]? {
        guard let ctts = firstBox("ctts", in: data, range: stbl.payload) else { return nil }
        let base = ctts.payload.lowerBound
        guard ctts.payload.count >= 8 else { return nil }
        let entryCount = Int(readU32(data, base + 4))
        guard ctts.payload.count >= 8 + entryCount * 8 else { return nil }
        var offsets: [Int] = []
        offsets.reserveCapacity(sampleCount)
        for i in 0..<entryCount {
            let e = base + 8 + i * 8
            let count = Int(readU32(data, e))
            // Знаковый (v1) и беззнаковый (v0) варианты — читаем как Int32.
            let value = Int(Int32(bitPattern: readU32(data, e + 4)))
            for _ in 0..<count {
                offsets.append(value)
                if offsets.count >= sampleCount { return offsets }
            }
        }
        while offsets.count < sampleCount { offsets.append(0) }
        return offsets
    }

    /// stss → множество номеров ключевых сэмплов (1-based); nil = все ключевые.
    private static func parseSTSS(_ data: Data, stbl: Box) -> Set<Int>? {
        guard let stss = firstBox("stss", in: data, range: stbl.payload) else { return nil }
        let base = stss.payload.lowerBound
        guard stss.payload.count >= 8 else { return nil }
        let count = Int(readU32(data, base + 4))
        guard stss.payload.count >= 8 + count * 4 else { return nil }
        var set = Set<Int>(minimumCapacity: count)
        for i in 0..<count {
            set.insert(Int(readU32(data, base + 8 + i * 4)))
        }
        return set
    }

    // MARK: - Заголовки

    private static func parseTimescale(_ data: Data, mdhd: Box) throws -> Int {
        let base = mdhd.payload.lowerBound
        guard mdhd.payload.count >= 4 else { throw IndexError.malformed("mdhd повреждён") }
        let version = data[data.startIndex + base]
        // v0: ver/flags(4) ctime(4) mtime(4) timescale(4); v1: времена по 8 байт.
        let offset = version == 1 ? base + 20 : base + 12
        guard mdhd.payload.upperBound >= offset + 4 else { throw IndexError.malformed("mdhd усечён") }
        let timescale = Int(readU32(data, offset))
        guard timescale > 0 else { throw IndexError.malformed("Нулевой timescale") }
        return timescale
    }

    private static func parseAVCC(_ data: Data, avcC: Box) throws -> (nalLength: Int, sps: [Data], pps: [Data]) {
        let bytes = [UInt8](data.subdata(in: avcC.payload))
        guard bytes.count >= 7, bytes[0] == 1 else { throw IndexError.malformed("avcC повреждён") }
        let nalLength = Int(bytes[4] & 0x03) + 1
        var pos = 5
        let spsCount = Int(bytes[pos] & 0x1F); pos += 1
        var sps: [Data] = []
        for _ in 0..<spsCount {
            guard pos + 2 <= bytes.count else { throw IndexError.malformed("SPS усечён") }
            let len = Int(bytes[pos]) << 8 | Int(bytes[pos + 1]); pos += 2
            guard pos + len <= bytes.count else { throw IndexError.malformed("SPS усечён") }
            sps.append(Data(bytes[pos..<pos + len])); pos += len
        }
        guard pos < bytes.count else { throw IndexError.malformed("PPS отсутствует") }
        let ppsCount = Int(bytes[pos]); pos += 1
        var pps: [Data] = []
        for _ in 0..<ppsCount {
            guard pos + 2 <= bytes.count else { throw IndexError.malformed("PPS усечён") }
            let len = Int(bytes[pos]) << 8 | Int(bytes[pos + 1]); pos += 2
            guard pos + len <= bytes.count else { throw IndexError.malformed("PPS усечён") }
            pps.append(Data(bytes[pos..<pos + len])); pos += len
        }
        guard !sps.isEmpty, !pps.isEmpty else { throw IndexError.malformed("SPS/PPS пусты") }
        return (nalLength, sps, pps)
    }

    // MARK: - Box-обход (локальная копия: у экстрактора помощники приватные)

    private struct Box {
        let type: String
        let payload: Range<Int>
        let end: Int
    }

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
