import Foundation
import Combine

@MainActor
final class AudioDownloadProgress: ObservableObject {
    @Published fileprivate(set) var values: [String: Double] = [:]
}

/// Загрузка треков для офлайн-прослушивания.
/// Файлы лежат в Application Support/Audio, метаданные — в downloads.json.
@MainActor
final class AudioDownloadManager: ObservableObject {
    @Published private(set) var downloaded: [Audio] = []
    @Published private(set) var inProgress: Set<String> = []
    let progress = AudioDownloadProgress()

    private let dir: URL
    private let metaURL: URL
    private let sessionConfiguration: URLSessionConfiguration
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var pendingAudio: [String: Audio] = [:]
    private var queue: [Audio] = []
    private lazy var session = URLSession(
        configuration: sessionConfiguration,
        delegate: Coordinator(manager: self),
        delegateQueue: nil
    )

    init(configuration: URLSessionConfiguration = .default, directory: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = directory ?? base.appendingPathComponent("Audio", isDirectory: true)
        metaURL = dir.appendingPathComponent("downloads.json")
        sessionConfiguration = configuration
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        loadMeta()
    }

    func isDownloaded(_ audio: Audio) -> Bool {
        downloaded.contains { $0.id == audio.id }
    }

    func localURL(for audio: Audio) -> URL? {
        let file = fileURL(for: audio)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    func download(_ audio: Audio) {
        guard audio.playbackURL != nil,
              !isDownloaded(audio),
              pendingAudio[audio.key] == nil else { return }

        pendingAudio[audio.key] = audio
        queue.append(audio)
        startNext()
    }

    /// Последовательный вариант для массовой загрузки в настройках.
    func downloadAndWait(_ audio: Audio) async {
        download(audio)
        while pendingAudio[audio.key] != nil && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func cancelDownload(_ audio: Audio) {
        if let task = tasks[audio.key] {
            task.cancel()
        } else {
            queue.removeAll { $0.key == audio.key }
            pendingAudio.removeValue(forKey: audio.key)
        }
    }

    func remove(_ audio: Audio) {
        try? FileManager.default.removeItem(at: fileURL(for: audio))
        downloaded.removeAll { $0.id == audio.id }
        saveMeta()
    }

    /// Переставить скачанные треки (режим редактирования в «Загрузках").
    func move(from source: IndexSet, to destination: Int) {
        downloaded.move(fromOffsets: source, toOffset: destination)
        saveMeta()
    }

    // MARK: - Callbacks

    private func updateProgress(for key: String, written: Int64, expected: Int64) {
        guard expected > 0 else { return }
        let value = min(max(Double(written) / Double(expected), 0), 1)
        guard value >= 1 || Int(value * 50) != Int((progress.values[key] ?? 0) * 50) else { return }
        progress.values[key] = value
    }

    private func finishDownload(for key: String, temporaryURL: URL) {
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard let audio = pendingAudio[key] else { return }
        let dest = fileURL(for: audio)
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: temporaryURL, to: dest)
            if !isDownloaded(audio) {
                downloaded.insert(audio, at: 0)
                saveMeta()
            }
        } catch {
            // После ошибки UI вернётся к кнопке «Скачать» в didComplete.
        }
    }

    private func completeDownload(for key: String) {
        inProgress.remove(key)
        progress.values.removeValue(forKey: key)
        tasks.removeValue(forKey: key)
        pendingAudio.removeValue(forKey: key)
        startNext()
    }

    // MARK: - Private

    private func startNext() {
        guard tasks.isEmpty, !queue.isEmpty else { return }
        let audio = queue.removeFirst()
        guard let remote = audio.playbackURL else {
            pendingAudio.removeValue(forKey: audio.key)
            startNext()
            return
        }

        let key = audio.key
        inProgress.insert(key)
        progress.values[key] = 0
        let task = session.downloadTask(with: remote)
        task.taskDescription = key
        tasks[key] = task
        task.resume()
    }

    private func fileURL(for audio: Audio) -> URL {
        dir.appendingPathComponent("\(audio.key).mp3")
    }

    private func loadMeta() {
        guard let data = try? Data(contentsOf: metaURL),
              let items = try? JSONDecoder().decode([Audio].self, from: data) else { return }
        downloaded = items.filter { localURL(for: $0) != nil }
    }

    private func saveMeta() {
        if let data = try? JSONEncoder().encode(downloaded) {
            try? data.write(to: metaURL, options: .atomic)
        }
    }

    private final class Coordinator: NSObject, URLSessionDownloadDelegate {
        weak var manager: AudioDownloadManager?
        private var temporaryURLs: [Int: URL] = [:]

        init(manager: AudioDownloadManager) {
            self.manager = manager
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard let key = downloadTask.taskDescription else { return }
            Task { @MainActor [weak manager] in
                manager?.updateProgress(for: key, written: totalBytesWritten, expected: totalBytesExpectedToWrite)
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: false)
            guard (try? FileManager.default.copyItem(at: location, to: temporaryURL)) != nil else { return }
            temporaryURLs[downloadTask.taskIdentifier] = temporaryURL
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let key = task.taskDescription else { return }
            let temporaryURL = temporaryURLs.removeValue(forKey: task.taskIdentifier)
            Task { @MainActor [weak manager] in
                if let temporaryURL {
                    manager?.finishDownload(for: key, temporaryURL: temporaryURL)
                }
                manager?.completeDownload(for: key)
            }
        }
    }
}
