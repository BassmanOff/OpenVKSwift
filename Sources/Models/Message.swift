import Foundation

/// Личное сообщение (messages.getHistory / last_message в getConversations).
/// ПРИМЕЧАНИЕ: API OpenVK не отдаёт вложения в ЛС — только текст.
/// Codable: encode нужен для дискового кэша диалогов/переписок.
struct Message: Codable, Identifiable, Hashable {
    let id: Int
    let fromID: Int
    let date: Int
    let text: String
    /// Исходящее (out=1) — написано текущим пользователем.
    let isOut: Bool

    enum CodingKeys: String, CodingKey {
        case id, date, out, text, body
        case fromID = "from_id"
    }

    /// Ручное создание — для мгновенной вставки события LongPoll (id у события настоящий,
    /// серверный; фоновая синхронизация потом сверит поля и дедуплицирует по id).
    init(id: Int, fromID: Int, date: Int, text: String, isOut: Bool) {
        self.id = id
        self.fromID = fromID
        self.date = date
        self.text = text
        self.isOut = isOut
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id     = (try? c.decode(Int.self, forKey: .id)) ?? 0
        fromID = (try? c.decode(Int.self, forKey: .fromID)) ?? 0
        date   = (try? c.decode(Int.self, forKey: .date)) ?? 0
        // Сервер шлёт и text, и body (одинаковые); берём что есть.
        // decodingHTMLEntities: сервер отдаёт текст пропущенным через htmlspecialchars
        // (см. TRichText::getText) — без раскодирования "<"/">"/"&" показывались бы как есть.
        text   = ((try? c.decode(String.self, forKey: .text))
              ?? (try? c.decode(String.self, forKey: .body)) ?? "").decodingHTMLEntities
        isOut  = ((try? c.decode(Int.self, forKey: .out)) ?? 0) == 1
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(fromID, forKey: .fromID)
        try c.encode(date, forKey: .date)
        try c.encode(text, forKey: .text)
        try c.encode(isOut ? 1 : 0, forKey: .out)
    }
}

/// Диалог из messages.getConversations: собеседник + последнее сообщение.
struct Conversation: Codable, Identifiable, Hashable {
    let peerID: Int
    let unreadCount: Int
    let lastMessage: Message?

    var id: Int { peerID }

    enum CodingKeys: String, CodingKey {
        case conversation
        case lastMessage = "last_message"
    }
    private enum ConvoKeys: String, CodingKey {
        case peer
        case unreadCount = "unread_count"
    }
    private enum PeerKeys: String, CodingKey { case id }

    /// Ручное создание — для закреплённого диалога, недогруженного пагинацией
    /// (см. ConversationsViewModel.ensurePinnedLoaded: строим по messages.getHistory,
    /// не по messages.getConversations — там уже нет постраничного «конверта»).
    init(peerID: Int, unreadCount: Int, lastMessage: Message?) {
        self.peerID = peerID
        self.unreadCount = unreadCount
        self.lastMessage = lastMessage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let convo = try c.nestedContainer(keyedBy: ConvoKeys.self, forKey: .conversation)
        let peer = try convo.nestedContainer(keyedBy: PeerKeys.self, forKey: .peer)
        peerID = (try? peer.decode(Int.self, forKey: .id)) ?? 0
        unreadCount = (try? convo.decode(Int.self, forKey: .unreadCount)) ?? 0
        lastMessage = try? c.decode(Message.self, forKey: .lastMessage)
    }

    /// Пишем в той же вложенной форме, что отдаёт сервер (для дискового кэша).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        var convo = c.nestedContainer(keyedBy: ConvoKeys.self, forKey: .conversation)
        var peer = convo.nestedContainer(keyedBy: PeerKeys.self, forKey: .peer)
        try peer.encode(peerID, forKey: .id)
        try convo.encode(unreadCount, forKey: .unreadCount)
        try c.encodeIfPresent(lastMessage, forKey: .lastMessage)
    }
}

/// Ответ messages.getConversations (extended=1).
struct ConversationsResponse: Decodable {
    let count: Int?
    let items: [Conversation]
    let profiles: [User]?
}

/// Ответ messages.getHistory.
struct HistoryResponse: Decodable {
    let items: [Message]
    let profiles: [User]?
}
