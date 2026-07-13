import SwiftUI
import MobileVLCKit

/// Обёртка над VLCMediaPlayer: публикует состояние для SwiftUI-контролов и управляет плеером.
final class VLCPlayerController: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    let player = VLCMediaPlayer()

    @Published var isPlaying = false
    @Published var isBuffering = true
    @Published var currentSeconds: Double = 0

    private var totalSeconds: Double = 1

    override init() {
        super.init()
        player.delegate = self
    }

    var duration: Double { totalSeconds }

    func attach(url: URL, duration: Int, to drawable: UIView) {
        guard player.media == nil else { return } // уже запущен
        totalSeconds = max(Double(duration), 1)
        player.media = VLCMedia(url: url)
        player.drawable = drawable
        player.play()
    }

    func togglePlayPause() {
        player.isPlaying ? player.pause() : player.play()
    }

    func seek(toSeconds seconds: Double) {
        player.position = Float(min(max(seconds / totalSeconds, 0), 1))
        currentSeconds = seconds
    }

    func stop() {
        player.stop()
    }

    // MARK: - VLCMediaPlayerDelegate (VLC зовёт с своего потока → уходим на main)

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        DispatchQueue.main.async {
            self.isPlaying = self.player.isPlaying
            let state = self.player.state
            // Буферизация — только пока плеер ещё не играет (иначе колёсико висит поверх видео).
            self.isBuffering = (state == .opening || state == .buffering) && !self.player.isPlaying
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        DispatchQueue.main.async {
            self.currentSeconds = (self.player.time.value?.doubleValue ?? 0) / 1000.0
            // Время идёт — значит кадры пошли, буферизация закончилась.
            if self.isBuffering { self.isBuffering = false }
        }
    }
}

/// UIKit-поверхность, в которую VLC рисует картинку.
struct VLCVideoSurface: UIViewRepresentable {
    let url: URL
    let duration: Int
    @ObservedObject var controller: VLCPlayerController

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        controller.attach(url: url, duration: duration, to: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
