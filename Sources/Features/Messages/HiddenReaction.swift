import Foundation

/// Реакции на сообщения поверх обычных ЛС. Сервер OpenVK реакций не умеет, поэтому реакцию
/// отправляем как СООБЩЕНИЕ вида «эмодзи + невидимая метка с id целевого сообщения».
/// На сайте это выглядит как отправленный эмодзи, а наш клиент прячет такое сообщение из
/// ленты и рисует реакцию на нужном пузыре.
///
/// ВАЖНО: работаем со СКАЛЯРАМИ Unicode (`unicodeScalars`), а НЕ с Character. Zero-width
/// символы сливаются в соседние grapheme-кластеры, поэтому перебор по Character и
/// String.range(of:) искажают биты id (реакция «терялась» после перезапуска). Сервер эти
/// символы сохраняет (его removeZalgo чистит только \p{M}, а это \p{Cf}; send не санитайзит).
enum HiddenReaction {
    private static let bit0 = Unicode.Scalar(0x200B)! // ZERO WIDTH SPACE            → бит 0
    private static let bit1 = Unicode.Scalar(0x200C)! // ZERO WIDTH NON-JOINER       → бит 1
    private static let mark = Unicode.Scalar(0x2060)! // WORD JOINER (×2 = старт метки)
    private static let stop = Unicode.Scalar(0x2061)! // FUNCTION APPLICATION (конец метки)

    /// Набор доступных реакций (как в Telegram).
    static let palette = ["👍", "❤️", "🔥", "😂", "😮", "😢", "👏"]

    /// Видимый эмодзи + невидимая метка (флаг снятия + targetID в двоичном виде).
    /// Для снятия реакции всё равно шлём видимый эмодзи (на сайте — просто эмодзи ещё раз),
    /// чтобы сообщение не было пустым и сервер его принял.
    static func encode(targetID: Int, emoji: String, remove: Bool = false) -> String {
        var s = emoji
        s.unicodeScalars.append(mark)
        s.unicodeScalars.append(mark)
        s.unicodeScalars.append(remove ? bit1 : bit0)                 // флаг
        for ch in String(targetID, radix: 2) {                        // биты id
            s.unicodeScalars.append(ch == "1" ? bit1 : bit0)
        }
        s.unicodeScalars.append(stop)
        return s
    }

    /// Если сообщение — реакция, возвращает (targetID, emoji, remove), иначе nil.
    static func decode(_ text: String) -> (targetID: Int, emoji: String, remove: Bool)? {
        let sc = Array(text.unicodeScalars)
        guard sc.count >= 5 else { return nil }
        // Старт — две подряд WORD JOINER.
        guard let startIdx = (0..<(sc.count - 1)).first(where: { sc[$0] == mark && sc[$0 + 1] == mark })
        else { return nil }
        let inner = startIdx + 2
        guard let stopIdx = (inner..<sc.count).first(where: { sc[$0] == stop }),
              stopIdx - inner >= 2 else { return nil }               // флаг + минимум 1 бит

        let flag = sc[inner]
        var bits = ""
        for i in (inner + 1)..<stopIdx {
            if sc[i] == bit1 { bits += "1" }
            else if sc[i] == bit0 { bits += "0" }
            else { return nil }                                       // посторонний символ — не наша метка
        }
        guard let id = Int(bits, radix: 2) else { return nil }

        var emoji = ""
        emoji.unicodeScalars.append(contentsOf: sc[0..<startIdx])
        return (id, emoji, flag == bit1)
    }
}
