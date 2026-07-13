import SwiftUI
import AVFoundation

/// Отдельная сессия для Range-запросов аудио: параллельные соединения, без кэша.
private let videoRangeSession: URLSession = {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.httpMaximumConnectionsPerHost = 12
    cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
    cfg.timeoutIntervalForRequest = 30
    return URLSession(configuration: cfg)
}()

/// Кэш подготовленных видео (скачанный mp4 + перекодированный в AAC звук) —
/// повторный просмотр открывается мгновенно и офлайн.
enum NativeVideoCache {
    static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("video_prep", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Готовит нативное видео OpenVK к воспроизведению БЕЗ VLC:
/// 1) если звук дорожки системе по зубам — просто стримим AVPlayer-ом;
/// 2) иначе (MP3-в-MP4): скачиваем файл → извлекаем MP3-дорожку (MP4AudioExtractor) →
///    аппаратно перекодируем в AAC (AVAssetExportSession) → склеиваем видео+звук
///    в AVMutableComposition → обычный AVPlayerItem.
@MainActor
final class NativeVideoPreparer: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working(String)
        case ready
        case failed(String)
    }
    @Published var phase: Phase = .idle
    private(set) var playerItem: AVPlayerItem?
    /// HLS-стример: resourceLoader держит делегата слабо — обязаны удерживать сами.
    private(set) var hlsStreamer: HLSStreamer?

    private struct PrepareError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// `streamURL` — максимальное качество (для прямого стриминга, когда звук исправен),
    /// `pipelineURL` — умеренное качество (для полной загрузки в конвейере переупаковки).
    func prepare(streamURL: URL, pipelineURL: URL) async {
        phase = .working("Проверка формата…")
        do {
            // Быстрый путь: если звук не требует переупаковки (или его нет) — стримим напрямую.
            // ВАЖНО: isDecodable здесь ВРЁТ — для MP3-дорожки внутри MP4 он отвечает true
            // (MP3 система декодировать умеет), но из MP4-контейнера её не достаёт.
            // Поэтому смотрим на КОДЕК дорожки.
            let remote = AVURLAsset(url: streamURL)
            let tracks = try await remote.load(.tracks)
            let audioTracks = tracks.filter { $0.mediaType == .audio }
            var needsRepack = false
            for track in audioTracks {
                if (try? await track.load(.isDecodable)) != true {
                    needsRepack = true
                }
                let descriptions = (try? await track.load(.formatDescriptions)) ?? []
                for desc in descriptions {
                    let subtype = CMFormatDescriptionGetMediaSubType(desc)
                    Self.log("аудиодорожка: кодек \(Self.fourCC(subtype))")
                    // MP3-семейство: kAudioFormatMPEGLayer3 ('.mp3') и MS-вариант ('ms U').
                    if subtype == kAudioFormatMPEGLayer3 || subtype == 0x6D73_0055 {
                        needsRepack = true
                    }
                }
            }
            // Быстрый путь — только когда AVFoundation ВИДИТ звук и он исправен.
            // «0 аудиодорожек» — подозреваемый: MP3-дорожку из MP4 AVFoundation
            // вообще не показывает в tracks (проверено на файлах OpenVK) —
            // скачиваем и смотрим контейнер собственным парсером.
            if !audioTracks.isEmpty && !needsRepack {
                Self.log("быстрый путь: прямой стриминг (звук исправен)")
                playerItem = AVPlayerItem(asset: remote)
                phase = .ready
                return
            }
            Self.log(audioTracks.isEmpty
                     ? "AVFoundation не видит аудиодорожек — проверяем контейнер сами"
                     : "нужна переупаковка звука (MP3)")

            // Основной путь — виртуальный HLS: качаем только moov, дальше плеер
            // тянет 5-секундные сегменты, которые мы на лету ремуксим в TS.
            // Мгновенный старт, перемотка, и MP3-звук играется штатно.
            do {
                try await hlsPrepare(streamURL: streamURL)
                return
            } catch is CancellationError {
                return
            } catch {
                hlsStreamer = nil
                Self.log("HLS-подготовка не удалась: \(error.localizedDescription) — фолбэк на полную загрузку")
            }

            // Запасной путь: полная загрузка файла + локальная сборка (кэшируется по URL).
            let key = Self.cacheKey(pipelineURL.absoluteString)
            let dir = NativeVideoCache.directory
            let localMP4 = dir.appendingPathComponent("\(key).mp4")
            let localM4A = dir.appendingPathComponent("\(key).m4a")
            let fm = FileManager.default

            if !fm.fileExists(atPath: localMP4.path) {
                phase = .working("Загрузка видео…")
                try await downloadWithProgress(from: pipelineURL, to: localMP4)
                let size = (try? fm.attributesOfItem(atPath: localMP4.path)[.size] as? Int) ?? 0
                Self.log("скачано: \(size / 1024 / 1024) МБ")
            }
            try Task.checkCancellation()

            if !fm.fileExists(atPath: localM4A.path) {
                phase = .working("Подготовка звука…")
                let mp3Data: Data
                do {
                    mp3Data = try await Self.extractAudio(localMP4)
                } catch MP4AudioExtractor.ExtractError.noAudioTrack {
                    // В контейнере правда нет звука — играем скачанный файл как есть.
                    Self.log("аудиодорожки в контейнере нет — немое видео, играем локально")
                    playerItem = AVPlayerItem(asset: AVURLAsset(url: localMP4))
                    phase = .ready
                    return
                } catch let error as MP4AudioExtractor.ExtractError {
                    // Битый файл в кэше (например, закэшированный отлуп сервера) —
                    // удаляем, чтобы при следующей попытке скачался заново.
                    Self.log("файл в кэше повреждён (\(error.localizedDescription)) — удаляем")
                    try? fm.removeItem(at: localMP4)
                    throw error
                }
                Self.log("извлечено аудио: \(mp3Data.count) байт")
                let mp3URL = dir.appendingPathComponent("\(key).mp3")
                try mp3Data.write(to: mp3URL)
                defer { try? fm.removeItem(at: mp3URL) }
                try Task.checkCancellation()
                try await Self.transcode(mp3: mp3URL, to: localM4A)
                Self.log("транскод в AAC завершён")
            }
            try Task.checkCancellation()

            phase = .working("Сборка…")
            playerItem = try await Self.compose(video: localMP4, audio: localM4A)
            phase = .ready
        } catch is CancellationError {
            // экран закрыли во время подготовки — тихо выходим
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Виртуальный HLS: индексируем файл по moov (один Range-запрос),
    /// AVPlayer получает плейлист с ЛОКАЛЬНОГО HTTP-сервера (127.0.0.1),
    /// сегменты ремуксятся на лету. (Resource loader для сегментов не годится —
    /// CoreMedia -12881: медиаданные HLS обязаны приходить по HTTP.)
    private func hlsPrepare(streamURL: URL) async throws {
        phase = .working("Подготовка стрима…")
        let total = try await Self.probeFileSize(streamURL)
        try Task.checkCancellation()

        let moovData = try await Self.locateMoov(streamURL, fileSize: total)
        Self.log("moov получен: \(moovData.count / 1024) КБ (файл \(total / 1024 / 1024) МБ)")
        try Task.checkCancellation()

        let mp4Index = try MP4Index.build(moovData: moovData)
        guard mp4Index.video.samples.allSatisfy({ $0.offset >= 0 && $0.offset + $0.size <= total }),
              mp4Index.audio?.samples.allSatisfy({ $0.offset >= 0 && $0.offset + $0.size <= total }) ?? true
        else { throw PrepareError(message: "Индекс сэмплов вне файла") }

        let streamer = HLSStreamer(index: mp4Index, remoteURL: streamURL)
        hlsStreamer = streamer
        let playlistURL = try await streamer.start()
        try Task.checkCancellation()
        playerItem = AVPlayerItem(asset: AVURLAsset(url: playlistURL))
        phase = .ready
        Self.log("HLS-стрим готов: \(streamer.segmentCount) сегментов, \(String(format: "%.1f", mp4Index.duration)) с, \(playlistURL.absoluteString)")
    }

    /// Размер файла + проверка поддержки Range (по Content-Range ответа 206).
    nonisolated private static func probeFileSize(_ url: URL) async throws -> Int {
        var req = URLRequest(url: url)
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, resp) = try await videoRangeSession.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 206,
              let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
              let totalPart = contentRange.split(separator: "/").last,
              let total = Int(totalPart), total > 0
        else { throw PrepareError(message: "Сервер не поддерживает Range-запросы") }
        return total
    }

    /// Один Range-запрос: строго 206 и ровно запрошенное число байтов.
    nonisolated private static func fetchRange(_ url: URL, _ range: Range<Int>) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        let (data, resp) = try await videoRangeSession.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 206, data.count == range.count else {
            throw PrepareError(message: "Range-запрос не удался")
        }
        return data
    }

    /// Находит и скачивает moov, не тянув файл целиком: голова 256 КБ (faststart),
    /// иначе шагаем по верхним боксам точечными запросами заголовков.
    nonisolated private static func locateMoov(_ url: URL, fileSize: Int) async throws -> Data {
        let head = try await fetchRange(url, 0..<min(256 * 1024, fileSize))

        func be32(_ bytes: [UInt8], _ o: Int) -> Int {
            Int(bytes[o]) << 24 | Int(bytes[o + 1]) << 16 | Int(bytes[o + 2]) << 8 | Int(bytes[o + 3])
        }

        var cursor = 0
        while cursor + 8 <= fileSize {
            let header: [UInt8]
            if cursor + 16 <= head.count {
                header = [UInt8](head.subdata(in: cursor..<cursor + 16))
            } else {
                header = [UInt8](try await fetchRange(url, cursor..<min(cursor + 16, fileSize)))
            }
            guard header.count >= 8 else { throw PrepareError(message: "Обрезанный заголовок бокса") }
            var size = be32(header, 0)
            let type = String(bytes: header[4..<8], encoding: .ascii) ?? ""
            if size == 1 {
                guard header.count >= 16 else { throw PrepareError(message: "Обрезанный 64-битный бокс") }
                size = (be32(header, 8) << 32) | be32(header, 12)
            } else if size == 0 {
                size = fileSize - cursor
            }
            guard size >= 8 else { throw PrepareError(message: "Повреждённый бокс") }
            if type == "moov" {
                let end = min(cursor + size, fileSize)
                if end <= head.count {
                    return head.subdata(in: cursor..<end)
                }
                return try await fetchRange(url, cursor..<end)
            }
            cursor += size
        }
        throw PrepareError(message: "moov не найден")
    }

    /// Потокобезопасный держатель задачи загрузки — для отмены из Sendable-замыкания.
    private final class DownloadBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDownloadTask?
        private var cancelled = false

        func set(_ newTask: URLSessionDownloadTask) {
            lock.lock(); defer { lock.unlock() }
            task = newTask
            if cancelled { newTask.cancel() }
        }

        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            task?.cancel()
        }
    }

    /// Загрузка с прогрессом в процентах (phase обновляется на лету) и отменой.
    private func downloadWithProgress(from url: URL, to destination: URL) async throws {
        let box = DownloadBox()
        var observation: NSKeyValueObservation?
        defer { observation?.invalidate() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let task = URLSession.shared.downloadTask(with: url) { tmp, response, error in
                    if let error {
                        cont.resume(throwing: error)
                        return
                    }
                    // Проверяем СТАТУС и размер: сервер мог вернуть отлуп (429/403)
                    // с пустым телом — без проверки он кэшировался как «видео».
                    guard let tmp,
                          let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                          let size = try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int,
                          size > 1024
                    else {
                        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                        cont.resume(throwing: PrepareError(message: "Загрузка не удалась (HTTP \(code))"))
                        return
                    }
                    do {
                        try? FileManager.default.removeItem(at: destination)
                        try FileManager.default.moveItem(at: tmp, to: destination)
                        cont.resume()
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
                observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                    let percent = Int(progress.fractionCompleted * 100)
                    Task { @MainActor [weak self] in
                        self?.phase = .working("Загрузка видео… \(percent)%")
                    }
                }
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    // MARK: - Этапы (nonisolated async → выполняются вне главного потока)

    nonisolated private static func extractAudio(_ url: URL) async throws -> Data {
        try MP4AudioExtractor.extractAudio(from: url)
    }

    nonisolated private static func transcode(mp3: URL, to output: URL) async throws {
        // AVAsset умеет читать «голый» .mp3 — экспортируем в m4a (AAC, аппаратно).
        let asset = AVURLAsset(url: mp3)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw PrepareError(message: "Не удалось создать конвертер звука")
        }
        try? FileManager.default.removeItem(at: output)
        export.outputURL = output
        export.outputFileType = .m4a
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }
        guard export.status == .completed else {
            let reason = export.error?.localizedDescription ?? "неизвестная ошибка"
            throw PrepareError(message: "Звук не сконвертировался: \(reason)")
        }
    }

    nonisolated private static func compose(video: URL, audio: URL) async throws -> AVPlayerItem {
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)
        let composition = AVMutableComposition()

        guard let videoTrack = try await videoAsset.load(.tracks).first(where: { $0.mediaType == .video }),
              let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw PrepareError(message: "Видеодорожка не найдена") }

        let videoDuration = try await videoAsset.load(.duration)
        try compVideo.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: videoTrack, at: .zero)
        compVideo.preferredTransform = try await videoTrack.load(.preferredTransform)

        // Звук обязан быть — ради него весь конвейер; молчаливое видео = ошибка.
        guard let audioTrack = try await audioAsset.load(.tracks).first(where: { $0.mediaType == .audio }),
              let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw PrepareError(message: "Звук потерялся при конвертации") }
        let audioDuration = try await audioAsset.load(.duration)
        let duration = CMTimeMinimum(videoDuration, audioDuration)
        try compAudio.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: audioTrack, at: .zero)
        log("композиция собрана: видео \(videoDuration.seconds)с, аудио \(audioDuration.seconds)с")
        return AVPlayerItem(asset: composition)
    }

    /// Лог конвейера в консоль Xcode (фильтр: [Video]).
    nonisolated private static func log(_ message: String) {
        print("[Video] \(message)")
    }

    /// FourCC-код в строку ("mp4a", ".mp3"…) для логов.
    nonisolated private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(code)
    }

    /// Стабильный ключ кэша из URL (простая свёртка, коллизии не критичны).
    private static func cacheKey(_ string: String) -> String {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }
}

/// Обвязка AVPlayer для наших контролов (та же роль, что VLCPlayerController у VLC).
@MainActor
final class NativeVideoController: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published var currentSeconds: Double = 0
    @Published var duration: Double = 0

    let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var failObserver: NSObjectProtocol?

    func attach(_ item: AVPlayerItem, fallbackDuration: Int) {
        duration = Double(max(fallbackDuration, 1))
        // ПРИМЕЧАНИЕ: automaticallyWaitsToMinimizeStalling=false давал «первый кадр и
        // фриз» (плеер стартовал на пустом буфере и не возобновлялся) — оставляем дефолт.
        player.replaceCurrentItem(with: item)

        // Диагностика: если AVPlayer отвергнет HLS-актив, ошибка появится здесь.
        statusObserver = item.observe(\.status, options: [.new]) { item, _ in
            switch item.status {
            case .failed:
                print("[Video] AVPlayerItem.status=failed: \(item.error?.localizedDescription ?? "?") | \((item.error as NSError?)?.debugDescription ?? "")")
                // Детальный журнал HLS-ошибок — тут видно, что именно не понравилось плееру.
                for event in item.errorLog()?.events ?? [] {
                    print("[Video] errorLog: код \(event.errorStatusCode) домен \(event.errorDomain) uri=\(event.uri ?? "-") комментарий=\(event.errorComment ?? "-")")
                }
            case .readyToPlay:
                print("[Video] AVPlayerItem.status=readyToPlay")
            default:
                break
            }
        }
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { note in
            let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            print("[Video] FailedToPlayToEnd: \(err?.localizedDescription ?? "?")")
        }

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            self.currentSeconds = time.seconds
            if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 {
                self.duration = d
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in self?.isPlaying = false }
        }
        player.play()
        isPlaying = true
    }

    func togglePlayPause() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func seek(toSeconds seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        currentSeconds = seconds
    }

    func stop() {
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let failObserver {
            NotificationCenter.default.removeObserver(failObserver)
            self.failObserver = nil
        }
        statusObserver?.invalidate()
        statusObserver = nil
        player.replaceCurrentItem(with: nil)
        isPlaying = false
    }
}

/// Слой AVPlayerLayer для SwiftUI.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: LayerView, context: Context) {
        uiView.playerLayer.player = player
    }
}

/// Полноэкранное нативное видео без VLC: та же обвязка, что у VLC-экрана
/// (тап — контролы, слайдер, поворот), но на системном AVPlayer.
struct NativeVideoScreen: View {
    let video: Video
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var audioPlayer: AudioPlayer

    @StateObject private var preparer = NativeVideoPreparer()
    @StateObject private var controller = NativeVideoController()
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
            if audioPlayer.isPlaying { audioPlayer.pause() } // музыка и видео не смешиваются
            AppDelegate.setVideoOrientation(true)
        }
        .onDisappear {
            controller.stop()
            AppDelegate.setVideoOrientation(false)
        }
        .task {
            guard let url = video.streamURL else { return }
            await preparer.prepare(streamURL: url, pipelineURL: video.pipelineURL ?? url)
            if case .ready = preparer.phase, let item = preparer.playerItem {
                controller.attach(item, fallbackDuration: video.duration)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch preparer.phase {
        case .ready:
            ZStack {
                PlayerLayerView(player: controller.player)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation { showControls.toggle() } }
                if showControls {
                    controlsOverlay
                }
            }
        case .failed(let message):
            VStack(spacing: 8) {
                Text("Не удалось подготовить видео")
                    .foregroundColor(.white)
                Text(message)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                Text("Можно включить видеодвижок VLC в настройках")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            VStack(spacing: 14) {
                ProgressView().tint(.white).scaleEffect(1.4)
                if case .working(let label) = preparer.phase {
                    Text(label)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var controlsOverlay: some View {
        ZStack {
            Button { controller.togglePlayPause() } label: {
                Image(systemName: controller.isPlaying ? "pause.circle.fill" : "play.circle.fill")
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
                            get: { isScrubbing ? scrubValue : controller.currentSeconds },
                            set: { scrubValue = $0 }
                        ),
                        in: 0...max(controller.duration, 1),
                        onEditingChanged: { editing in
                            if editing {
                                isScrubbing = true
                            } else {
                                controller.seek(toSeconds: scrubValue)
                                isScrubbing = false
                            }
                        }
                    )
                    .tint(.white)
                    Text(Self.time(controller.duration))
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

    private var displaySeconds: Double { isScrubbing ? scrubValue : controller.currentSeconds }

    private static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
