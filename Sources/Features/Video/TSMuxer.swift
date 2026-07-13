import Foundation

/// Мультиплексор MPEG-TS: собирает сегмент HLS из сэмплов H.264 и MP3.
/// Именно то, чего не умеет AVFoundation: MP3-звук в TS Apple HLS играет штатно
/// (Authoring Spec допускает MPEG-1 Layer III), поэтому транскодирование не нужно.
///
/// Формат: пакеты по 188 байт; PAT (PID 0) и PMT (PID 4096) в начале сегмента;
/// видео PES на PID 256 (stream_type 0x1B, H.264 Annex B) с PCR;
/// аудио PES на PID 257 (stream_type 0x03, MPEG-1 audio).
enum TSMuxer {
    struct VideoUnit {
        let data: Data       // сэмпл в исходном AVCC-формате (длина+NAL)
        let pts: Int64       // 90 кГц
        let dts: Int64       // 90 кГц
        let isSync: Bool
    }

    struct AudioUnit {
        let data: Data       // сырой MP3-кадр
        let pts: Int64       // 90 кГц
    }

    private static let videoPID: UInt16 = 256
    private static let audioPID: UInt16 = 257
    private static let pmtPID: UInt16 = 4096

    /// Собирает один TS-сегмент.
    static func mux(
        video: [VideoUnit],
        audio: [AudioUnit],
        sps: [Data],
        pps: [Data],
        nalLengthSize: Int
    ) -> Data {
        var out = Data()
        out.reserveCapacity((video.reduce(0) { $0 + $1.data.count } + audio.reduce(0) { $0 + $1.data.count }) * 12 / 10)

        var ccPAT: UInt8 = 0
        var ccPMT: UInt8 = 0
        var ccVideo: UInt8 = 0
        var ccAudio: UInt8 = 0

        writeTable(&out, pid: 0, table: patTable(), cc: &ccPAT)
        writeTable(&out, pid: pmtPID, table: pmtTable(hasAudio: !audio.isEmpty), cc: &ccPMT)

        // Чередуем PES по времени декодирования (аудио группируем пачками).
        var vIndex = 0
        var aIndex = 0
        let audioGroup = 12 // MP3-кадров на один PES (меньше оверхеда)

        while vIndex < video.count || aIndex < audio.count {
            let nextVideoDTS = vIndex < video.count ? video[vIndex].dts : Int64.max
            let nextAudioPTS = aIndex < audio.count ? audio[aIndex].pts : Int64.max

            if nextVideoDTS <= nextAudioPTS {
                let unit = video[vIndex]
                vIndex += 1
                let annexB = annexBPayload(unit, sps: sps, pps: pps, nalLengthSize: nalLengthSize)
                let pes = pesPacket(streamID: 0xE0, pts: unit.pts, dts: unit.dts, payload: annexB, unboundedLength: true)
                writePES(&out, pid: videoPID, pes: pes, cc: &ccVideo, pcr: unit.dts)
            } else {
                // Пачка аудио-кадров одним PES (PTS первого кадра).
                let end = min(aIndex + audioGroup, audio.count)
                var payload = Data()
                for i in aIndex..<end { payload.append(audio[i].data) }
                let pts = audio[aIndex].pts
                aIndex = end
                let pes = pesPacket(streamID: 0xC0, pts: pts, dts: nil, payload: payload, unboundedLength: false)
                writePES(&out, pid: audioPID, pes: pes, cc: &ccAudio, pcr: nil)
            }
        }
        return out
    }

    // MARK: - H.264: AVCC → Annex B

    private static func annexBPayload(_ unit: VideoUnit, sps: [Data], pps: [Data], nalLengthSize: Int) -> Data {
        var out = Data(capacity: unit.data.count + 128)
        let startCode: [UInt8] = [0, 0, 0, 1]

        // AUD — Access Unit Delimiter (Apple-плееры любят явные границы кадров).
        out.append(contentsOf: startCode)
        out.append(contentsOf: [0x09, 0xF0])

        // Перед ключевым кадром — SPS/PPS (сегменты должны быть самодостаточны).
        if unit.isSync {
            for s in sps { out.append(contentsOf: startCode); out.append(s) }
            for p in pps { out.append(contentsOf: startCode); out.append(p) }
        }

        // NAL-ы сэмпла: длина (nalLengthSize байт, BE) → стартовый код.
        let bytes = [UInt8](unit.data)
        var pos = 0
        while pos + nalLengthSize <= bytes.count {
            var len = 0
            for i in 0..<nalLengthSize { len = len << 8 | Int(bytes[pos + i]) }
            pos += nalLengthSize
            guard len > 0, pos + len <= bytes.count else { break }
            out.append(contentsOf: startCode)
            out.append(contentsOf: bytes[pos..<pos + len])
            pos += len
        }
        return out
    }

    // MARK: - PES

    private static func pesPacket(streamID: UInt8, pts: Int64, dts: Int64?, payload: Data, unboundedLength: Bool) -> Data {
        var header = Data()
        header.append(contentsOf: [0x00, 0x00, 0x01, streamID])

        let ptsDtsFlags: UInt8 = dts != nil ? 0b11 : 0b10
        let headerDataLength = dts != nil ? 10 : 5
        let packetLength: Int
        if unboundedLength {
            packetLength = 0 // разрешено для видео
        } else {
            packetLength = 3 + headerDataLength + payload.count // после поля длины
        }
        header.append(UInt8((packetLength >> 8) & 0xFF))
        header.append(UInt8(packetLength & 0xFF))
        header.append(0x80)                              // '10' + без скремблинга/приоритета
        header.append(ptsDtsFlags << 6)                  // только PTS(+DTS)
        header.append(UInt8(headerDataLength))
        appendTimestamp(&header, marker: dts != nil ? 0b0011 : 0b0010, value: pts)
        if let dts {
            appendTimestamp(&header, marker: 0b0001, value: dts)
        }
        header.append(payload)
        return header
    }

    /// 33-битный таймстемп в 5 байтах (формат PTS/DTS).
    private static func appendTimestamp(_ data: inout Data, marker: UInt8, value: Int64) {
        let v = UInt64(bitPattern: value) & 0x1_FFFF_FFFF
        data.append(UInt8(marker) << 4 | UInt8((v >> 29) & 0x0E) | 0x01)
        data.append(UInt8((v >> 22) & 0xFF))
        data.append(UInt8((v >> 14) & 0xFE) | 0x01)
        data.append(UInt8((v >> 7) & 0xFF))
        data.append(UInt8((v << 1) & 0xFE) | 0x01)
    }

    // MARK: - TS-пакетизация

    /// Режет PES на 188-байтные пакеты; PCR — в первом пакете (adaptation field).
    private static func writePES(_ out: inout Data, pid: UInt16, pes: Data, cc: inout UInt8, pcr: Int64?) {
        let bytes = [UInt8](pes)
        var pos = 0
        var first = true

        while pos < bytes.count {
            var packet = Data(capacity: 188)
            packet.append(0x47)
            let pusi: UInt8 = first ? 0x40 : 0x00
            packet.append(pusi | UInt8((pid >> 8) & 0x1F))
            packet.append(UInt8(pid & 0xFF))

            let remaining = bytes.count - pos
            var adaptation = Data()

            if first, let pcr {
                // Adaptation field с PCR.
                var af = Data()
                af.append(0x10) // только PCR
                let base = UInt64(bitPattern: pcr) & 0x1_FFFF_FFFF
                af.append(UInt8((base >> 25) & 0xFF))
                af.append(UInt8((base >> 17) & 0xFF))
                af.append(UInt8((base >> 9) & 0xFF))
                af.append(UInt8((base >> 1) & 0xFF))
                af.append(UInt8((base << 7) & 0x80) | 0x7E) // бит base + reserved
                af.append(0x00)                              // PCR extension
                adaptation = af
            }

            // Свободное место под данные с учётом adaptation.
            var headerLen = 4 + (adaptation.isEmpty ? 0 : 1 + adaptation.count)
            var payloadLen = 188 - headerLen

            if remaining < payloadLen {
                // Добиваем stuffing-ом через adaptation field.
                let stuffing = payloadLen - remaining
                if adaptation.isEmpty && stuffing == 1 {
                    adaptation = Data() // поле длиной 0 (одиночный байт длины)
                    headerLen = 5
                } else if adaptation.isEmpty {
                    adaptation = Data([0x00]) // флаги
                    adaptation.append(Data(repeating: 0xFF, count: stuffing - 2))
                    headerLen = 4 + 1 + adaptation.count
                } else {
                    adaptation.append(Data(repeating: 0xFF, count: stuffing))
                    headerLen = 4 + 1 + adaptation.count
                }
                payloadLen = 188 - headerLen
            }

            let hasAdaptation = headerLen > 4
            packet.append((hasAdaptation ? 0x30 : 0x10) | cc)
            cc = (cc + 1) & 0x0F
            if hasAdaptation {
                packet.append(UInt8(headerLen - 5)) // длина adaptation после байта длины
                packet.append(adaptation)
            }

            let take = min(payloadLen, remaining)
            packet.append(contentsOf: bytes[pos..<pos + take])
            pos += take

            // Паранойя: пакет обязан быть ровно 188.
            if packet.count < 188 {
                packet.append(Data(repeating: 0xFF, count: 188 - packet.count))
            }
            out.append(packet)
            first = false
        }
    }

    /// Пакет с таблицей (PAT/PMT): pointer_field + таблица + stuffing.
    private static func writeTable(_ out: inout Data, pid: UInt16, table: Data, cc: inout UInt8) {
        var packet = Data(capacity: 188)
        packet.append(0x47)
        packet.append(0x40 | UInt8((pid >> 8) & 0x1F))
        packet.append(UInt8(pid & 0xFF))
        packet.append(0x10 | cc)
        cc = (cc + 1) & 0x0F
        packet.append(0x00) // pointer_field
        packet.append(table)
        packet.append(Data(repeating: 0xFF, count: 188 - packet.count))
        out.append(packet)
    }

    // MARK: - PAT / PMT

    private static func patTable() -> Data {
        var body = Data()
        body.append(contentsOf: [0x00, 0x01]) // transport_stream_id
        body.append(0xC1)                     // version 0, current
        body.append(contentsOf: [0x00, 0x00]) // section/last section
        body.append(contentsOf: [0x00, 0x01]) // program 1
        body.append(UInt8(0xE0 | (pmtPID >> 8))); body.append(UInt8(pmtPID & 0xFF))
        return section(tableID: 0x00, body: body)
    }

    private static func pmtTable(hasAudio: Bool) -> Data {
        var body = Data()
        body.append(contentsOf: [0x00, 0x01]) // program 1
        body.append(0xC1)
        body.append(contentsOf: [0x00, 0x00])
        body.append(UInt8(0xE0 | (videoPID >> 8))); body.append(UInt8(videoPID & 0xFF)) // PCR PID
        body.append(contentsOf: [0xF0, 0x00]) // program_info_length 0
        // H.264
        body.append(0x1B)
        body.append(UInt8(0xE0 | (videoPID >> 8))); body.append(UInt8(videoPID & 0xFF))
        body.append(contentsOf: [0xF0, 0x00])
        if hasAudio {
            // MPEG-1 audio (Layer III).
            body.append(0x03)
            body.append(UInt8(0xE0 | (audioPID >> 8))); body.append(UInt8(audioPID & 0xFF))
            body.append(contentsOf: [0xF0, 0x00])
        }
        return section(tableID: 0x02, body: body)
    }

    /// Оборачивает тело в секцию PSI: заголовок с длиной + CRC32 (MPEG).
    private static func section(tableID: UInt8, body: Data) -> Data {
        var section = Data()
        section.append(tableID)
        let length = body.count + 4 // + CRC
        section.append(UInt8(0xB0 | ((length >> 8) & 0x0F)))
        section.append(UInt8(length & 0xFF))
        section.append(body)
        let crc = crc32MPEG([UInt8](section))
        section.append(UInt8((crc >> 24) & 0xFF))
        section.append(UInt8((crc >> 16) & 0xFF))
        section.append(UInt8((crc >> 8) & 0xFF))
        section.append(UInt8(crc & 0xFF))
        return section
    }

    /// CRC32 в варианте MPEG-2 (полином 0x04C11DB7, без отражений).
    private static func crc32MPEG(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in bytes {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
            }
        }
        return crc
    }
}
