import SwiftUI

/// Одна запись стены: автор + дата + устройство, текст, фото, аудио, репост, счётчики.
struct PostRow: View {
    let post: Post
    let authors: [Int: WallViewModel.Author]
    var onDelete: ((Post) -> Void)? = nil
    /// Пост изменился (wall.edit) — родитель обычно перечитывает его через refreshPost().
    var onEdited: ((Post) -> Void)? = nil
    /// Отключает интерактивность кнопки комментариев (используется при встраивании PostRow в CommentsView).
    var commentTapEnabled: Bool = true
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var likes: LikesManager
    @EnvironmentObject private var photoHero: PhotoHeroCoordinator
    @Environment(\.openURL) private var openURL
    @State private var showCommentsSheet = false
    @State private var showLikers = false
    @State private var confirmDelete = false
    @State private var showEditSheet = false
    @State private var showRepostSheet = false
    @State private var localRepostsCount: Int?
    @State private var toastMessage: String?
    /// Оригинал репоста, дозагруженный через wall.getById (в copy_history API кладёт только фото).
    @State private var fullRepost: Post?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            authorHeader(id: post.fromID, date: post.date, platform: post.platform)

            if !post.text.isEmpty {
                Text(linkifiedText(post.text))
                    .font(.subheadline)
                    .foregroundColor(OVK.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            photosView(post.photos)
            MediaAttachmentsView(audios: post.audios, videos: post.videos)

            if let poll = post.poll {
                // .id — форс пересоздания при обновлении поста (pull-to-refresh), иначе
                // @State внутри PollCardView не подхватит новые голоса/результаты с сервера.
                PollCardView(poll: poll)
                    .id("\(poll.id)-\(poll.votes)-\(poll.hasVoted)")
            }

            if let repost = post.repost {
                repostBlock(repost)
            }

            footer
        }
        .padding()
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { likes.like(post, settings: settings) }
        .sheet(isPresented: $showCommentsSheet) {
            CommentsView(ownerID: post.ownerID, postID: post.postID, fallbackIDs: [], post: post)
        }
        .sheet(isPresented: $showLikers) {
            LikersView(ownerID: post.ownerID, postID: post.postID)
        }
        .sheet(isPresented: $showEditSheet) {
            NewPostView(ownerID: post.ownerID, groupName: authors[post.ownerID]?.name, editingPost: post) {
                onEdited?(post)
            }
        }
        .confirmationDialog("Удалить запись?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { onDelete?(post) }
        }
        .sheet(isPresented: $showRepostSheet) {
            RepostSheet(post: post) { message, bumpCount in
                toastMessage = message
                if bumpCount { localRepostsCount = (localRepostsCount ?? post.repostsCount) + 1 }
            }
        }
        .toast($toastMessage)
        .task { await loadFullRepost() }
    }

    /// Тап по автору: профиль пользователя или страница сообщества (через маршрутизатор ссылок).
    private func openAuthor(_ id: Int) {
        guard id != 0 else { return }
        let path = id > 0 ? "id\(id)" : "club\(-id)"
        if let url = URL(string: "https://openvk.org/\(path)") { openURL(url) }
    }

    /// Если у репоста нет видео/аудио — возможно, их срезал API (copy_history содержит
    /// только фото). Добираем оригинал одним запросом wall.getById (с кэшем в ObjectResolver).
    private func loadFullRepost() async {
        guard let repost = post.repost, fullRepost == nil,
              repost.videos.isEmpty, repost.audios.isEmpty,
              repost.postID != 0 else { return }
        fullRepost = await ObjectResolver.shared.post(
            ownerID: repost.ownerID, postID: repost.postID, extended: false, settings: settings
        )?.post
    }

    // MARK: - Автор

    private func authorHeader(id: Int, date: Int, platform: User.OnlinePlatform) -> some View {
        let author = authors[id]
        return HStack(spacing: 10) {
            // Тап по аватару/имени открывает профиль или сообщество.
            Button { openAuthor(id) } label: {
                HStack(spacing: 10) {
                    CachedImage(url: author?.avatar) {
                        ZStack { OVK.Palette.background; Image(systemName: "person.crop.square").foregroundColor(OVK.Palette.textSecondary) }
                    }
                    .frame(width: 40, height: 40)
                    .clipped()
                    .cornerRadius(4)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(author?.name ?? "Пользователь")
                            .font(.subheadline).fontWeight(.semibold)
                            .foregroundColor(OVK.Palette.link)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Text(Self.dateText(date))
                                .font(.caption)
                                .foregroundColor(OVK.Palette.textSecondary)
                            if platform.hasIcon {
                                OnlinePlatformIcon(platform: platform, size: 10)
                            }
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            // Меню «⋯» (изменить/удалить) — только когда есть хоть одно из прав.
            // Явная кнопка вместо долгих тапов/contextMenu: те конфликтовали то с
            // «сердечком», то со скроллом List (см. историю правок).
            if (post.canEdit && onEdited != nil) || (post.canDelete && onDelete != nil) {
                Menu {
                    if post.canEdit && onEdited != nil {
                        Button { showEditSheet = true } label: {
                            Label("Изменить", systemImage: "pencil")
                        }
                    }
                    if post.canDelete && onDelete != nil {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(OVK.Palette.textSecondary)
                        .padding(8) // зона нажатия побольше самой иконки
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Вложения

    @ViewBuilder
    private func photosView(_ photos: [Photo]) -> some View {
        if photos.count == 1, let photo = photos.first {
            // Одно фото — показываем целиком в его пропорциях (без кадрирования).
            // .clipped() НЕ ограничивает хит-тест: невидимый «хвост» фото перехватывал бы
            // тапы соседних элементов. Тап ловит оверлей photoHeroSource, картинке хит не нужен.
            CachedImage(url: photo.bestURL) {
                // Placeholder с правильным aspectRatio, чтобы не прыгал layout при загрузке
                OVK.Palette.background
                    .aspectRatio(photo.aspectRatio ?? 1.4, contentMode: .fit)
            }
                .aspectRatio(photo.aspectRatio ?? 1.4, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipped()
                .cornerRadius(6)
                .allowsHitTesting(false)
                .photoHeroSource(photos: photos, index: 0, post: post, coordinator: photoHero)
        } else if !photos.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)], spacing: 2) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { i, photo in
                    // Размер ячейки задаёт Color.clear, фото — оверлеем с обрезкой.
                    // Так картинка не «распирает» ячейку и не наезжает на соседей.
                    // .clipped() НЕ ограничивает хит-тест: невидимый «хвост» .fill-картинки
                    // ложился бы поверх соседних ячеек и «съедал» их тапы.
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 120)
                        .overlay(
                            CachedImage(url: photo.thumbURL, contentMode: .fill) { OVK.Palette.background }
                                .allowsHitTesting(false)
                        )
                        .clipped()
                        .cornerRadius(4)
                        .photoHeroSource(photos: photos, index: i, post: post, coordinator: photoHero)
                }
            }
        }
    }

    // MARK: - Репост

    private func repostBlock(_ repost: Post.Repost) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(OVK.Palette.separator)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                Button { openAuthor(repost.fromID) } label: {
                    HStack(spacing: 8) {
                        CachedImage(url: authors[repost.fromID]?.avatar) {
                            ZStack { OVK.Palette.background; Image(systemName: "person.crop.square").foregroundColor(OVK.Palette.textSecondary) }
                        }
                        .frame(width: 28, height: 28)
                        .clipped()
                        .cornerRadius(3)
                        Text(authors[repost.fromID]?.name ?? "Запись")
                            .font(.caption).fontWeight(.semibold)
                            .foregroundColor(OVK.Palette.link)
                            .lineLimit(1)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                if !repost.text.isEmpty {
                    Text(linkifiedText(repost.text))
                        .font(.subheadline)
                        .foregroundColor(OVK.Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Вложения: приоритет — дозагруженный оригинал (в copy_history видео/аудио нет).
                photosView(fullRepost?.photos ?? repost.photos)
                MediaAttachmentsView(
                    audios: fullRepost?.audios ?? repost.audios,
                    videos: fullRepost?.videos ?? repost.videos
                )
            }
            .padding(.leading, 10)
        }
    }

    // MARK: - Счётчики

    private var footer: some View {
        HStack(spacing: 20) {
            // Тап — лайк, долгий тап — список оценивших. Раздельные .onTapGesture
            // и .onLongPressGesture SwiftUI арбитрирует сам (быстрый тап засчитывает тап;
            // удержание >0.4с — только long-press, тап при этом НЕ срабатывает).
            // Не Button + .simultaneousGesture (оба срабатывали разом: лайк И список)
            // и не LongPress.exclusively(before: Tap) (тап-лайк проглатывался).
            Label("\(likes.count(post))", systemImage: likes.isLiked(post) ? "heart.fill" : "heart")
                .foregroundColor(likes.isLiked(post) ? .red : OVK.Palette.textSecondary)
                .contentShape(Rectangle())
                .onTapGesture {
                    likes.toggle(post, settings: settings)
                }
                .onLongPressGesture(minimumDuration: 0.4) {
                    if likes.count(post) > 0 { showLikers = true }
                }

            if commentTapEnabled {
                Button { showCommentsSheet = true } label: {
                    Label("\(post.commentsCount)", systemImage: "bubble.right")
                        .foregroundColor(OVK.Palette.textSecondary)
                }
                .buttonStyle(.plain)
            } else {
                Label("\(post.commentsCount)", systemImage: "bubble.right")
                    .foregroundColor(OVK.Palette.textSecondary)
            }
            Button { showRepostSheet = true } label: {
                Label("\(localRepostsCount ?? post.repostsCount)", systemImage: "arrowshape.turn.up.right")
                    .foregroundColor(OVK.Palette.textSecondary)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .font(.system(size: 15)) // как в PhotoHero (pointSize 16 иконка / 15pt текст)
        .padding(.top, 2)
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
