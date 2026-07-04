import SwiftUI

/// Мини-плеер: полоса снизу с текущим треком и контролами. Показывается глобально над таб-баром.
struct MiniPlayerView: View {
    @EnvironmentObject private var player: AudioPlayer
    var onExpand: () -> Void = {}

    var body: some View {
        if let track = player.current {
            VStack(spacing: 0) {
                MiniProgressBar(clock: player.clock)

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).font(.subheadline).lineLimit(1)
                        Text(track.artist)
                            .font(.caption)
                            .foregroundColor(OVK.Palette.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { onExpand() }

                    Button { player.previous() } label: { Image(systemName: "backward.fill") }
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    }
                    Button { player.next() } label: { Image(systemName: "forward.fill") }
                }
                .foregroundColor(OVK.Palette.primary)
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .background(.regularMaterial)
        }
    }
}

/// Полоса прогресса — наблюдает только за часами, поэтому тики не трогают остальной UI.
private struct MiniProgressBar: View {
    @ObservedObject var clock: PlaybackClock
    var body: some View {
        ProgressView(value: progress)
            .progressViewStyle(.linear)
            .tint(OVK.Palette.primary)
    }
    private var progress: Double {
        guard clock.duration > 0 else { return 0 }
        return min(max(clock.currentTime / clock.duration, 0), 1)
    }
}
