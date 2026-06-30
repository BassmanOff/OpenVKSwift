import SwiftUI

/// Полноэкранный плеер в стилистике старого VK: крупная обложка-заглушка,
/// перемотка, большие контролы. Открывается тапом по мини-плееру.
struct FullScreenPlayerView: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var downloads: AudioDownloadManager
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: LibraryManager
    @Environment(\.dismiss) private var dismiss

    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var showQueue = false

    var body: some View {
        VStack(spacing: 0) {
            handle

            Spacer(minLength: 0)

            artwork
                .padding(.horizontal, 32)

            Spacer(minLength: 0)

            if let track = player.current {
                VStack(spacing: 6) {
                    Text(track.title)
                        .font(.title3).fontWeight(.semibold)
                        .foregroundColor(OVK.Palette.textPrimary)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.subheadline)
                        .foregroundColor(OVK.Palette.textSecondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 24)
            }

            scrubber
                .padding(.horizontal, 24)
                .padding(.top, 24)

            controls
                .padding(.top, 16)

            Spacer(minLength: 0)

            downloadControl
                .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OVK.Palette.card.ignoresSafeArea())
        .toast($library.toast)
        .sheet(isPresented: $showQueue) {
            QueueView()
        }
    }

    // MARK: - Компоненты

    private var handle: some View {
        ZStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(OVK.Palette.textSecondary)
                    .contentShape(Rectangle())
            }

            HStack {
                // Слева — добавить трек в мою музыку.
                if let track = player.current {
                    Button {
                        library.toggleTrack(track, settings: settings)
                    } label: {
                        Image(systemName: library.isAdded(track) ? "checkmark.circle.fill" : "plus.circle")
                            .font(.title3)
                            .foregroundColor(OVK.Palette.primary)
                    }
                    .padding(.leading, 20)
                }

                Spacer()

                // Справа — очередь воспроизведения.
                Button {
                    showQueue = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.title3)
                        .foregroundColor(OVK.Palette.primary)
                }
                .padding(.trailing, 20)
            }
        }
        .padding(.vertical, 16)
    }

    private var artwork: some View {
        CachedImage(url: player.current?.coverURL) {
            ZStack {
                OVK.Palette.background
                Image(systemName: "music.note")
                    .font(.system(size: 80))
                    .foregroundColor(OVK.Palette.primary.opacity(0.5))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 320)
        .cornerRadius(16)
        .clipped()
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubValue : player.currentTime },
                    set: { scrubValue = $0 }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    if editing {
                        isScrubbing = true
                    } else {
                        player.seek(to: scrubValue)
                        isScrubbing = false
                    }
                }
            )
            .tint(OVK.Palette.primary)

            HStack {
                Text(Self.time(isScrubbing ? scrubValue : player.currentTime))
                Spacer()
                Text("-" + Self.time(max(player.duration - (isScrubbing ? scrubValue : player.currentTime), 0)))
            }
            .font(.caption)
            .foregroundColor(OVK.Palette.textSecondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 28) {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .font(.title3)
                    .foregroundColor(player.isShuffled ? OVK.Palette.primary : OVK.Palette.textSecondary)
            }
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.title)
            }
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
            }
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.title)
            }
            Button { player.cycleRepeatMode() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.title3)
                    .foregroundColor(player.repeatMode == .off ? OVK.Palette.textSecondary : OVK.Palette.primary)
            }
        }
        .foregroundColor(OVK.Palette.primary)
    }

    @ViewBuilder
    private var downloadControl: some View {
        if let track = player.current {
            if downloads.isDownloaded(track) {
                Label("Скачано", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundColor(.green)
            } else if downloads.inProgress.contains(track.key) {
                ProgressView()
            } else if track.isPlayable {
                Button {
                    Task { await downloads.download(track) }
                } label: {
                    Label("Скачать", systemImage: "arrow.down.circle")
                        .font(.footnote)
                        .foregroundColor(OVK.Palette.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
