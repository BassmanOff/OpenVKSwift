import Foundation

/// Текст песни: синхронизированный (строки с таймкодами, LRCLIB) или обычный (без времени).
struct Lyrics: Codable, Equatable {
    struct Line: Codable, Equatable {
        /// Время начала строки в секундах (nil — текст без синхронизации).
        let time: Double?
        let text: String
    }

    let lines: [Line]
    let synced: Bool
    /// Откуда взят текст — для подписи («LRCLIB» / «OpenVK»).
    let source: String

    var isEmpty: Bool { lines.isEmpty }

    /// Обычный текст → строки без времени.
    static func plain(_ text: String, source: String) -> Lyrics {
        let ls = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { Line(time: nil, text: String($0)) }
        return Lyrics(lines: ls, synced: false, source: source)
    }

    /// LRC (`[mm:ss.xx] текст`) → синхронизированные строки. nil, если таймкодов нет.
    static func synced(_ lrc: String, source: String) -> Lyrics? {
        let parsed = parseLRC(lrc)
        guard !parsed.isEmpty else { return nil }
        return Lyrics(lines: parsed, synced: true, source: source)
    }

    // MARK: - Парсер LRC

    private static func parseLRC(_ lrc: String) -> [Line] {
        var result: [Line] = []
        for raw in lrc.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(raw)
            var idx = s.startIndex
            var times: [Double] = []
            // Считываем идущие в начале строки теги [..]; числовые — таймкоды, прочие (ar:, ti:) — пропускаем.
            while idx < s.endIndex, s[idx] == "[" {
                guard let close = s[idx...].firstIndex(of: "]") else { break }
                let tag = String(s[s.index(after: idx)..<close])
                if let t = parseTimestamp(tag) { times.append(t) }
                idx = s.index(after: close)
            }
            guard !times.isEmpty else { continue } // строка без таймкодов — метаданные, пропускаем
            let text = String(s[idx...]).trimmingCharacters(in: .whitespaces)
            for t in times { result.append(Line(time: t, text: text)) }
        }
        return result.sorted { ($0.time ?? 0) < ($1.time ?? 0) }
    }

    /// `mm:ss.xx` / `mm:ss.xxx` / `mm:ss` → секунды. Нечисловой тег → nil.
    private static func parseTimestamp(_ s: String) -> Double? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let mm = Double(parts[0]) else { return nil }
        guard let sec = Double(parts[1].replacingOccurrences(of: ",", with: ".")) else { return nil }
        return mm * 60 + sec
    }
}
