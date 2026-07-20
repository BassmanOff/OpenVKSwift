import SwiftUI
import UserNotifications

@MainActor
final class DownloadAllViewModel: ObservableObject {
    @Published var isRunning = false
    @Published var progress: String?
    @Published var checkingUpdates = false

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
            await downloads.downloadAndWait(track)
            done += 1
        }
        progress = "Готово: скачано \(done)"
    }
}

/// Настройки — обычный пуш в NavigationView владельца (ProfileView), НЕ модалка.
/// Так ссылки внутри (разработчик и т.п.) просто пушатся дальше по тому же стеку,
/// вместо того чтобы открываться «за» модальным окном.
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var downloads: AudioDownloadManager
    @StateObject private var downloadAll = DownloadAllViewModel()
    /// Подтверждение очистки кэша («Кэш музыки очищен» и т.п.).
    @State private var cacheNote: String?
    /// Состояние «Обновления контента» iOS (от него зависит BGAppRefresh).
    @State private var bgRefreshStatus = UIApplication.shared.backgroundRefreshStatus
    /// Реальное системное разрешение на уведомления (а не наш локальный тумблер) —
    /// его могли отклонить при первом запуске или отозвать потом в Настройках iOS,
    /// тогда UNUserNotificationCenter.add молча ничего не покажет, а тумблер тут будет думать, что всё включено.
    @State private var systemAuthDenied = false
    /// Диалоги подтверждения для кэш-операций.
    @State private var confirmClear: String?
    /// Результат проверки обновлений по тегам GitHub (nil — ещё не проверяли/идёт проверка).
    @State private var updateResult: UpdateChecker.Result?
    @State private var isCheckingUpdate = false

    var body: some View {
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

                    if settings.notifyMessages, systemAuthDenied {
                        Label(
                            "Уведомления запрещены в системных настройках iOS — приложение их не увидит, пока вы не разрешите вручную.",
                            systemImage: "bell.slash.fill"
                        )
                        .font(.footnote)
                        .foregroundColor(.red)
                        Button("Открыть настройки iOS") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    } else if settings.notifyMessages, !settings.backgroundKeepAlive, bgRefreshStatus != .available {
                        Label(
                            "«Обновление контента» отключено в iOS — при закрытом приложении уведомления приходить не будут. Включите: Настройки → Основные → Обновление контента, либо включите «Фоновый режим» выше.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.footnote)
                        .foregroundColor(.orange)
                    }
                }

                Section(footer: Text("Бейдж на значке «Архив» в списке диалогов — сколько там непрочитанных. В общий счётчик сообщений (вкладка «Сообщения», иконка приложения) архив не входит.")) {
                    Toggle("Непрочитанные в архиве", isOn: $settings.countArchivedUnread)
                }

                Section(footer: Text("Ссылка на запись (например, из репоста) в личных сообщениях показывается как карточка. Касается только записей БЕЗ фото — с фото запись всегда показывается с полноразмерным фото, как обычная фотография в чате. Развёрнутая — автор и текст в несколько строк; компактная — короткая строка.")) {
                    Toggle("Развёрнутая карточка записи в ЛС", isOn: $settings.messagePostFullCard)
                }

                Section(
                    header: Text("Изображения (отладка)"),
                    footer: Text("Даунсэмплинг и фоновое декодирование: меньше памяти и плавнее скролл, но картинка появляется чуть позже. Выключите, чтобы сравнить — действует сразу.")
                ) {
                    Toggle("Оптимизация изображений", isOn: $settings.imageOptimization)
                }

                Section(
                    header: Text("Сообщения (отладка)"),
                    footer: Text("Реакции реализованы через скрытые сообщения. Выключите, чтобы увидеть переписку как в веб-версии OpenVK — реакции станут обычными текстовыми сообщениями. Действует при следующем открытии диалога.")
                ) {
                    Toggle("Кастомные реакции", isOn: $settings.enableCustomReactions)
                }

                Section(header: Text("Плеер (отладка)")) {
                    Toggle("Новый плеер (в разработке)", isOn: $settings.useNewPlayer)
                }

                Section(
                    header: Text("Кэш (отладка)"),
                    footer: Text("Скачанные треки не затрагиваются. После очистки приложение закроется — запустите его заново.")
                ) {
                    Button("Очистить кэш музыки") {
                        confirmClear = "music"
                    }
                    Button("Очистить кэш сообщений") {
                        confirmClear = "messages"
                    }
                    Button("Очистить кэш изображений") {
                        confirmClear = "images"
                    }
                    Button("Очистить весь кэш", role: .destructive) {
                        confirmClear = "all"
                    }
                }
                Section(
                    header: Text("О приложении"),
                    footer: updateFooter
                ) {
                    HStack {
                        Text("Версия")
                        Spacer()
                        Text(UpdateChecker.currentVersion).foregroundColor(OVK.Palette.textSecondary)
                    }

                    HStack {
                        Text("Разработчик")
                        Spacer()
                        Link("BassmanOff", destination: URL(string: "https://openvk.org/id21510")!)
                            .foregroundColor(OVK.Palette.primary)
                    }

                    if let result = updateResult, result.isUpdateAvailable, let latest = result.latestVersion {
                        Link(destination: result.releaseURL) {
                            HStack {
                                Label("Доступна версия \(latest)", systemImage: "arrow.down.circle.fill")
                                    .foregroundColor(OVK.Palette.primary)
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption)
                                    .foregroundColor(OVK.Palette.textSecondary)
                            }
                        }
                    }

                    Button(isCheckingUpdate ? "Проверка…" : "Проверить обновления") {
                        Task { await runUpdateCheck(force: true) }
                    }
                    .disabled(isCheckingUpdate)
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            // Пуш (не модалка) — .task перезапускается при каждом заходе,
            // так и подхватываем изменения, сделанные в Настройках iOS между заходами.
            .task {
                let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                systemAuthDenied = status == .denied
                await runUpdateCheck(force: false) // из кэша, если проверяли < часа назад
            }
            .confirmationDialog("Очистить кэш?", isPresented: Binding(
                get: { confirmClear != nil },
                set: { if !$0 { confirmClear = nil } }
            ), presenting: confirmClear) { action in
                Button("Очистить", role: .destructive) {
                    performClearCache(confirmClear!)
                }
            } message: { kind in
                switch kind {
                case "music":
                    Text("Это очистит кэш музыки. Скачанные треки?")
                case "messages":
                    Text("Это очистит кэш сообщений и диалогов.")
                case "images":
                    Text("Это очистит кэш изображений и обложек.")
                default:
                    Text("Это очистит весь кэш приложения.")
                }
            }
            // Актуализируем статус «Обновления контента» (мог измениться в Настройках iOS).
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.backgroundRefreshStatusDidChangeNotification
            )) { _ in
                bgRefreshStatus = UIApplication.shared.backgroundRefreshStatus
            }
    }

    private var notificationsFooter: String {
        """
        «Фоновый режим» пытается удержать службу отправки уведомлений рабочей, даже когда приложение свёрнуто.
        В любом случае НЕ смахивайте приложение из свитчера - это убивает фоновую работу.
        """
    }

    /// Закрывает приложение после очистки кэша (перезапуск всё равно нужен).
    /// Небольшая задержка — чтобы записи на диск успели завершиться.
    private static func terminate() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            exit(0)
        }
    }

    /// Проверка обновлений по тегам GitHub (нет App Store — TrollStore/SideStore
    /// не умеют опрашивать обновления сами, поэтому сверяемся вручную).
    private func runUpdateCheck(force: Bool) async {
        isCheckingUpdate = true
        updateResult = await UpdateChecker.check(currentVersion: UpdateChecker.currentVersion, force: force)
        isCheckingUpdate = false
    }

    @ViewBuilder
    private var updateFooter: some View {
        if let result = updateResult, result.isUpdateAvailable {
            EmptyView() // ссылка на обновление уже видна как отдельная строка в секции
        } else if updateResult != nil {
            Text("Установлена последняя версия.")
        } else {
            Text("Обновления публикуются как теги в GitHub-репозитории (без App Store).")
        }
    }

    private func performClearCache(_ kind: String) {
        switch kind {
        case "music":
            AudioViewModel.clearCache()
            CoverArtService.shared.clearCache()
            LyricsService.clearCache()
        case "messages":
            ConversationsViewModel.clearCache()
            ChatViewModel.clearAllCaches()
        case "images":
            URLCache.shared.removeAllCachedResponses()
            ImageCache.shared.removeAll()
        case "all":
            AudioViewModel.clearCache()
            CoverArtService.shared.clearCache()
            LyricsService.clearCache()
            ConversationsViewModel.clearCache()
            ChatViewModel.clearAllCaches()
            URLCache.shared.removeAllCachedResponses()
            ImageCache.shared.removeAll()
            ObjectResolver.shared.clear()
            NewsfeedViewModel.clearCache()
            ProfileViewModel.clearCache()
            WallViewModel.clearCache()
        default:
            break
        }
        Self.terminate()
    }
}
