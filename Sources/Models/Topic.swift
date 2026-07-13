import Foundation

/// Тема обсуждения сообщества (board.getTopics).
struct Topic: Decodable, Identifiable, Hashable {
    let topicID: Int
    let title: String
    let comments: Int
    let isClosed: Bool

    var id: Int { topicID }

    enum CodingKeys: String, CodingKey {
        case topicID = "id"
        case title
        case comments
        case isClosed = "is_closed"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        topicID  = (try? c.decode(Int.self, forKey: .topicID)) ?? 0
        title    = (try? c.decode(String.self, forKey: .title)) ?? ""
        comments = (try? c.decode(Int.self, forKey: .comments)) ?? 0
        isClosed = ((try? c.decode(Int.self, forKey: .isClosed)) ?? 0) == 1
    }
}
