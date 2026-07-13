import Foundation

/// Голосование (polls.getById/create). У постов бывает максимум одно вложение-голосование.
/// Сервер мешает настоящие JSON bool (multiple/closed/disable_unvote) и int 0/1
/// (can_vote/anonymous) в одном ответе — декодим оба варианта явно, не полагаясь на синтез.
struct Poll: Decodable, Identifiable, Hashable {
    let id: Int
    let ownerID: Int
    let question: String
    let votes: Int
    let multiple: Bool
    let anonymous: Bool
    let disableUnvote: Bool
    let closed: Bool
    let canVote: Bool
    let endDate: Int
    /// Id вариантов, за которые уже проголосовал текущий пользователь.
    let answerIDs: [Int]
    let answers: [Answer]

    struct Answer: Decodable, Identifiable, Hashable {
        let id: Int
        let text: String
        let votes: Int
        let rate: Double

        enum CodingKeys: String, CodingKey { case id, text, votes, rate }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? c.decode(Int.self, forKey: .id)) ?? 0
            text = (try? c.decode(String.self, forKey: .text)) ?? ""
            votes = (try? c.decode(Int.self, forKey: .votes)) ?? 0
            // pct может прийти как целое число (50), если процент ровный — PHP не допишет ".0".
            rate = (try? c.decode(Double.self, forKey: .rate)) ?? Double((try? c.decode(Int.self, forKey: .rate)) ?? 0)
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, question, votes, multiple, anonymous, closed, answers
        case ownerID = "owner_id"
        case disableUnvote = "disable_unvote"
        case canVote = "can_vote"
        case endDate = "end_date"
        case answerIDs = "answer_ids"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        ownerID = (try? c.decode(Int.self, forKey: .ownerID)) ?? 0
        question = (try? c.decode(String.self, forKey: .question)) ?? ""
        votes = (try? c.decode(Int.self, forKey: .votes)) ?? 0
        endDate = (try? c.decode(Int.self, forKey: .endDate)) ?? 0
        answerIDs = (try? c.decode([Int].self, forKey: .answerIDs)) ?? []
        answers = (try? c.decode([Answer].self, forKey: .answers)) ?? []
        // ВАЖНО: два эндпоинта отдают bool-поля В РАЗНЫХ ТИПАХ. polls.getById — int 0/1,
        // а wall.get (getApiPoll, лента) — настоящие JSON bool. Модель кормится ОБОИМИ,
        // поэтому декодим и bool, и int. Раньше can_vote декодился только как Int → в ленте
        // (bool true) падал в 0 → canVote=false → виджет показывал результаты без кнопки голоса.
        multiple = Self.flexBool(c, .multiple) ?? false
        closed = Self.flexBool(c, .closed) ?? false
        anonymous = Self.flexBool(c, .anonymous) ?? false
        canVote = Self.flexBool(c, .canVote) ?? false
        // disable_unvote в ленте ИНВЕРТИРОВАН относительно polls.getById (сервер шлёт
        // isRevotable() вместо !isRevotable()) — полю доверять нельзя, кнопку отмены голоса
        // гейтим не по нему (см. PollCardView).
        disableUnvote = Self.flexBool(c, .disableUnvote) ?? false
    }

    /// Терпимо к обоим представлениям: JSON bool (лента) и int 0/1 (polls.getById).
    private static func flexBool(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Bool? {
        if let b = try? c.decode(Bool.self, forKey: key) { return b }
        if let i = try? c.decode(Int.self, forKey: key) { return i == 1 }
        return nil
    }

    var hasVoted: Bool { !answerIDs.isEmpty }
}
