import SwiftUI

/// Строка комментария: автор, текст (с ссылками), фото/аудио/видео, дата.
/// Используется в комментариях к записям и в обсуждениях сообществ.
struct CommentRow: View {
    let comment: Comment
    let author: WallViewModel.Author?
    /// Скорректированный id автора (board-комменты от имени группы приходят с положительным
    /// from_id — TopicView передаёт отрицательный). nil — берём comment.fromID как есть.
    var authorID: Int? = nil
    /// Владелец стены/сообщества (для likes.add). Для лайков комментов owner_id не критичен.
    var ownerID: Int = 0
    /// Нажатие «Ответить» (подставляет упоминание в поле ввода). nil — кнопку не показываем.
    var onReply: (() -> Void)? = nil

    @EnvironmentObject private var likes: LikesManager
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { openAuthor() } label: {
                CachedImage(url: author?.avatar) {
                    ZStack { OVK.Palette.background; Image(systemName: "person.crop.square").foregroundColor(OVK.Palette.textSecondary) }
                }
                .frame(width: 36, height: 36)
                .clipped()
                .cornerRadius(4)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Button { openAuthor() } label: {
                    Text(author?.name ?? "Пользователь")
                        .font(.subheadline).fontWeight(.semibold)
                        .foregroundColor(OVK.Palette.link)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                if !comment.text.isEmpty {
                    Text(linkifiedText(comment.text))
                        .font(.subheadline)
                        .foregroundColor(OVK.Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(comment.photos) { photo in
                    CachedImage(url: photo.bestURL, contentMode: .fit) { OVK.Palette.background }
                        .frame(maxWidth: 220, maxHeight: 200, alignment: .leading)
                        .cornerRadius(6)
                }
                MediaAttachmentsView(audios: comment.audios, videos: comment.videos)

                HStack(spacing: 16) {
                    Text(Self.dateText(comment.date))
                        .font(.caption2)
                        .foregroundColor(OVK.Palette.textSecondary)

                    Button {
                        likes.toggle(comment: comment, ownerID: ownerID, settings: settings)
                    } label: {
                        Label("\(likes.count(comment: comment))",
                              systemImage: likes.isLiked(comment: comment) ? "heart.fill" : "heart")
                            .font(.caption2)
                            .foregroundColor(likes.isLiked(comment: comment) ? .red : OVK.Palette.textSecondary)
                    }
                    .buttonStyle(.plain)

                    if let onReply {
                        Button(action: onReply) {
                            Label("Ответить", systemImage: "arrowshape.turn.up.left")
                                .font(.caption2)
                                .foregroundColor(OVK.Palette.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Тап по автору: профиль пользователя или страница сообщества (через маршрутизатор ссылок).
    private func openAuthor() {
        let id = authorID ?? comment.fromID
        guard id != 0 else { return }
        let path = id > 0 ? "id\(id)" : "club\(-id)"
        if let url = URL(string: "https://openvk.org/\(path)") { openURL(url) }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM 'в' HH:mm"
        return f
    }()

    private static func dateText(_ timestamp: Int) -> String {
        formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }
}
