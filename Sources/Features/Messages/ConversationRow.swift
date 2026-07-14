import SwiftUI

/// Строка диалога — общий рендер для основного списка, закреплённой секции и архива.
/// Чисто презентационная: всё непрочитанное/пин-состояние вычисляет вызывающая сторона.
struct ConversationRow: View {
    let convo: Conversation
    let author: WallViewModel.Author?
    let isUnread: Bool
    let unreadCount: Int
    /// Булавка справа от собеседника — как в Telegram, только в закреплённой секции.
    var showsPinIcon: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            CachedImage(url: author?.avatar) {
                ZStack { OVK.Palette.background; Image(systemName: "person.crop.square").foregroundColor(OVK.Palette.textSecondary) }
            }
            .frame(width: 48, height: 48)
            .clipped()
            .cornerRadius(4)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(author?.name ?? "Диалог")
                        .font(.subheadline).fontWeight(.semibold)
                        .foregroundColor(OVK.Palette.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    if let last = convo.lastMessage {
                        Text(Self.dateText(last.date))
                            .font(.caption2)
                            .foregroundColor(OVK.Palette.textSecondary)
                    }
                }
                HStack(spacing: 6) {
                    if let last = convo.lastMessage {
                        Text((last.isOut ? "Вы: " : "") + last.text)
                            .font(.footnote)
                            .foregroundColor(OVK.Palette.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    // Точное число знаем только из LongPoll (сервер отдаёт максимум «1»,
                    // проверяя лишь последнее сообщение) — иначе показываем точку.
                    if isUnread {
                        if unreadCount > 0 {
                            Text("\(unreadCount)")
                                .font(.caption2).fontWeight(.semibold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(OVK.Palette.primary))
                        } else {
                            Circle()
                                .fill(OVK.Palette.primary)
                                .frame(width: 9, height: 9)
                        }
                    }
                    if showsPinIcon {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundColor(OVK.Palette.textSecondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // DateFormatter дорог в создании — держим статически (вызывается в каждой строке).
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "HH:mm"
        return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM"
        return f
    }()

    private static func dateText(_ timestamp: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        return Calendar.current.isDateInToday(date)
            ? timeFormatter.string(from: date)
            : dayFormatter.string(from: date)
    }
}
