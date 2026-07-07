import SwiftUI

@MainActor
final class DownloadAllViewModel: ObservableObject {
    @Published var isRunning = false
    @Published var progress: String?

    func downloadAll(settings: AppSettings, downloads: AudioDownloadManager) async {
        guard !isRunning, let token = settings.token else { return }
        isRunning = true
        defer { isRunning = false }

        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        let tracks: [Audio]
        do {
            let res: ItemsResponse<Audio> = try await client.call("audio.get", params: ["count": "100"])
            tracks = res.items
        } catch {
            progress = "Не удалось получить список"
            return
        }

        let pending = tracks.filter { $0.isPlayable && !downloads.isDownloaded($0) }
        guard !pending.isEmpty else { progress = "Всё уже скачано"; return }

        var done = 0
        for track in pending {
            progress = "Скачивание \(done + 1) из \(pending.count)…"
            await downloads.download(track)
            done += 1
        }
        progress = "Готово: скачано \(done)"
    }
}

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var downloads: AudioDownloadManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var downloadAll = DownloadAllViewModel()
    /// Подтверждение очистки кэша («Кэш музыки очищен» и т.п.).
    @State private var cacheNote: String?
    /// Состояние «Обновления контента» iOS (от него зависит BGAppRefresh).
    @State private var bgRefreshStatus = UIApplication.shared.backgroundRefreshStatus

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Музыка"), footer: Text("Треки будут автоматически скачиваться для офлайна — когда вы добавляете их в «Мою музыку» и когда слушаете.")) {
                    Toggle("Автоматически скачивать треки", isOn: $settings.autoDownloadMyTracks)

                    if downloadAll.isRunning {
                        HStack {
                            ProgressView()
                            Text(downloadAll.progress ?? "Скачивание…")
                                .foregroundColor(OVK.Palette.textSecondary)
                        }
                    } else {
                        Button("Скачать все мои треки") {
                            Task { await downloadAll.downloadAll(settings: settings, downloads: downloads) }
                        }
                        if let progress = downloadAll.progress {
                            Text(progress)
                                .font(.footnote)
                                .foregroundColor(OVK.Palette.textSecondary)
                        }
                    }
                }
                Section(
                    header: Text("Уведомления"),
                    footer: Text(notificationsFooter)
                ) {
                    Toggle("Сообщения", isOn: Binding(
                        get: { settings.notifyMessages },
                        set: { enabled in
                            settings.notifyMessages = enabled
                            if enabled {
                                Task {
                                    // Без разрешения системы уведомления не показать — откатываем.
                                    if await !NotificationService.requestPermission() {
                                        settings.notifyMessages = false
                                    } else {
                                        BackgroundRefresh.schedule()
                                    }
                                }
                            } else {
                                // Нет уведомлений — фоновый режим бессмыслен.
                                settings.backgroundKeepAlive = false
                            }
                        }
                    ))

                    Toggle("Фоновый режим (мгновенно)", isOn: Binding(
                        get: { settings.backgroundKeepAlive },
                        set: { enabled in
                            settings.backgroundKeepAlive = enabled
                            // Фоновый режим показывает уведомления → включаем «Сообщения»
                            // и спрашиваем разрешение, если ещё не дано.
                            if enabled, !settings.notifyMessages {
                                settings.notifyMessages = true
                                Task {
                                    if await !NotificationService.requestPermission() {
                                        settings.notifyMessages = false
                                        settings.backgroundKeepAlive = false
                                    } else {
                                        BackgroundRefresh.schedule()
                                    }
                                }
                            }
                        }
                    ))

                    if settings.notifyMessages, !settings.backgroundKeepAlive, bgRefreshStatus != .available {
                        Label(
                            "«Обновление контента» отключено в iOS — при закрытом приложении уведомления приходить не будут. Включите: Настройки → Основные → Обновление контента, либо включите «Фоновый режим» выше.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.footnote)
                        .foregroundColor(.orange)
                    }
                }

                Section(
                    header: Text("Изображения (отладка)"),
                    footer: Text("Даунсэмплинг и фоновое декодирование: меньше памяти и плавнее скролл, но картинка появляется чуть позже. Выключите, чтобы сравнить — действует сразу.")
                ) {
                    Toggle("Оптимизация изображений", isOn: $settings.imageOptimization)
                }

                Section(
                    header: Text("Кэш (отладка)"),
                    footer: Text("Скачанные треки не затрагиваются. После очистки приложение закроется — запустите его заново.")
                ) {
                    Button("Очистить кэш музыки") {
                        // Список «Моей музыки» + обложки iTunes (память и диск).
                        AudioViewModel.clearCache()
                        CoverArtService.shared.clearCache()
                        Self.terminate()
                    }
                    Button("Очистить кэш сообщений") {
                        // Список диалогов + последние страницы переписок.
                        ConversationsViewModel.clearCache()
                        ChatViewModel.clearAllCaches()
                        Self.terminate()
                    }
                    Button("Очистить кэш изображений") {
                        // Дисковый URLCache (картинки и JSON-ответы) + память декодированных.
                        URLCache.shared.removeAllCachedResponses()
                        ImageCache.shared.removeAll()
                        Self.terminate()
                    }
                    Button("Очистить весь кэш", role: .destructive) {
                        AudioViewModel.clearCache()
                        CoverArtService.shared.clearCache()
                        ConversationsViewModel.clearCache()
                        ChatViewModel.clearAllCaches()
                        URLCache.shared.removeAllCachedResponses()
                        ImageCache.shared.removeAll()
                        RepostCache.shared.clear()
                        NewsfeedViewModel.clearCache()
                        ProfileViewModel.clearCache()
                        WallViewModel.clearCache()
                        Self.terminate()
                    }
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            // Актуализируем статус «Обновления контента» (мог измениться в Настройках iOS).
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.backgroundRefreshStatusDidChangeNotification
            )) { _ in
                bgRefreshStatus = UIApplication.shared.backgroundRefreshStatus
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var notificationsFooter: String {
        """
        «Фоновый режим» держит приложение подключённым тихим аудио — сообщения приходят \
        мгновенно даже при закрытом экране (расход батареи ~1–3%/час, пока не играет музыка). \
        Без него уведомления приходят мгновенно только когда приложение открыто или в фоне \
        играет музыка, иначе iOS проверяет их периодически (раз в 15–60 минут). \
        В любом случае НЕ смахивайте приложение из свитчера — это убивает фоновую работу.
        """
    }

    /// Закрывает приложение после очистки кэша (перезапуск всё равно нужен).
    /// Небольшая задержка — чтобы записи на диск успели завершиться.
    private static func terminate() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            exit(0)
        }
    }
}
