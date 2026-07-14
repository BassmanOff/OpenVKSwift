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
    /// Можно ли удалить комментарий. onDelete nil — пункт/кнопка не показываются.
    var canDelete: Bool = false
    var onDelete: (() -> Void)? = nil

    @EnvironmentObject private var likes: LikesManager
    @EnvironmentObject private var photoHero: PhotoHeroCoordinator
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openURL) private var openURL
    @State private var showLikers = false
    @State private var confirmDelete = false

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
                ForEach(Array(comment.photos.enumerated()), id: \.element.id) { i, photo in
                    // Обёртка с правильным aspectRatio для placeholder'а, чтобы не прыгал layout
                    ZStack {
                        OVK.Palette.background
                            .aspectRatio(photo.aspectRatio ?? 1.4, contentMode: .fit)
                        CachedImage(url: photo.bestURL, contentMode: .fit) { OVK.Palette.background }
                    }
                    .aspectRatio(photo.aspectRatio ?? 1.4, contentMode: .fit)
                    .frame(maxWidth: 220, maxHeight: 200, alignment: .leading)
                    .cornerRadius(6)
                    .photoHeroSource(photos: comment.photos, index: i, post: nil, coordinator: photoHero)
                }
                MediaAttachmentsView(audios: comment.audios, videos: comment.videos)

                HStack(spacing: 16) {
                    Text(Self.dateText(comment.date))
                        .font(.caption2)
                        .foregroundColor(OVK.Palette.textSecondary)

                    // Тап — лайк, долгий тап — список оценивших. Раздельные .onTapGesture
                    // и .onLongPressGesture SwiftUI арбитрирует сам (быстрый тап засчитывает
                    // тап; удержание >0.4с — только long-press, тап при этом НЕ срабатывает).
                    // Не Button + .simultaneousGesture (оба срабатывали разом: лайк И список)
                    // и не LongPress.exclusively(before: Tap) (тап-лайк проглатывался).
                    Label("\(likes.count(comment: comment))",
                          systemImage: likes.isLiked(comment: comment) ? "heart.fill" : "heart")
                        .font(.caption2)
                        .foregroundColor(likes.isLiked(comment: comment) ? .red : OVK.Palette.textSecondary)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            likes.toggle(comment: comment, ownerID: ownerID, settings: settings)
                        }
                        .onLongPressGesture(minimumDuration: 0.4) {
                            if likes.count(comment: comment) > 0 { showLikers = true }
                        }

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
            // Явная кнопка «⋯» вместо contextMenu на всю строку: долгий тап по строке
            // конфликтовал с долгим тапом по «сердечку» — оба открывались разом (см. PostRow).
            if canDelete, onDelete != nil {
                Menu {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(OVK.Palette.textSecondary)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .sheet(isPresented: $showLikers) {
            LikersView(commentOwnerID: ownerID, commentID: comment.commentID)
        }
        .confirmationDialog("Удалить комментарий?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { onDelete?() }
        }
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
