import Foundation
import AVFoundation

/// Держит приложение живым в фоне ТИХИМ зацикленным аудио (фоновый режим `audio`),
/// чтобы LongPoll не засыпал и уведомления о сообщениях приходили МГНОВЕННО даже при
/// закрытом экране. Настоящего APNs-пуша нет (нужен сервер) — это единственный путь
/// «всегда онлайн» без сервера. Процесс при этом виден в диспетчере (CocoaTop).
///
/// Цена — расход батареи ~1–3%/час, пока приложение в фоне и не играет музыка
/// (когда музыка играет, она сама держит процесс — тихое аудио тогда не нужно).
/// Ограничение iOS: принудительный СВАЙП приложения из свитчера убивает процесс —
/// до повторного открытия уведомлений не будет (это не лечится без сервера/пуша).
@MainActor
final class KeepAliveService: ObservableObject {
    @Published private(set) var isRunning = false
    private var player: AVAudioPlayer?

    /// Запускает тихое аудио (idempotent). Вызывать при уходе в фон, когда включён
    /// фоновый режим и НЕ играет музыка.
    func start() {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        // mixWithOthers — не прерываем и не приглушаем чужую музыку/подкасты.
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)

        if player == nil {
            player = try? AVAudioPlayer(data: Self.silentWAV)
            player?.numberOfLoops = -1        // бесконечный цикл
            player?.prepareToPlay()
        }
        // Контент — нули (тишина), поэтому громкость не важна и ничего не слышно.
        player?.play()
        isRunning = player?.isPlaying ?? false
    }

    func stop() {
        guard isRunning else { return }
        player?.stop()
        player?.currentTime = 0
        isRunning = false
        // Возвращаем звук другим приложениям; музыкальный плеер при старте
        // сам заново настроит и активирует сессию.
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Минимальный валидный PCM-WAV из тишины (моно, 8 кГц, 16-бит, ~0.5 с) — строим в коде,
    /// чтобы не тащить бинарный ресурс.
    private static let silentWAV: Data = {
        let sampleRate = 8000, channels = 1, bits = 16
        let samples = sampleRate / 2                       // 0.5 c
        let dataSize = samples * channels * bits / 8
        let byteRate = sampleRate * channels * bits / 8
        let blockAlign = channels * bits / 8

        var d = Data()
        func str(_ s: String) { d.append(contentsOf: s.utf8) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }

        str("RIFF"); u32(UInt32(36 + dataSize)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(UInt16(channels))
        u32(UInt32(sampleRate)); u32(UInt32(byteRate)); u16(UInt16(blockAlign)); u16(UInt16(bits))
        str("data"); u32(UInt32(dataSize))
        d.append(Data(count: dataSize))                    // тишина = нули
        return d
    }()
}
