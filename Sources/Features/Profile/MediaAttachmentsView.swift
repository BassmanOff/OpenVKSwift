import SwiftUI

/// Аудио- и видео-вложения (для постов и комментариев): аудио играется, видео открывается в плеере.
struct MediaAttachmentsView: View {
    let audios: [Audio]
    let videos: [Video]
    @EnvironmentObject private var player: AudioPlayer
    @State private var selectedVideo: Video?

    @ViewBuilder
    var body: some View {
        if audios.isEmpty && videos.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(audios) { track in
                    AudioRow(track: track)
                        .contentShape(Rectangle())
                        .onTapGesture { playTrack(track) }
                }
                ForEach(videos) { video in
                    videoThumb(video)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedVideo = video }
                }
            }
            .fullScreenCover(item: $selectedVideo) { video in
                VideoPlayerScreen(video: video)
            }
        }
    }

    private func videoThumb(_ video: Video) -> some View {
        ZStack {
            CachedImage(url: video.thumbURL) {
                ZStack { OVK.Palette.background; Image(systemName: "play.rectangle").foregroundColor(OVK.Palette.textSecondary) }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .clipped()
            .cornerRadius(6)

            Image(systemName: "play.circle.fill")
                .font(.system(size: 44))
                .foregroundColor(.white.opacity(0.9))
                .shadow(radius: 3)

            VStack {
                Spacer()
                HStack {
                    Text(video.title.isEmpty ? "Видео" : video.title)
                        .font(.caption).foregroundColor(.white).lineLimit(1)
                    Spacer()
                    Text(video.durationText).font(.caption2).foregroundColor(.white)
                }
                .padding(6)
                .background(Color.black.opacity(0.45))
            }
            .cornerRadius(6)
        }
    }

    private func playTrack(_ track: Audio) {
        guard track.isPlayable else { return }
        if player.current?.id == track.id {
            player.togglePlayPause()
        } else {
            player.play(track, in: audios.filter { $0.isPlayable })
        }
    }
}
