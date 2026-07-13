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
            if audioPlayer.isPlaying { audioPlayer.pause() } // не мешаем звук музыки и видео
            AppDelegate.setVideoOrientation(true) // разрешить ландшафт на время видео
        }
        .onDisappear {
            vlc.stop()
            AppDelegate.setVideoOrientation(false) // вернуть портрет
        }
    }

    @ViewBuilder
    private var content: some View {
        if let stream = video.streamURL {
            ZStack {
                VLCVideoSurface(url: stream, duration: video.duration, controller: vlc)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation { showControls.toggle() } }

                if vlc.isBuffering {
                    ProgressView().tint(.white).scaleEffect(1.4)
                }

                if showControls {
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
            Button { vlc.togglePlayPause() } label: {
                Image(systemName: vlc.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
                    .foregroundColor(.white.opacity(0.9))
                    .shadow(radius: 4)
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
