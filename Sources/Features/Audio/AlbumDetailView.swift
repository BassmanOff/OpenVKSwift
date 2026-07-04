import SwiftUI

/// Квадратная обложка альбома с заглушкой-нотой, пока картинка грузится/отсутствует.
struct AlbumCover: View {
    let url: URL?
    var size: CGFloat
    var corner: CGFloat = 6

    var body: some View {
        CachedImage(url: url) {
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
                    .foregroundColor(.green)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(OVK.Palette.textSecondary)
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
            Section {
                HStack(spacing: 16) {
                    AlbumCover(url: album.coverImageURL, size: 96, corner: 10)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(album.title)
                            .font(.headline)
                            .foregroundColor(OVK.Palette.textPrimary)
                        Text(album.sizeText)
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
                .padding(.vertical, 4)
            }

            if model.isLoading && model.tracks.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            } else if model.tracks.isEmpty {
                Text("Нет треков")
                    .foregroundColor(OVK.Palette.textSecondary)
            } else {
                ForEach(model.tracks) { track in
                    AudioRow(track: track)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard track.isPlayable else { return }
                            if player.current?.id == track.id {
                                player.togglePlayPause()
                            } else {
                                player.play(track, in: model.tracks.filter { $0.isPlayable })
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
    }
}
