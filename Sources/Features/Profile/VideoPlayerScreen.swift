import SwiftUI
import WebKit

/// Экран воспроизведения видео: нативные mp4 (в т.ч. MP3-в-MP4) играет VLC со звуком;
/// внешние (YouTube и т.п.) — во встроенном веб-вью.
struct VideoPlayerScreen: View {
    let video: Video
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var audioPlayer: AudioPlayer

    @StateObject private var vlc = VLCPlayerController()
    @State private var showControls = true
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var landscape = false
    @State private var retryID = 0
    @State private var resumeAudioOnDismiss = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            content

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(10)
                    .background(Color.black.opacity(0.4))
                    .clipShape(Circle())
            }
            .padding()
        }
        .onAppear {
            resumeAudioOnDismiss = audioPlayer.isPlaying
            if resumeAudioOnDismiss { audioPlayer.pause() } // не мешаем звук музыки и видео
            landscape = video.startsLandscape
            AppDelegate.setVideoOrientation(true) // разрешить ландшафт на время видео
            if landscape { AppDelegate.forceRotate(to: .landscapeRight) }
        }
        .onDisappear {
            vlc.stop()
            AppDelegate.setVideoOrientation(false) // вернуть портрет
            if resumeAudioOnDismiss { audioPlayer.resume() }
        }
        .task(id: showControls && vlc.isPlaying && !isScrubbing && vlc.errorMessage == nil) {
            guard showControls && vlc.isPlaying && !isScrubbing && vlc.errorMessage == nil else { return }
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { showControls = false }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let stream = video.playbackURL {
            ZStack {
                VLCVideoSurface(url: stream, duration: video.duration, controller: vlc)
                    .id(retryID)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation { showControls = !showControls } }

                if let error = vlc.errorMessage {
                    VStack(spacing: 12) {
                        Text(error).foregroundColor(.white)
                        Button("Повторить") {
                            vlc.stop()
                            retryID += 1
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(OVK.Palette.primary)
                    }
                } else if vlc.isBuffering {
                    ProgressView().tint(.white).scaleEffect(1.4)
                }

                if showControls && vlc.errorMessage == nil {
                    controlsOverlay
                }
            }
        } else if let embed = video.embedURL {
            WebView(url: embed)
        } else {
            Text("Видео недоступно для воспроизведения")
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var controlsOverlay: some View {
        ZStack {
            VStack {
                Text(video.title.isEmpty ? "Видео" : video.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 64)
                    .padding(.top, 20)
                Spacer()
            }

            HStack(spacing: 28) {
                skipButton(seconds: -10, symbol: "gobackward.10")
                Button { vlc.togglePlayPause() } label: {
                    Image(systemName: vlc.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 64))
                        .foregroundColor(.white.opacity(0.9))
                        .shadow(radius: 4)
                }
                skipButton(seconds: 10, symbol: "goforward.10")
            }

            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Text(Self.time(displaySeconds))
                        .font(.caption).foregroundColor(.white).monospacedDigit()
                    Slider(
                        value: Binding(
                            get: { isScrubbing ? scrubValue : vlc.currentSeconds },
                            set: { scrubValue = $0 }
                        ),
                        in: 0...max(vlc.duration, 1),
                        onEditingChanged: { editing in
                            if editing {
                                isScrubbing = true
                            } else {
                                vlc.seek(toSeconds: scrubValue)
                                isScrubbing = false
                                showControls = true
                            }
                        }
                    )
                    .tint(.white)
                    Text(Self.time(vlc.duration))
                        .font(.caption).foregroundColor(.white).monospacedDigit()

                    Button {
                        landscape.toggle()
                        AppDelegate.forceRotate(to: landscape ? .landscapeRight : .portrait)
                    } label: {
                        Image(systemName: landscape
                              ? "arrow.down.right.and.arrow.up.left"
                              : "arrow.up.left.and.arrow.down.right")
                            .foregroundColor(.white)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.4))
            }
        }
    }

    private var displaySeconds: Double { isScrubbing ? scrubValue : vlc.currentSeconds }

    private func skipButton(seconds: Double, symbol: String) -> some View {
        Button { vlc.seek(by: seconds) } label: {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(.white)
                .frame(width: OVK.Metrics.minimumTapSize, height: OVK.Metrics.minimumTapSize)
        }
    }

    private static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Простой WKWebView для внешних видео (YouTube и т.п.).
struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.isScrollEnabled = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
