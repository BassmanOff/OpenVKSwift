import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var longPoll: LongPollService
    @EnvironmentObject private var keepAlive: KeepAliveService
    @Environment(\.scenePhase) private var scenePhase

    /// Держим ли процесс живым в фоне (тихое аудио) — когда музыка не играет.
    /// Если да, LongPoll не глушим при уходе в фон → мгновенные уведомления.
    private var backgroundStaysAlive: Bool {
        player.isPlaying || settings.backgroundKeepAlive
    }

    private enum Tab: Int { case feed, messages, friends, music, profile }
    @State private var selection: Tab = .feed
    /// ОБЩИЙ роутер ссылок: глобальный перехват (override ниже) кладёт сюда назначение +
    /// индекс активной вкладки, а `.pushesGlobalLinks(tab:)` внутри каждой вкладки пушит его
    /// в её стек — VK-style (страница справа, свайп-назад, таб-бар на месте).
    @StateObject private var linkRouter = LinkRouter()
    @State private var showPlayer = false
    /// Модель диалогов живёт здесь: счётчик непрочитанных нужен бейджу на вкладке.
    @StateObject private var conversations = ConversationsViewModel()
    /// Активность («Ответы») живёт здесь — ЕДИНЫЙ источник для бейджа колокольчика (в ленте)
    /// И бейджа вкладки «Новости». Периодический refresh ведёт .task ниже (работает на любой
    /// вкладке, в т.ч. при играющей музыке), NewsfeedView лишь читает и делает первичную загрузку.
    @StateObject private var activity = ActivityViewModel()
    /// Друзья — живёт здесь для сохранения состояния поиска/скролла между переключениями вкладок.
    @StateObject private var friendsTab = FriendsTabViewModel()

    var body: some View {
        // Явная раскладка: контент → мини-плеер → таб-бар. Так музыка НИКОГДА не перекрывает
        // ни меню, ни нижние панели разделов (например, вкладки в «Сообществах»).
        VStack(spacing: 0) {
            content
            if player.current != nil {
                MiniPlayerView(onExpand: { showPlayer = true })
            }
            tabBar
        }
        // ГЛОБАЛЬНЫЙ перехват ссылок OpenVK: override навешен НАД всеми вкладками → наследуется
        // КАЖДЫМ экраном (все вкладки И запушенные экраны, вкл. «Ответы»/ActivityView из тулбара).
        // Тап фиксирует активную вкладку в роутере; пуш делает `.pushesGlobalLinks(tab:)` ВНУТРИ
        // этой вкладки. Модалки (плеер, комментарии-sheet) override не наследуют через границу —
        // на них .handlesOVKLinks() навешен отдельно (пуш в NavigationView самой модалки).
        .environment(\.openURL, OpenURLAction { url in
            linkRouter.open(url, activeTab: selection.rawValue) ? .handled : .systemAction
        })
        .environmentObject(linkRouter)
        .ignoresSafeArea(.keyboard, edges: .bottom) // таб-бар не «прыгает» с клавиатурой
        .sheet(isPresented: $showPlayer) {
            FullScreenPlayerView()
        }
        .task {
            longPoll.start(settings: settings)
            // Уведомления включены по умолчанию — спрашиваем системное разрешение при
            // первом запуске (idempotent: если уже отвечали, повторного алерта нет) и
            // планируем фоновую проверку.
            if settings.notifyMessages {
                if await NotificationService.requestPermission() {
                    BackgroundRefresh.schedule()
                } else {
                    // Отклонили системный алерт (сейчас или раньше — запрос идемпотентный) —
                    // тумблер должен честно показывать, что уведомлений не будет, а не молчать.
                    settings.notifyMessages = false
                }
            }
            // Пока приложение открыто — держим статус «онлайн» (окно 5 мин, пингуем чаще).
            while !Task.isCancelled {
                settings.reportOnline()
                try? await Task.sleep(nanoseconds: 240 * 1_000_000_000)
            }
        }
        // Периодический refresh активности («Ответы») — ЖИВЁТ НА ВСЕХ ВКЛАДКАХ (task привязан
        // к контейнеру, а не к ленте) и при играющей музыке. OpenVK не шлёт LongPoll-событий
        // об активности, поэтому опрос — единственный путь; интервал 30с (было 90с только в ленте).
        .task {
            await activity.loadIfNeeded(settings: settings)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                print("[Notifications] \(debugNow()) периодический refresh активности")
                await activity.reload(settings: settings)
            }
        }
        .onChange(of: selection) { sel in
            // Открыли вкладку «Сообщения» — тихо освежаем список (свои сообщения
            // с других устройств не приходят через LongPoll).
            if sel == .messages {
                Task { await conversations.load(settings: settings) }
            }
        }
        // Тап по уведомлению — переключаемся на вкладку «Сообщения»
        // (сам диалог откроет ConversationsView).
        .onReceive(NotificationRouter.shared.$pendingPeerID) { peer in
            if peer != nil { selection = .messages }
        }
        // Тап по баннеру активности — на «Новости» (сам экран «Ответы» пушит NewsfeedView).
        .onReceive(NotificationRouter.shared.$pendingActivity) { pending in
            if pending { selection = .feed }
        }
        // Уведомление о сообщении, когда приложение не на экране
        // (реально случается, пока музыка держит нас живыми в фоне).
        .onReceive(longPoll.newMessage) { event in
            // Уведомляем, даже когда приложение активно (баннер показывает
            // willPresent в AppDelegate). Пропускаем ТОЛЬКО уже открытый диалог
            // (conversations.activePeerID) — его ChatView сам вставит и отметит прочитанным.
            guard settings.notifyMessages else { return }
            guard event.peerID != conversations.activePeerID else { return }
            NotificationService.notifyMessage(
                peerID: event.peerID,
                messageID: event.messageID,
                text: event.text,
                author: conversations.authors[event.peerID]?.name
            )
        }
        .onChange(of: player.isPlaying) { playing in
            if playing {
                keepAlive.stop() // музыка сама держит процесс — тихое аудио не нужно
                // Музыку возобновили из Пункта управления в фоне: scenePhase НЕ меняется —
                // LongPoll перезапускаем вручную.
                if scenePhase != .active { longPoll.start(settings: settings) }
            } else if scenePhase == .background {
                // Музыка встала в фоне. Если включён фоновый режим — подхватываем тихим
                // аудио, чтобы процесс не заснул и LongPoll продолжал работать.
                if settings.backgroundKeepAlive {
                    keepAlive.start()
                } else {
                    longPoll.stop()
                }
            }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                keepAlive.stop() // на экране тихое аудио не нужно
                settings.reportOnline()
                longPoll.start(settings: settings) // после фона переподключаемся
                Task { await conversations.load(settings: settings) } // догоняем пропущенное
                Task { await activity.reload(settings: settings) } // и активность — сразу, не ждём 30с

            case .background:
                // Держим процесс живым (музыка ИЛИ фоновый режим) → LongPoll не глушим,
                // сообщения приходят мгновенно как уведомления.
                if backgroundStaysAlive {
                    if !player.isPlaying { keepAlive.start() } // тихое аудио вместо музыки
                } else {
                    longPoll.stop() // ничего не держит процесс — iOS его заморозит
                }
                // Планируем фоновую задачу всегда (при входе): она и обновляет кэш ленты,
                // и — если включены — проверяет новые сообщения.
                if settings.isLoggedIn {
                    BackgroundRefresh.schedule()
                }
            default:
                break
            }
        }
    }

    /// Все вкладки смонтированы (сохраняем их состояние навигации); видна и активна одна.
    private var content: some View {
        ZStack {
            NewsfeedView(activity: activity)
                .opacity(selection == .feed ? 1 : 0)
                .allowsHitTesting(selection == .feed)
            ConversationsView(model: conversations)
                .opacity(selection == .messages ? 1 : 0)
                .allowsHitTesting(selection == .messages)
            FriendsTabView(
                model: friendsTab,
                isActive: Binding(get: { selection == .friends }, set: { _ in })
            )
                .opacity(selection == .friends ? 1 : 0)
                .allowsHitTesting(selection == .friends)
            AudioListView()
                .opacity(selection == .music ? 1 : 0)
                .allowsHitTesting(selection == .music)
            ProfileView()
                .opacity(selection == .profile ? 1 : 0)
                .allowsHitTesting(selection == .profile)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tabBar: some View {
        HStack(alignment: .top, spacing: 0) {
            tabButton(.feed, "Новости", "newspaper", badge: activity.unreadCount)
            tabButton(.messages, "Сообщения", "message", badge: conversations.unreadDialogsCount)
            tabButton(.friends, "Друзья", "person.2")
            tabButton(.music, "Музыка", "music.note")
            tabButton(.profile, "Профиль", "person.crop.circle")
        }
        .padding(.top, 6)
        .background(
            OVK.Palette.card
                .ignoresSafeArea(edges: .bottom) // фон уходит под home-indicator
                .overlay(Divider(), alignment: .top)
        )
    }

    /// `badge` — число непрочитанных для вкладки (сообщения/активность); 0 = нет бейджа.
    private func tabButton(_ tab: Tab, _ title: String, _ icon: String, badge: Int = 0) -> some View {
        Button {
            if selection == tab {
                // Уже на этой вкладке — pop-to-root её стека (анимированно, как свайп-назад).
                linkRouter.resetTrigger[tab.rawValue, default: 0] += 1
            }
            selection = tab
        } label: {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .overlay(alignment: .topTrailing) {
                        // Бейдж непрочитанных: диалоги («Сообщения») / активность («Новости»).
                        if badge > 0 {
                            Text(badge > 99 ? "99+" : "\(badge)")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.red))
                                .offset(x: 10, y: -6)
                        }
                    }
                Text(title).font(.system(size: 10))
            }
            .foregroundColor(selection == tab ? OVK.Palette.primary : OVK.Palette.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
