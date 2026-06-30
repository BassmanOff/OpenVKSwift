import SwiftUI

/// Одна запись стены: автор + дата + устройство, текст, фото, аудио, репост, счётчики.
struct PostRow: View {
    let post: Post
    let authors: [Int: WallViewModel.Author]
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var likes: LikesManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            authorHeader(id: post.fromID, date: post.date, platform: post.platform)

            if !post.text.isEmpty {
                Text(post.text)
                    .font(.subheadline)
                    .foregroundColor(OVK.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            photosView(post.photos)
            audiosView(post.audios)

            if let repost = post.repost {
                repostBlock(repost)
            }

            footer
        }
        .padding()
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { likes.like(post, settings: settings) }
    }

    // MARK: - Автор

    private func authorHeader(id: Int, date: Int, platform: User.OnlinePlatform) -> some View {
        let author = authors[id]
        return HStack(spacing: 10) {
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
            Spacer()
        }
    }

    // MARK: - Вложения

    @ViewBuilder
    private func photosView(_ photos: [Photo]) -> some View {
        if photos.count == 1, let photo = photos.first {
            // Одно фото — показываем целиком в его пропорциях (без кадрирования).
            CachedImage(url: photo.bestURL) { OVK.Palette.background }
                .aspectRatio(photo.aspectRatio ?? 1.4, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipped()
                .cornerRadius(6)
        } else if !photos.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)], spacing: 2) {
                ForEach(photos) { photo in
                    CachedImage(url: photo.thumbURL) { OVK.Palette.background }
                        .aspectRatio(1, contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .frame(height: 120)
                        .clipped()
                        .cornerRadius(4)
                }
            }
        }
    }

    @ViewBuilder
    private func audiosView(_ audios: [Audio]) -> some View {
        ForEach(audios) { track in
            AudioRow(track: track)
                .contentShape(Rectangle())
                .onTapGesture { playTrack(track, in: audios) }
        }
    }

    private func playTrack(_ track: Audio, in list: [Audio]) {
        guard track.isPlayable else { return }
        if player.current?.id == track.id {
            player.togglePlayPause()
        } else {
            player.play(track, in: list.filter { $0.isPlayable })
        }
    }

    // MARK: - Репост

    private func repostBlock(_ repost: Post.Repost) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(OVK.Palette.separator)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
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
                if !repost.text.isEmpty {
                    Text(repost.text)
                        .font(.subheadline)
                        .foregroundColor(OVK.Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                photosView(repost.photos)
                audiosView(repost.audios)
            }
            .padding(.leading, 10)
        }
    }

    // MARK: - Счётчики

    private var footer: some View {
        HStack(spacing: 20) {
            Button {
                likes.toggle(post, settings: settings)
            } label: {
                Label("\(likes.count(post))", systemImage: likes.isLiked(post) ? "heart.fill" : "heart")
                    .foregroundColor(likes.isLiked(post) ? .red : OVK.Palette.textSecondary)
            }
            .buttonStyle(.plain)

            Label("\(post.commentsCount)", systemImage: "bubble.right")
                .foregroundColor(OVK.Palette.textSecondary)
            Label("\(post.repostsCount)", systemImage: "arrowshape.turn.up.right")
                .foregroundColor(OVK.Palette.textSecondary)
            Spacer()
        }
        .font(.caption)
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
