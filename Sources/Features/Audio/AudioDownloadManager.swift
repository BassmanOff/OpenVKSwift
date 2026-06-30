import Foundation
import Combine

/// Загрузка треков для офлайн-прослушивания.
/// Файлы лежат в Application Support/Audio, метаданные — в downloads.json.
@MainActor
final class AudioDownloadManager: ObservableObject {
    @Published private(set) var downloaded: [Audio] = []
    @Published private(set) var inProgress: Set<String> = []

    private let dir: URL
    private let metaURL: URL

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

    func download(_ audio: Audio) async {
        guard let remote = audio.playbackURL,
              !isDownloaded(audio),
              !inProgress.contains(audio.key) else { return }

        inProgress.insert(audio.key)
        defer { inProgress.remove(audio.key) }

        do {
            let (tmp, _) = try await URLSession.shared.download(from: remote)
            let dest = fileURL(for: audio)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)

            if !isDownloaded(audio) {
                downloaded.append(audio)
                saveMeta()
            }
        } catch {
            // Тихо игнорируем сбой загрузки; UI просто покажет кнопку «скачать» снова.
        }
    }

    func remove(_ audio: Audio) {
        try? FileManager.default.removeItem(at: fileURL(for: audio))
        downloaded.removeAll { $0.id == audio.id }
        saveMeta()
    }

    // MARK: - Private

    private func fileURL(for audio: Audio) -> URL {
        dir.appendingPathComponent("\(audio.key).mp3")
    }

    private func loadMeta() {
        guard let data = try? Data(contentsOf: metaURL),
              let items = try? JSONDecoder().decode([Audio].self, from: data) else { return }
        // Оставляем только те, чьи файлы реально на месте.
        downloaded = items.filter { localURL(for: $0) != nil }
    }

    private func saveMeta() {
        if let data = try? JSONEncoder().encode(downloaded) {
            try? data.write(to: metaURL, options: .atomic)
        }
    }
}
