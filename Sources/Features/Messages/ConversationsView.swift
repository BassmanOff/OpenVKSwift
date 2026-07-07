import SwiftUI
import UIKit
import UserNotifications

/// Список диалогов (messages.getConversations). Чаты OpenVK не поддерживает — только 1-на-1.
@MainActor
final class ConversationsViewModel: ObservableObject {
    @Published private(set) var conversations: [Conversation] = [] {
        didSet { updateAppBadge() }
    }
    @Published private(set) var authors: [Int: WallViewModel.Author] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var canLoadMore = false
    @Published var errorMessage: String?
    private var loaded = false

    /// Пагинация: держим и перечитываем первые fetchLimit диалогов; скролл вниз добавляет страницу.
    /// Маленькая первая страница = быстрый первый кадр на медленном сервере.
    private let pageSize = 20
    private var fetchLimit = 20
    /// Общее число диалогов на сервере (count из ответа).
    private var totalCount: Int?

    // MARK: Непрочитанные.
    // Сервер отдаёт unread_count максимум 1 (проверяет только ПОСЛЕДНЕЕ сообщение),
    // а пометить прочитанным через API нельзя (markAsRead нет; сбрасывает только ответ).
    // Поэтому: точное число копим локально по LongPoll-событиям, серверный флаг
    // показываем «точкой», а «прочитанность» запоминаем сами по id последнего
    // просмотренного сообщения (UserDefaults).

    /// Счётчики новых сообщений, накопленные по LongPoll (peerID → число).
    @Published private(set) var localUnread: [Int: Int] = [:] {
        didSet { updateAppBadge() }
    }
    /// Открытый сейчас диалог — его события не считаются непрочитанными.
    @Published var activePeerID: Int? {
        didSet { updateAppBadge() }
    }
    /// id последнего просмотренного сообщения по диалогам (живёт между запусками).
    private var seenLastID: [Int: Int]
    private static let seenKey = "msg_seen_last_ids"

    init() {
        let raw = (UserDefaults.standard.dictionary(forKey: Self.seenKey) as? [String: Int]) ?? [:]
        seenLastID = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            Int(key).map { ($0, value) }
        })
    }

    /// Пришло LongPoll-событие о новом сообщении.
    func noteIncoming(peer: Int) {
        guard peer != activePeerID else { return }
        localUnread[peer, default: 0] += 1
    }

    /// Диалог открыт/закрыт — считаем всё в нём просмотренным.
    func markSeen(peer: Int) {
        localUnread[peer] = nil
        if let lastID = conversations.first(where: { $0.peerID == peer })?.lastMessage?.id {
            seenLastID[peer] = lastID
            let raw = Dictionary(uniqueKeysWithValues: seenLastID.map { (String($0.key), $0.value) })
            UserDefaults.standard.set(raw, forKey: Self.seenKey)
        }
    }

    /// Есть ли в диалоге непрочитанные ВХОДЯЩИЕ (локальный счётчик или серверный флаг).
    func hasUnread(_ convo: Conversation) -> Bool {
        if convo.peerID == activePeerID { return false }
        if (localUnread[convo.peerID] ?? 0) > 0 { return true }
        guard convo.unreadCount > 0,
              let last = convo.lastMessage, !last.isOut else { return false }
        // Сервер не даёт снять флаг — гасим его локальной отметкой о просмотре.
        return last.id > (seenLastID[convo.peerID] ?? 0)
    }

    /// Число диалогов с непрочитанными — для бейджа на вкладке.
    var unreadDialogsCount: Int {
        conversations.filter { hasUnread($0) }.count
    }

    /// Число непрочитанных СООБЩЕНИЙ — для бейджа на иконке приложения.
    /// Локальный счётчик (по LongPoll) точный; там где есть только серверный флаг —
    /// считаем ≤1 (сервер знает лишь про последнее сообщение).
    var unreadMessagesCount: Int {
        conversations.reduce(0) { sum, convo in
            guard convo.peerID != activePeerID else { return sum }
            if let n = localUnread[convo.peerID], n > 0 { return sum + n }
            if let last = convo.lastMessage, !last.isOut, convo.unreadCount > 0,
               last.id > (seenLastID[convo.peerID] ?? 0) {
                return sum + convo.unreadCount
            }
            return sum
        }
    }

    /// Обновляет бейдж на иконке приложения (число непрочитанных сообщений).
    private func updateAppBadge() {
        let count = unreadMessagesCount
        if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(count)
        } else {
            Self.setLegacyBadge(count)
        }
    }

    /// iOS 15: applicationIconBadgeNumber (устарел с iOS 17). Помечаем функцию deprecated,
    /// чтобы использование устаревшего API внутри неё не давало предупреждения.
    @available(iOS, deprecated: 16.0)
    private static func setLegacyBadge(_ count: Int) {
        UIApplication.shared.applicationIconBadgeNumber = count
    }

    func loadIfNeeded(settings: AppSettings) async {
        guard !loaded else { return }
        loaded = true
        await load(settings: settings)
    }

    func load(settings: AppSettings) async {
        guard let token = settings.token else { return }
        // Мгновенно показываем кэш (в т.ч. офлайн), потом обновляем сетью.
        if conversations.isEmpty, let cached = Self.loadCache() {
            conversations = cached.conversations
            authors = cached.authors
        }
        isLoading = conversations.isEmpty
        errorMessage = nil
        defer { isLoading = false }

        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        do {
            let res: ConversationsResponse = try await client.call(
                "messages.getConversations",
                params: ["count": String(fetchLimit), "extended": "1"]
            )
            for u in res.profiles ?? [] {
                authors[u.id] = WallViewModel.Author(name: u.fullName, avatar: u.avatarURL)
            }
            conversations = res.items
            totalCount = res.count
            canLoadMore = conversations.count < (totalCount ?? 0)
            Self.saveCache(DialogsCache(conversations: conversations, authors: authors))
        } catch {
            if error.isCancellation { return }
            // Оффлайн/ошибка: если есть кэш — молча оставляем его.
            if conversations.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    /// Догрузка следующей страницы (по появлению последней строки).
    /// Расширяем fetchLimit и перечитываем список целиком — так все тихие обновления
    /// (LongPoll/60с/вкладка) автоматически держат уже догруженные страницы в актуальном виде.
    func loadMore(settings: AppSettings) async {
        guard !isLoadingMore, !isLoading, canLoadMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        fetchLimit += pageSize
        await load(settings: settings)
    }

    // MARK: - Дисковый кэш (список виден сразу и офлайн)

    private struct DialogsCache: Codable {
        let conversations: [Conversation]
        let authors: [Int: WallViewModel.Author]
    }

    private static let cacheURL: URL = {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("dialogs_cache.json")
    }()

    private static func saveCache(_ cache: DialogsCache) {
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    private static func loadCache() -> DialogsCache? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(DialogsCache.self, from: data)
    }

    /// Стирает кэш (при выходе из аккаунта — это личные данные).
    static func clearCache() {
        try? FileManager.default.removeItem(at: cacheURL)
    }
}

struct ConversationsView: View {
    /// Модель живёт в MainTabView — счётчик непрочитанных нужен и таб-бару.
    @ObservedObject var model: ConversationsViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var longPoll: LongPollService
    /// Открытый диалог (программная навигация — надёжнее NavigationLink в строках на iOS 15).
    @State private var openPeerID: Int?

    var body: some View {
        NavigationView {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(OVK.Palette.background.ignoresSafeArea())
                .navigationTitle("Сообщения")
                .navigationBarTitleDisplayMode(.inline)
                .background(
                    NavigationLink(
                        isActive: Binding(
                            get: { openPeerID != nil },
                            set: { active in
                                if !active, let peer = openPeerID {
                                    // Выход из диалога — фиксируем просмотренное.
                                    model.markSeen(peer: peer)
                                    model.activePeerID = nil
                                    openPeerID = nil
                                }
                            }
                        )
                    ) {
                        if let peerID = openPeerID {
                            ChatView(peerID: peerID,
                                     title: model.authors[peerID]?.name ?? "Диалог",
                                     avatarURL: model.authors[peerID]?.avatar)
                        }
                    } label: { EmptyView() }
                    .hidden()
                )
                // Тап по уведомлению — открываем нужный диалог.
                .onReceive(NotificationRouter.shared.$pendingPeerID) { peer in
                    guard let peer else { return }
                    NotificationRouter.shared.pendingPeerID = nil
                    openChat(peer: peer)
                }
                .task {
                    await model.loadIfNeeded(settings: settings)
                    // Свои сообщения, отправленные с других устройств (веб), НЕ дают
                    // LongPoll-событий (сервер шлёт событие только ПОЛУЧАТЕЛЮ) —
                    // добираем их периодическим тихим обновлением списка.
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                        await model.load(settings: settings)
                    }
                }
                // Новое сообщение в любом диалоге — учитываем в счётчике и тихо
                // обновляем список (load показывает спиннер только когда список пуст).
                // Второй проход подбирает события, проглоченные сервером в очереди.
                .onReceive(longPoll.newMessage) { event in
                    model.noteIncoming(peer: event.peerID)
                    Task {
                        await model.load(settings: settings)
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        await model.load(settings: settings)
                    }
                }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.conversations.isEmpty {
            ProgressView()
        } else if let error = model.errorMessage, model.conversations.isEmpty {
            ErrorRetry(message: error) { Task { await model.load(settings: settings) } }
        } else if model.conversations.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 40))
                    .foregroundColor(OVK.Palette.textSecondary)
                Text("Нет сообщений")
                    .foregroundColor(OVK.Palette.textSecondary)
            }
        } else {
            List {
                ForEach(model.conversations) { convo in
                    Button {
                        openChat(peer: convo.peerID)
                    } label: {
                        row(convo)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        // Показалась последняя строка — догружаем следующую страницу.
                        if convo.id == model.conversations.last?.id {
                            Task { await model.loadMore(settings: settings) }
                        }
                    }
                }
                if model.isLoadingMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .refreshable { await model.load(settings: settings) }
        }
    }

    /// Открывает диалог (из списка или по тапу на уведомление). Если другой диалог
    /// уже открыт — сперва закрываем: NavigationLink не умеет менять пункт назначения на лету.
    private func openChat(peer: Int) {
        let open = {
            model.markSeen(peer: peer)
            model.activePeerID = peer
            openPeerID = peer
        }
        if openPeerID != nil, openPeerID != peer {
            model.activePeerID = nil
            openPeerID = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { open() }
        } else {
            open()
        }
    }

    private func row(_ convo: Conversation) -> some View {
        let author = model.authors[convo.peerID]
        return HStack(spacing: 10) {
            CachedImage(url: author?.avatar) {
                ZStack { OVK.Palette.background; Image(systemName: "person.crop.square").foregroundColor(OVK.Palette.textSecondary) }
            }
            .frame(width: 48, height: 48)
            .clipped()
            .cornerRadius(4)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(author?.name ?? "Диалог")
                        .font(.subheadline).fontWeight(.semibold)
                        .foregroundColor(OVK.Palette.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    if let last = convo.lastMessage {
                        Text(Self.dateText(last.date))
                            .font(.caption2)
                            .foregroundColor(OVK.Palette.textSecondary)
                    }
                }
                HStack(spacing: 6) {
                    if let last = convo.lastMessage {
                        Text((last.isOut ? "Вы: " : "") + last.text)
                            .font(.footnote)
                            .foregroundColor(OVK.Palette.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    // Точное число знаем только из LongPoll (сервер отдаёт максимум «1»,
                    // проверяя лишь последнее сообщение) — иначе показываем точку.
                    if model.hasUnread(convo) {
                        let count = model.localUnread[convo.peerID] ?? 0
                        if count > 0 {
                            Text("\(count)")
                                .font(.caption2).fontWeight(.semibold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(OVK.Palette.primary))
                        } else {
                            Circle()
                                .fill(OVK.Palette.primary)
                                .frame(width: 9, height: 9)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    // DateFormatter дорог в создании — держим статически (вызывается в каждой строке).
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "HH:mm"
        return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM"
        return f
    }()

    private static func dateText(_ timestamp: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        return Calendar.current.isDateInToday(date)
            ? timeFormatter.string(from: date)
            : dayFormatter.string(from: date)
    }
}
