import SwiftUI

/// Мини-плеер: полоса снизу с текущим треком и контролами. Показывается глобально над таб-баром.
struct MiniPlayerView: View {
    @EnvironmentObject private var player: AudioPlayer
    @State private var extraCover: URL?
    @State private var showStopConfirmation = false
    var onExpand: () -> Void = {}

    var body: some View {
        if let track = player.current {
            VStack(spacing: 0) {
                MiniProgressBar(clock: player.clock)

                HStack(spacing: 0) {
                    Button(action: onExpand) {
                        HStack(spacing: 10) {
                            artwork(track)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title)
                                    .font(.subheadline)
                                    .foregroundColor(OVK.Palette.textPrimary)
                                    .lineLimit(1)
                                Text(track.artist)
                                    .font(.caption)
                                    .foregroundColor(OVK.Palette.primary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 4)
                        }
                        .frame(maxWidth: .infinity, minHeight: OVK.Metrics.miniPlayerHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(track.title), \(track.artist)")
                    .accessibilityHint("Открывает плеер")

                    Button {
                        showStopConfirmation = true
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: OVK.Metrics.miniPlayerHeight,
                                   height: OVK.Metrics.miniPlayerHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Дополнительные действия")

                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: OVK.Metrics.miniPlayerHeight,
                                   height: OVK.Metrics.miniPlayerHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(player.isPlaying ? "Пауза" : "Воспроизвести")

                    Button { player.next() } label: {
                        Image(systemName: "forward.fill")
                            .frame(width: OVK.Metrics.miniPlayerHeight,
                                   height: OVK.Metrics.miniPlayerHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Следующий трек")
                }
                .foregroundColor(OVK.Palette.primary)
                .padding(.leading, 8)
                .padding(.trailing, 2)
                .frame(height: OVK.Metrics.miniPlayerHeight)
            }
            .task(id: track.id) {
                extraCover = nil
                guard track.coverURL == nil else { return }
                let cover = await CoverArtService.shared.cover(artist: track.artist, title: track.title)
                guard !Task.isCancelled else { return }
                extraCover = cover
            }
            .confirmationDialog("Дополнительные действия", isPresented: $showStopConfirmation) {
                Button("Остановить и закрыть", role: .destructive) { player.stop() }
                Button("Отмена", role: .cancel) {}
            }
        }
    }

    private func artwork(_ track: Audio) -> some View {
        AlbumCover(
            url: track.coverURL ?? extraCover,
            size: 40,
            corner: OVK.Metrics.compactCornerRadius
        )
        .accessibilityHidden(true)
    }
}

/// Полоса прогресса — наблюдает только за часами, поэтому тики не трогают остальной UI.
private struct MiniProgressBar: View {
    @ObservedObject var clock: PlaybackClock
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                OVK.Palette.separator
                OVK.Palette.primary
                    .frame(width: proxy.size.width * progress)
            }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
    private var progress: Double {
        guard clock.duration > 0 else { return 0 }
        return min(max(clock.currentTime / clock.duration, 0), 1)
    }
}
