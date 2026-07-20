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
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var pendingAudio: [String: Audio] = [:]
    private lazy var session = URLSession(
        configuration: .default,
        delegate: Coordinator(manager: self),
        delegateQueue: nil
    )

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("Audio", isDirectory: true)
        metaURL = dir.appendingPathComponent("downloads.json")
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
        guard let remote = audio.playbackURL,
              !isDownloaded(audio),
              tasks[audio.key] == nil else { return }

        let key = audio.key
        inProgress.insert(key)
        progress.values[key] = 0
        pendingAudio[key] = audio
        let task = session.downloadTask(with: remote)
        task.taskDescription = key
        tasks[key] = task
        task.resume()
    }

    /// Последовательный вариант для массовой загрузки в настройках.
    func downloadAndWait(_ audio: Audio) async {
        download(audio)
        while inProgress.contains(audio.key) && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func cancelDownload(_ audio: Audio) {
        tasks[audio.key]?.cancel()
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
    }

    // MARK: - Private

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
            guard let key = downloadTask.taskDescription else { return }
            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: false)
            guard (try? FileManager.default.copyItem(at: location, to: temporaryURL)) != nil else { return }
            Task { @MainActor [weak manager] in
                manager?.finishDownload(for: key, temporaryURL: temporaryURL)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let key = task.taskDescription else { return }
            Task { @MainActor [weak manager] in
                manager?.completeDownload(for: key)
            }
        }
    }
}
