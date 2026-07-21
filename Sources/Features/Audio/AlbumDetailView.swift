import SwiftUI

/// Квадратная обложка альбома с заглушкой-нотой, пока картинка грузится/отсутствует.
struct AlbumCover: View {
    let url: URL?
    var size: CGFloat
    var corner: CGFloat = OVK.Metrics.compactCornerRadius
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        CachedImage(url: url, maxPixelSize: size * displayScale) {
            ZStack {
                OVK.Palette.background
                Image(systemName: "music.note.list")
                    .font(.system(size: size * 0.4))
                    .foregroundColor(OVK.Palette.primary.opacity(0.5))
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .cornerRadius(corner)
    }
}

/// Строка альбома в списке поиска.
struct AlbumRow: View {
    let album: Album
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: LibraryManager

    var body: some View {
        HStack(spacing: 12) {
            AlbumCover(url: album.coverImageURL, size: 50)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .foregroundColor(OVK.Palette.textPrimary)
                    .lineLimit(1)
                Text(album.sizeText)
                    .font(.footnote)
                    .foregroundColor(OVK.Palette.textSecondary)
            }
            Spacer()
            if library.isBookmarked(album) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundColor(OVK.Palette.primary)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if library.isBookmarked(album) {
                Button(role: .destructive) {
                    library.toggleAlbum(album, settings: settings)
                } label: {
                    Label("Убрать из плейлистов", systemImage: "minus.circle")
                }
            } else {
                Button {
                    library.toggleAlbum(album, settings: settings)
                } label: {
                    Label("Добавить альбом к себе", systemImage: "plus.circle")
                }
            }
        }
    }
}

/// Экран альбома: шапка с обложкой + список треков.
struct AlbumDetailView: View {
    let album: Album
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var library: LibraryManager
    @StateObject private var model = AudioViewModel()

    var body: some View {
        List {
            albumHeader

            if model.isLoading && model.tracks.isEmpty {
                OVKListStateView(message: "Загрузка треков…", isLoading: true)
            } else if model.tracks.isEmpty {
                OVKListStateView(message: "Нет треков")
            } else {
                ForEach(model.tracks) { track in
                    AudioRow(track: track)
                        .ovkPlainListRow()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard track.isPlayable else { return }
                            if player.current?.id == track.id {
                                player.togglePlayPause()
                            } else {
                                player.play(track, in: model.tracks.filter { $0.isPlayable }, source: album.title)
                            }
                        }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    library.toggleAlbum(album, settings: settings)
                } label: {
                    Image(systemName: library.isBookmarked(album) ? "checkmark.circle.fill" : "plus.circle")
                }
            }
        }
        .toast($library.toast)
        .task { await model.load(album: album, settings: settings) }
        .task { await library.hydrateBookmarks(settings: settings) }
    }

    private var albumHeader: some View {
        HStack(spacing: 16) {
            AlbumCover(url: album.coverImageURL, size: 96)
            VStack(alignment: .leading, spacing: 6) {
                Text(album.title)
                    .font(.headline)
                    .foregroundColor(OVK.Palette.textPrimary)
                // Кол-во берём из реально загруженных треков: album.size недостоверен
                // при открытии по ссылке (getPlaylistById не отдаёт size → 0).
                // ponytail: потолок — 100 (count в audio.get); playlist >100 покажет "100".
                Text(Album.sizeText(model.tracks.isEmpty ? album.size : model.tracks.count))
                    .font(.subheadline)
                    .foregroundColor(OVK.Palette.textSecondary)
                if !album.description.isEmpty {
                    Text(album.description)
                        .font(.footnote)
                        .foregroundColor(OVK.Palette.textSecondary)
                        .lineLimit(3)
                }
            }
            Spacer()
        }
        .padding(OVK.Metrics.contentInset)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(OVK.Palette.card.overlay(OVKHairline(), alignment: .bottom))
    }
}
