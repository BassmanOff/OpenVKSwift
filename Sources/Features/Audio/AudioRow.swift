import SwiftUI

/// Строка трека в стиле старого VK: обложка + название/исполнитель + длительность + одно действие.
/// Используется в списке музыки, в поиске и на экране альбома.
struct AudioRow: View {
    let track: Audio
    /// Показывать ли в контекстном меню действие «Добавить к себе / Убрать» (в «Загрузках» не нужно).
    var showAddToLibrary: Bool = true
    /// Показывать ли состояние «уже в моей музыке» (полезно в поиске).
    var showAddedBadge: Bool = false
    /// Встроенное контекст-меню SwiftUI. ВЫКЛЮЧАЙТЕ внутри ячейки List с другим контентом
    /// (посты в ленте): там SwiftUI вешает long-press на ВСЮ ячейку, а не на строку трека.
    var showsContextMenu: Bool = true

    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var downloads: AudioDownloadManager
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: LibraryManager
    @State private var extraCover: URL?   // обложка из iTunes, если в OpenVK её нет
    @State private var showUnavailableAlert = false

    private var isCurrent: Bool { player.current?.id == track.id }
    private var coverURL: URL? { track.coverURL ?? extraCover }
    /// Скачанный трек можно играть офлайн, даже если онлайн-url протух.
    private var canPlay: Bool { player.isAvailable(track) }

    private var subtitle: String {
        if canPlay { return track.artist }
        if track.isProcessing { return "Обрабатывается — нажмите, чтобы повторить" }
        return "Снято по копирайту"
    }

    private var titleColor: Color {
        canPlay ? OVK.Palette.textPrimary : OVK.Palette.textSecondary
    }

    /// Одинаковая плитка 44 pt есть у каждого трека; заполненный символ появляется
    /// только у выбранного трека, а недоступность обозначается контурным символом.
    @ViewBuilder
    private var leading: some View {
        AlbumCover(url: coverURL, size: 44, corner: OVK.Metrics.compactCornerRadius)
            .overlay {
                if isCurrent && canPlay {
                    ZStack {
                        if coverURL != nil { Color.black.opacity(0.25) }
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .foregroundColor(coverURL == nil ? OVK.Palette.primary : .white)
                    }
                    .cornerRadius(OVK.Metrics.compactCornerRadius)
                } else if !canPlay {
                    Image(systemName: track.isProcessing ? "arrow.clockwise.circle" : "nosign")
                        .foregroundColor(OVK.Palette.textSecondary)
                }
            }
    }

    var body: some View {
        if showsContextMenu {
            core.contextMenu { menuItems }
        } else {
            core
        }
    }

    private var core: some View {
        HStack(spacing: 12) {
            leading

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .foregroundColor(titleColor)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundColor(canPlay ? OVK.Palette.link : OVK.Palette.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(track.durationText)
                .font(.caption)
                .foregroundColor(OVK.Palette.textSecondary)

            trailingAccessory
        }
        .padding(.vertical, 4)
        .opacity(canPlay ? 1 : 0.6)
        .task {
            // Обложки нет в OpenVK — пробуем подобрать в iTunes (только для играбельных).
            if track.coverURL == nil && canPlay && extraCover == nil {
                extraCover = await CoverArtService.shared.cover(artist: track.artist, title: track.title)
            }
        }
        .onReceive(player.$unavailableTrack) { selected in
            showUnavailableAlert = selected?.id == track.id
        }
        .unavailableAudioAlert(isPresented: $showUnavailableAlert) {
            player.clearUnavailableTrack()
        }
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        if showAddedBadge && library.isAdded(track) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundColor(OVK.Palette.primary)
        } else if track.isPlayable || downloads.isDownloaded(track) {
            downloadButton
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        if canPlay {
            Button {
                player.playNext(track)
            } label: {
                Label("Играть следующим", systemImage: "play.circle")
            }
            Button {
                player.enqueue(track)
            } label: {
                Label("В конец очереди", systemImage: "list.bullet")
            }
        }
        // Переход к альбому трека — только если он к нему привязан (MainTabView откроет «Музыку»,
        // AudioListView — сам альбом; см. player.pendingAlbum).
        if let album = track.album {
            Button {
                player.pendingAlbum = album
            } label: {
                Label("Перейти к альбому", systemImage: "music.note.list")
            }
        }
        if showAddToLibrary {
            if library.isAdded(track) {
                Button(role: .destructive) {
                    library.toggleTrack(track, settings: settings)
                } label: {
                    Label("Убрать из моей музыки", systemImage: "minus.circle")
                }
            } else {
                Button {
                    library.toggleTrack(track, settings: settings)
                } label: {
                    Label("Добавить к себе", systemImage: "plus.circle")
                }
            }
        }
    }

    @ViewBuilder
    private var downloadButton: some View {
        if downloads.isDownloaded(track) {
            Button {
                downloads.remove(track)
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(OVK.Palette.primary)
            }
            .buttonStyle(.plain)
        } else if downloads.inProgress.contains(track.key) {
            ProgressView()
        } else {
            Button {
                downloads.download(track)
            } label: {
                Image(systemName: "arrow.down.circle").foregroundColor(OVK.Palette.textSecondary)
            }
            .buttonStyle(.plain)
        }
    }
}
