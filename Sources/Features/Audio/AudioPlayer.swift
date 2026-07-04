import Foundation
import AVFoundation
import MediaPlayer
import Combine
import UIKit

/// Часто меняющееся время воспроизведения вынесено в отдельный объект, чтобы тики (2/сек)
/// НЕ перерисовывали все вьюхи, наблюдающие AudioPlayer (списки постов/аудио и т.п.).
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
}

/// Аудиоплеер: очередь, фоновое воспроизведение, контролы на локскрине,
/// предпочтение локального (скачанного) файла перед стримом.
@MainActor
final class AudioPlayer: ObservableObject {
    enum RepeatMode { case off, all, one }

    @Published private(set) var queue: [Audio] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var isPlaying = false
    @Published private(set) var isShuffled = false
    @Published private(set) var repeatMode: RepeatMode = .off
    /// Позиция/длительность — отдельный наблюдаемый объект (см. PlaybackClock).
    let clock = PlaybackClock()

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private weak var downloads: AudioDownloadManager?
    private weak var settings: AppSettings?
    private var currentArtwork: MPMediaItemArtwork?
    /// Скачивать ли трек при воспроизведении (синхронизируется из AppSettings.autoDownloadMyTracks).
    var downloadOnPlay = true
    /// Разрешена ли автозагрузка для текущей очереди (ставится в play(...:autoDownload:)).
    private var autoDownloadCurrentQueue = false
    /// Исходный порядок очереди до перемешивания (для возврата при выключении shuffle).
    private var unshuffledQueue: [Audio]?

    var current: Audio? {
        guard let i = currentIndex, queue.indices.contains(i) else { return nil }
        return queue[i]
    }

    init() {
        configureSession()
        setupRemoteCommands()
    }

    func attach(downloads: AudioDownloadManager) {
        self.downloads = downloads
    }

    func attach(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - Управление

    /// `autoDownload` — разрешить автозагрузку при прослушивании для ЭТОЙ очереди.
    /// true только из вкладки «Онлайн» (Мои треки); из альбомов, поиска, ленты — false,
    /// чтобы случайное прослушивание не забивало «Загрузки».
    func play(_ audio: Audio, in list: [Audio], autoDownload: Bool = false) {
        queue = list
        autoDownloadCurrentQueue = autoDownload
        currentIndex = list.firstIndex(where: { $0.id == audio.id }) ?? 0
        if isShuffled { applyShuffleKeepingCurrent() }
        startCurrent()
    }

    /// Вкл/выкл перемешивание. Текущий трек остаётся играть, остальные перемешиваются/восстанавливаются.
    func toggleShuffle() {
        isShuffled.toggle()
        guard !queue.isEmpty else { return }
        if isShuffled {
            applyShuffleKeepingCurrent()
        } else {
            let curID = current?.id
            if let unshuffledQueue {
                queue = unshuffledQueue
                self.unshuffledQueue = nil
            }
            if let curID, let idx = queue.firstIndex(where: { $0.id == curID }) {
                currentIndex = idx
            }
        }
    }

    /// Циклически меняет режим повтора: выкл → вся очередь → один трек → выкл.
    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    private func applyShuffleKeepingCurrent() {
        guard let cur = current else { return }
        unshuffledQueue = queue
        var rest = queue
        rest.removeAll { $0.id == cur.id }
        rest.shuffle()
        queue = [cur] + rest
        currentIndex = 0
    }

    /// Вставляет трек сразу после текущего (или начинает воспроизведение, если ничего не играет).
    func playNext(_ audio: Audio) {
        guard let curID = current?.id else { play(audio, in: [audio]); return }
        if audio.id == curID { return }
        var q = queue
        q.removeAll { $0.id == audio.id }          // убираем возможный дубль
        guard let curIdx = q.firstIndex(where: { $0.id == curID }) else {
            play(audio, in: [audio]); return
        }
        q.insert(audio, at: curIdx + 1)
        queue = q
        currentIndex = curIdx
    }

    /// Добавляет трек в конец очереди (или начинает воспроизведение, если ничего не играет).
    func enqueue(_ audio: Audio) {
        guard current != nil else { play(audio, in: [audio]); return }
        guard !queue.contains(where: { $0.id == audio.id }) else { return }
        queue.append(audio)
    }

    /// Перейти к треку очереди по индексу (тап в экране очереди).
    func play(at index: Int) {
        guard queue.indices.contains(index) else { return }
        currentIndex = index
        startCurrent()
    }

    /// Удалить треки из очереди. Если удалён текущий — переходим к соседнему или останавливаемся.
    func removeFromQueue(at offsets: IndexSet) {
        let curID = current?.id
        var q = queue
        q.remove(atOffsets: offsets)
        queue = q
        if let curID, let idx = q.firstIndex(where: { $0.id == curID }) {
            currentIndex = idx
        } else if q.isEmpty {
            stop()
        } else {
            currentIndex = min(offsets.min() ?? 0, q.count - 1)
            startCurrent()
        }
    }

    /// Переставить треки в очереди, сохранив текущий играющий.
    func moveInQueue(from source: IndexSet, to destination: Int) {
        let curID = current?.id
        var q = queue
        q.move(fromOffsets: source, toOffset: destination)
        queue = q
        if let curID, let idx = q.firstIndex(where: { $0.id == curID }) {
            currentIndex = idx
        }
    }

    /// Полная остановка и очистка очереди.
    func stop() {
        player?.pause()
        removeObservers()
        player = nil
        isPlaying = false
        clock.currentTime = 0
        clock.duration = 0
        currentIndex = nil
        queue = []
        updateNowPlaying()
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        configureSession()
        player?.play()
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func next() { advance(auto: false) }

    func previous() {
        guard let i = currentIndex else { return }
        if i - 1 >= 0 {
            currentIndex = i - 1
            startCurrent()
        } else if repeatMode == .all {
            currentIndex = queue.count - 1
            startCurrent()
        }
    }

    /// Переход к следующему треку. `auto` = вызвано окончанием трека (учитывает повтор/конец очереди).
    private func advance(auto: Bool) {
        guard let i = currentIndex else { return }
        if i + 1 < queue.count {
            currentIndex = i + 1
            startCurrent()
        } else if repeatMode == .all {
            currentIndex = 0
            startCurrent()
        } else if auto {
            // конец очереди, повтора нет — останавливаем воспроизведение
            isPlaying = false
            updateNowPlaying()
        }
    }

    /// Вызывается по окончании трека: при «повторе одного» переигрываем, иначе идём дальше.
    private func trackDidEnd() {
        if repeatMode == .one {
            seek(to: 0)
            player?.play()
            isPlaying = true
            updateNowPlaying()
        } else {
            advance(auto: true)
        }
    }

    func seek(to time: Double) {
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        clock.currentTime = time
        updateNowPlaying()
    }

    // MARK: - Private

    private func startCurrent() {
        guard let audio = current else { return }
        let local = downloads?.localURL(for: audio)
        let source = local ?? audio.playbackURL
        guard let url = source else { return }

        // Автозагрузка при прослушивании: только для очереди из вкладки «Онлайн»
        // (autoDownloadCurrentQueue), если играем из сети и включено в настройках.
        // Альбомы/поиск/лента такого не делают — не забиваем «Загрузки».
        if downloadOnPlay, autoDownloadCurrentQueue, local == nil, audio.isPlayable {
            Task { await downloads?.download(audio) }
        }

        // Регистрируем прослушивание на сервере (+статус «слушаю») — один раз на старт трека.
        settings?.broadcastListen(ownerID: audio.ownerID, audioID: audio.audioID)

        configureSession() // на случай, если видео (VLC) поменяло аудиосессию
        removeObservers()

        let item = AVPlayerItem(url: url)
        let avPlayer = AVPlayer(playerItem: item)
        player = avPlayer
        addObservers(for: item, player: avPlayer)

        clock.duration = audio.duration > 0 ? Double(audio.duration) : 0
        clock.currentTime = 0
        avPlayer.play()
        isPlaying = true
        loadArtwork(for: audio)
        updateNowPlaying()
    }

    private func addObservers(for item: AVPlayerItem, player avPlayer: AVPlayer) {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            self.clock.currentTime = time.seconds
            if let itemDuration = self.player?.currentItem?.duration.seconds,
               itemDuration.isFinite, itemDuration > 0 {
                self.clock.duration = itemDuration
            }
            self.updateNowPlaying()
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in self?.trackDidEnd() }
        }
    }

    private func removeObservers() {
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        // ВАЖНО: iOS вызывает эти обработчики на ФОНОВОМ потоке. Методы плеера — @MainActor
        // (трогают AVAudioSession.setActive, AVPlayer и @Published-состояние), поэтому каждое
        // действие переносим на главный актор через `Task { @MainActor in }`. Иначе с локскрина
        // кнопки «не работают» (действие выполняется не на том потоке и тихо проваливается).
        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }

        // Отключаем skip/seek-команды, чтобы на локскрине не подменяли кнопки next/prev.
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false

        // Перемотка ползунком на локскрине / в пункте управления.
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = e.positionTime
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let audio = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: audio.title,
            MPMediaItemPropertyArtist: audio.artist,
            MPMediaItemPropertyPlaybackDuration: clock.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: clock.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let currentArtwork {
            info[MPMediaItemPropertyArtwork] = currentArtwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Грузит обложку текущего трека для локскрина (один раз на трек).
    /// Если в OpenVK обложки нет — подбираем из iTunes.
    private func loadArtwork(for audio: Audio) {
        currentArtwork = nil
        Task {
            let url: URL?
            if let cover = audio.coverURL {
                url = cover
            } else {
                url = await CoverArtService.shared.cover(artist: audio.artist, title: audio.title)
            }
            guard let url,
                  let data = try? await URLSession.shared.data(from: url).0,
                  let image = UIImage(data: data),
                  current?.id == audio.id else { return }
            currentArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            updateNowPlaying()
        }
    }
}
