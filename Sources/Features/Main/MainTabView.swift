import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var longPoll: LongPollService
    @Environment(\.scenePhase) private var scenePhase

    private enum Tab { case feed, messages, music, profile }
    @State private var selection: Tab = .feed
    @State private var showPlayer = false
    /// Модель диалогов живёт здесь: счётчик непрочитанных нужен бейджу на вкладке.
    @StateObject private var conversations = ConversationsViewModel()

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
        .ignoresSafeArea(.keyboard, edges: .bottom) // таб-бар не «прыгает» с клавиатурой
        .sheet(isPresented: $showPlayer) {
            FullScreenPlayerView()
        }
        .task {
            longPoll.start(settings: settings)
            // Пока приложение открыто — держим статус «онлайн» (окно 5 мин, пингуем чаще).
            while !Task.isCancelled {
                settings.reportOnline()
                try? await Task.sleep(nanoseconds: 240 * 1_000_000_000)
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
        // Уведомление о сообщении, когда приложение не на экране
        // (реально случается, пока музыка держит нас живыми в фоне).
        .onReceive(longPoll.newMessage) { event in
            guard settings.notifyMessages, scenePhase != .active else { return }
            NotificationService.notifyMessage(
                peerID: event.peerID,
                messageID: event.messageID,
                text: event.text,
                author: conversations.authors[event.peerID]?.name
            )
        }
        .onChange(of: player.isPlaying) { playing in
            // Музыку возобновили из Пункта управления, находясь в фоне: процесс снова
            // жив (аудио-фон), но scenePhase НЕ меняется — LongPoll перезапускаем вручную.
            if playing {
                if scenePhase != .active { longPoll.start(settings: settings) }
            } else if scenePhase == .background {
                longPoll.stop() // музыка встала в фоне — iOS скоро заморозит процесс
            }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                settings.reportOnline()
                longPoll.start(settings: settings) // после фона переподключаемся
                Task { await conversations.load(settings: settings) } // догоняем пропущенное
            case .background:
                // Пока играет музыка, приложение живёт в фоне (UIBackgroundModes audio) —
                // оставляем LongPoll работать: сообщения придут мгновенно как уведомления.
                if !player.isPlaying {
                    longPoll.stop() // без музыки iOS всё равно заморозит соединение
                }
                if settings.notifyMessages {
                    BackgroundRefresh.schedule() // периодическая проверка при закрытом приложении
                }
            default:
                break
            }
        }
    }

    /// Все вкладки смонтированы (сохраняем их состояние навигации); видна и активна одна.
    private var content: some View {
        ZStack {
            NewsfeedView()
                .opacity(selection == .feed ? 1 : 0)
                .allowsHitTesting(selection == .feed)
            ConversationsView(model: conversations)
                .opacity(selection == .messages ? 1 : 0)
                .allowsHitTesting(selection == .messages)
            AudioListView()
                .opacity(selection == .music ? 1 : 0)
                .allowsHitTesting(selection == .music)
            ProfileView()
                .opacity(selection == .profile ? 1 : 0)
                .allowsHitTesting(selection == .profile)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .handlesOVKLinks() // ссылки OpenVK в контенте вкладок открываются в приложении
    }

    private var tabBar: some View {
        HStack(alignment: .top, spacing: 0) {
            tabButton(.feed, "Новости", "newspaper")
            tabButton(.messages, "Сообщения", "message")
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

    private func tabButton(_ tab: Tab, _ title: String, _ icon: String) -> some View {
        Button { selection = tab } label: {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .overlay(alignment: .topTrailing) {
                        // Бейдж непрочитанных ДИАЛОГОВ на вкладке «Сообщения».
                        if tab == .messages, conversations.unreadDialogsCount > 0 {
                            Text("\(conversations.unreadDialogsCount)")
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
