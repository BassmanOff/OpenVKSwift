import SwiftUI

/// Строка трека в стиле старого VK: ▶ + название/исполнитель + длительность + кнопка скачать.
/// Используется в списке музыки, в поиске и на экране альбома.
struct AudioRow: View {
    let track: Audio
    /// Показывать ли в контекстном меню действие «Добавить к себе / Убрать» (в «Загрузках» не нужно).
    var showAddToLibrary: Bool = true
    /// Показывать ли зелёную галочку «уже в моей музыке» (полезно в поиске).
    var showAddedBadge: Bool = false
    /// Встроенное контекст-меню SwiftUI. ВЫКЛЮЧАЙТЕ внутри ячейки List с другим контентом
    /// (посты в ленте): там SwiftUI вешает long-press на ВСЮ ячейку, а не на строку трека.
    var showsContextMenu: Bool = true

    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var downloads: AudioDownloadManager
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: LibraryManager
    @State private var extraCover: URL?   // обложка из iTunes, если в OpenVK её нет

    private var isCurrent: Bool { player.current?.id == track.id }
    private var coverURL: URL? { track.coverURL ?? extraCover }
    /// Скачанный трек можно играть офлайн, даже если онлайн-url протух.
    private var canPlay: Bool { track.isPlayable || downloads.isDownloaded(track) }

    private var leadingIcon: String {
        if canPlay { return (isCurrent && player.isPlaying) ? "pause.circle.fill" : "play.circle.fill" }
        if track.isProcessing { return "arrow.clockwise.circle" }
        return "nosign" // withdrawn
    }

    private var subtitle: String {
        if canPlay { return track.artist }
        if track.isProcessing { return "Обрабатывается — нажмите, чтобы повторить" }
        return "Снято по копирайту"
    }

    private var titleColor: Color {
        guard canPlay else { return OVK.Palette.textSecondary }
        return isCurrent ? OVK.Palette.primary : OVK.Palette.textPrimary
    }

    /// Слева — обложка альбома (если есть) с иконкой play/pause поверх, иначе обычная иконка.
    @ViewBuilder
    private var leading: some View {
        if let cover = coverURL {
            CachedImage(url: cover) {
                OVK.Palette.background
            }
            .frame(width: 44, height: 44)
            .clipped()
            .cornerRadius(6)
            .overlay {
                if canPlay {
                    ZStack {
                        Color.black.opacity(0.25)
                        Image(systemName: (isCurrent && player.isPlaying) ? "pause.fill" : "play.fill")
                            .foregroundColor(.white)
                            .shadow(radius: 2)
                    }
                    .cornerRadius(6)
                }
            }
        } else {
            Image(systemName: leadingIcon)
                .font(.title)
                .foregroundColor(canPlay ? OVK.Palette.primary : OVK.Palette.textSecondary.opacity(0.5))
                .frame(width: 44, height: 44)
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
                    .foregroundColor(OVK.Palette.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            if showAddedBadge && library.isAdded(track) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            }

            Text(track.durationText)
                .font(.caption)
                .foregroundColor(OVK.Palette.textSecondary)

            if track.isPlayable || downloads.isDownloaded(track) { downloadButton }
        }
        .padding(.vertical, 4)
        .opacity(canPlay ? 1 : 0.6)
        .task {
            // Обложки нет в OpenVK — пробуем подобрать в iTunes (только для играбельных).
            if track.coverURL == nil && canPlay && extraCover == nil {
                extraCover = await CoverArtService.shared.cover(artist: track.artist, title: track.title)
            }
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
                Image(systemName: "arrow.down.circle.fill").foregroundColor(.green)
            }
            .buttonStyle(.plain)
        } else if downloads.inProgress.contains(track.key) {
            ProgressView()
        } else {
            Button {
                Task { await downloads.download(track) }
            } label: {
                Image(systemName: "arrow.down.circle").foregroundColor(OVK.Palette.textSecondary)
            }
            .buttonStyle(.plain)
        }
    }
}
