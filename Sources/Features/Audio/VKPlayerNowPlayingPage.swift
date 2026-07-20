import SwiftUI

struct VKPlayerNowPlayingPage: View {
    /// Плеер теперь оверлей, а не модалка — \.dismiss не закроет его. Просим закрытие у контейнера.
    let clock: PlaybackClock
    var onRequestClose: () -> Void
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var downloads: AudioDownloadManager
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: LibraryManager
    @State private var extraCover: URL?

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            if let track = player.current {
                // Порядок эпохи (см. docs/vk-player-spec.md): обложка → скраббер СРАЗУ под ней →
                // название + артист → транспорт → громкость.
                artwork(track)
                VKPlayerScrubber(clock: clock) { player.seek(to: $0) }
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
                Spacer(minLength: 18)
                metadata(track)
                transport(track)
                // Референс: тихий динамик слева, громкий справа, серые.
                HStack(spacing: 12) {
                    Image(systemName: "speaker.fill")
                        .font(.system(size: 11))
                    VolumeSlider()
                        .frame(height: 28)
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 13))
                }
                .foregroundColor(OVK.Palette.textSecondary)
                .padding(.horizontal, 34)
                .padding(.top, 18)
            } else {
                emptyState
            }
            Spacer(minLength: 20)
        }
        .task(id: player.current?.id) {
            extraCover = nil
            if let track = player.current, track.coverURL == nil {
                extraCover = await CoverArtService.shared.cover(artist: track.artist, title: track.title)
            }
        }
    }

    @ViewBuilder
    private func menuButton(_ track: Audio) -> some View {
        Menu {
            Button { player.playNext(track) } label: {
                Label("Играть следующим", systemImage: "play.circle")
            }
            Button { player.enqueue(track) } label: {
                Label("В конец очереди", systemImage: "list.bullet")
            }
            if let album = track.album {
                Button {
                    player.pendingAlbum = album
                    onRequestClose()
                } label: {
                    Label("Перейти к альбому", systemImage: "music.note.list")
                }
            }
            if library.isAdded(track) {
                Button(role: .destructive) {
                    library.toggleTrack(track, settings: settings)
                } label: {
                    Label("Убрать из моей музыки", systemImage: "minus.circle")
                }
            }
        } label: {
            Image(systemName: "ellipsis").font(.title2.weight(.bold))
        }
    }

    @ViewBuilder
    private func libraryDownloadButton(_ track: Audio) -> some View {
        if !library.isAdded(track) {
            Button { library.toggleTrack(track, settings: settings) } label: {
                Image(systemName: "plus.circle")
            }
        } else if downloads.isDownloaded(track) {
            Button { downloads.remove(track) } label: {
                // Скачано: залитая стрелка вниз в фирменном синем (зелёная галка не вписывалась).
                Image(systemName: "arrow.down.circle.fill")
            }
        } else if downloads.inProgress.contains(track.key) {
            Button { downloads.cancelDownload(track) } label: {
                // Circle без frame растягивается на всё доступное место и расталкивает
                // транспортный ряд — держим размер соседних иконок (.title2 ≈ 22pt).
                ZStack {
                    Circle().stroke(OVK.Palette.background, lineWidth: 3)
                    DownloadProgressRing(progress: downloads.progress, key: track.key)
                    Image(systemName: "xmark").font(.caption2.weight(.bold))
                }
                .frame(width: 22, height: 22)
            }
        } else if track.isPlayable {
            Button { downloads.download(track) } label: {
                Image(systemName: "arrow.down.circle")
            }
        } else {
            Image(systemName: "nosign")
                .foregroundColor(OVK.Palette.textSecondary)
        }
    }

    private func artwork(_ track: Audio) -> some View {
        CachedImage(url: track.coverURL ?? extraCover) {
            ZStack {
                OVK.Palette.background
                Image(systemName: "music.note")
                    .font(.system(size: 80))
                    .foregroundColor(OVK.Palette.primary.opacity(0.5))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .cornerRadius(14)
        .clipped()
        .padding(.horizontal, 18)
    }

    private func metadata(_ track: Audio) -> some View {
        VStack(spacing: 5) {
            Text(track.title).font(.title3.weight(.semibold)).lineLimit(1)
            // Имя артиста — синяя «ссылка», как в референсе (на всех страницах плеера).
            Text(track.artist).font(.subheadline).foregroundColor(OVK.Palette.primary).lineLimit(1)
        }
        .foregroundColor(OVK.Palette.textPrimary)
        .padding(.horizontal, 24)
    }

    /// Один ряд: + / скачивание — prev — play/pause — next — ⋯. Раньше +/⋯ жили в отдельном
    /// topBar над обложкой — по скриншоту и решению из Q5 они должны быть в этом же ряду.
    /// Равные Spacer'ы между всеми пятью — иначе +/⋯ жались к краям, а транспорт кучковался
    /// по центру (визуально «слишком далеко»).
    private func transport(_ track: Audio) -> some View {
        HStack(spacing: 0) {
            libraryDownloadButton(track).font(.title2)
            Spacer()
            Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title2) }
            Spacer()
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
            }
            Spacer()
            Button { player.next() } label: { Image(systemName: "forward.fill").font(.title2) }
            Spacer()
            menuButton(track)
        }
        .foregroundColor(OVK.Palette.primary)
        .padding(.horizontal, 28)
        .padding(.top, 18)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 58))
                .foregroundColor(OVK.Palette.textSecondary)
            Text("Ничего не воспроизводится")
                .foregroundColor(OVK.Palette.textSecondary)
        }
    }
}

private struct DownloadProgressRing: View {
    @ObservedObject var progress: AudioDownloadProgress
    let key: String

    var body: some View {
        Circle()
            .trim(from: 0, to: progress.values[key] ?? 0)
            .stroke(OVK.Palette.primary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .rotationEffect(.degrees(-90))
    }
}

private struct VKPlayerScrubber: View {
    @ObservedObject var clock: PlaybackClock
    let onSeek: (Double) -> Void
    @State private var isScrubbing = false
    @State private var value = 0.0

    var body: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(
                get: { isScrubbing ? value : clock.currentTime },
                set: { value = $0 }
            ), in: 0...max(clock.duration, 1), onEditingChanged: { editing in
                if editing { isScrubbing = true }
                else { onSeek(value); isScrubbing = false }
            })
            .tint(OVK.Palette.primary)
            HStack {
                Text(time(isScrubbing ? value : clock.currentTime))
                Spacer()
                Text("-" + time(max(clock.duration - (isScrubbing ? value : clock.currentTime), 0)))
            }
            .font(.caption)
            .foregroundColor(OVK.Palette.textSecondary)
        }
    }

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}
