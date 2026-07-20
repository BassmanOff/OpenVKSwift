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
    /// true, пока идёт load — параллельные вызовы (таймер/refresh/ретрай) пропускаются.
    private var isReloading = false

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

    // MARK: - Закреплённые / архивные (чисто локально — сервер OpenVK этого не поддерживает:
    // ни pin/archive метода в Messages API, ни колонки в Correspondence — проверено по исходникам).

    /// Порядок закреплённых диалогов (peerID), верх списка — первый элемент.
    @Published private(set) var pinnedOrder: [Int] {
        didSet { UserDefaults.standard.set(pinnedOrder, forKey: Self.pinnedKey) }
    }
    /// Архивные диалоги (peerID).
    @Published private(set) var archived: Set<Int> {
        didSet { UserDefaults.standard.set(Array(archived), forKey: Self.archivedKey) }
    }
    private static let pinnedKey = "msg_pinned_order"
    private static let archivedKey = "msg_archived_peers"

    init() {
        let raw = (UserDefaults.standard.dictionary(forKey: Self.seenKey) as? [String: Int]) ?? [:]
        seenLastID = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            Int(key).map { ($0, value) }
        })
        pinnedOrder = (UserDefaults.standard.array(forKey: Self.pinnedKey) as? [Int]) ?? []
        archived = Set((UserDefaults.standard.array(forKey: Self.archivedKey) as? [Int]) ?? [])
    }

    var pinnedConversations: [Conversation] {
        pinnedOrder.compactMap { id in conversations.first { $0.peerID == id } }
    }
    var unpinnedConversations: [Conversation] {
        conversations.filter { !pinnedOrder.contains($0.peerID) && !archived.contains($0.peerID) }
    }
    var archivedConversations: [Conversation] {
        conversations.filter { archived.contains($0.peerID) }
    }
    /// Непрочитанные в архиве — для бейджа на кнопке «Архив» (в общий счётчик не входит).
    var archivedUnreadCount: Int {
        archivedConversations.filter { hasUnread($0) }.count
    }

    func isPinned(_ peerID: Int) -> Bool { pinnedOrder.contains(peerID) }
    func isArchived(_ peerID: Int) -> Bool { archived.contains(peerID) }

    func togglePin(_ peerID: Int) {
        if let idx = pinnedOrder.firstIndex(of: peerID) {
            pinnedOrder.remove(at: idx)
        } else {
            pinnedOrder.append(peerID)
            archived.remove(peerID) // закреплённое не может быть одновременно в архиве
        }
    }

    func toggleArchive(_ peerID: Int) {
        if archived.contains(peerID) {
            archived.remove(peerID)
        } else {
            archived.insert(peerID)
            pinnedOrder.removeAll { $0 == peerID }
        }
    }

    /// Перестановка закреплённых из нативного edit mode (.onMove). Индексы приходят
    /// по ВИДИМОМУ списку (pinnedConversations) — он может быть короче pinnedOrder,
    /// если какой-то диалог не догрузился; недостающих сохраняем хвостом.
    func movePinned(fromOffsets: IndexSet, toOffset: Int) {
        var visible = pinnedConversations.map(\.peerID)
        visible.move(fromOffsets: fromOffsets, toOffset: toOffset)
        let missing = pinnedOrder.filter { !visible.contains($0) }
        pinnedOrder = visible + missing
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
        // Реентрантность: load зовут 60с-таймер, pull-to-refresh и ретрай ошибки.
        // Без гварда накладываются параллельные getConversations (каждый ~7с на сервере)
        // и дерутся за 6 соединений к хосту. Гвард ПОСЛЕ показа кэша — кэш-кадр не теряем.
        guard !isReloading else { return }
        isReloading = true
        defer { isReloading = false }

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
            await ensurePinnedLoaded(settings: settings)
            Self.saveCache(DialogsCache(conversations: conversations, authors: authors))
        } catch {
            if error.isCancellation { return }
            // Оффлайн/ошибка: если есть кэш — молча оставляем его.
            if conversations.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    /// Точечное обновление одного диалога по LongPoll-событию. peerID из события —
    /// только ПОДСКАЗКА, какой диалог перечитать (поля события недоверенные, данные
    /// берём обычным API); мусорный peerID даст пустой ответ — молча пропускаем.
    /// На сервере getConversations — N+1 по всем диалогам (~7с на 20 диалогов),
    /// getHistory одного пира — доли секунды. Полный reload остаётся 60с-таймеру.
    func refreshPeer(_ peerID: Int, settings: AppSettings) async {
        guard let token = settings.token else { return }
        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        guard let res: HistoryResponse = try? await client.call(
            "messages.getHistory",
            params: ["peer_id": String(peerID), "count": "1", "extended": "1"]
        ), let msg = res.items.first else { return }
        for u in res.profiles ?? [] {
            authors[u.id] = WallViewModel.Author(name: u.fullName, avatar: u.avatarURL)
        }
        conversations.removeAll { $0.peerID == peerID }
        // Новое сообщение = самый свежий диалог — в начало (сервер сортирует так же).
        // unreadCount: 1 для входящего повторяет серверную семантику (максимум 1).
        conversations.insert(Conversation(peerID: peerID, unreadCount: msg.isOut ? 0 : 1, lastMessage: msg), at: 0)
        Self.saveCache(DialogsCache(conversations: conversations, authors: authors))
    }

    /// Закреплённый диалог может не попасть в загруженную страницу (пагинация — по свежести,
    /// а закреплённый мог давно молчать). Догружаем недостающих напрямую по peer_id и
    /// вклеиваем — иначе они молча пропадали бы из «закреплённых» до случайной догрузки страницы.
    private func ensurePinnedLoaded(settings: AppSettings) async {
        let missing = pinnedOrder.filter { id in !conversations.contains { $0.peerID == id } }
        guard !missing.isEmpty, let token = settings.token else { return }
        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        // Параллельно: N последовательных round-trip'ов схлопываются в один самый долгий.
        let results = await withTaskGroup(of: (Int, HistoryResponse?).self) { group in
            for peerID in missing {
                group.addTask {
                    (peerID, try? await client.call(
                        "messages.getHistory",
                        params: ["peer_id": String(peerID), "count": "1", "extended": "1"]
                    ) as HistoryResponse)
                }
            }
            var out: [(Int, HistoryResponse)] = []
            for await (id, res) in group { if let res { out.append((id, res)) } }
            return out
        }
        for (peerID, res) in results {
            for u in res.profiles ?? [] {
                authors[u.id] = WallViewModel.Author(name: u.fullName, avatar: u.avatarURL)
            }
            // unreadCount: 0 — закреплённый диалог без данных о непрочитанности лучше
            // считать прочитанным, чем неверно раздувать бейдж по недостающим данным.
            conversations.append(Conversation(peerID: peerID, unreadCount: 0, lastMessage: res.items.first))
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
        UserDefaults.standard.removeObject(forKey: pinnedKey)
        UserDefaults.standard.removeObject(forKey: archivedKey)
    }
}

struct ConversationsView: View {
    /// Модель живёт в MainTabView — счётчик непрочитанных нужен и таб-бару.
    @ObservedObject var model: ConversationsViewModel
    let isActive: Bool
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var longPoll: LongPollService
    /// Открытый диалог (программная навигация — надёжнее NavigationLink в строках на iOS 15).
    @State private var openPeerID: Int?
    /// Режим перестановки закреплённых: включается пунктом меню «Изменить порядок»,
    /// выключается кнопкой «Готово» (нативный edit mode — хендлы только у строк с .onMove).
    @State private var editMode: EditMode = .inactive

    var body: some View {
        NavigationView {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(OVK.Palette.background.ignoresSafeArea())
                .navigationTitle("Сообщения")
                .navigationBarTitleDisplayMode(.inline)
                .pushesGlobalLinks(tab: 1) // ссылки из диалогов пушатся в стек этой вкладки
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        // if внутри ToolbarItem — обязательное место (снаружи требует iOS 16).
                        if editMode == .active {
                            Button("Готово") {
                                withAnimation { editMode = .inactive }
                            }
                        }
                    }
                    ToolbarItem(placement: .navigationBarLeading) {
                        NavigationLink {
                            ArchivedConversationsView(model: model)
                        } label: {
                            Image(systemName: "archivebox")
                                .overlay(alignment: .topTrailing) {
                                    let count = model.archivedUnreadCount
                                    if settings.countArchivedUnread, count > 0 {
                                        Text(count > 99 ? "99+" : "\(count)")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Capsule().fill(Color.red))
                                            .offset(x: 10, y: -6)
                                    }
                                }
                        }
                    }
                }
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
                }
                .task(id: isActive) {
                    guard isActive else { return }
                    // Свои сообщения, отправленные с других устройств (веб), НЕ дают
                    // LongPoll-событий (сервер шлёт событие только ПОЛУЧАТЕЛЮ) —
                    // добираем их периодическим тихим обновлением списка, только пока
                    // вкладка видима. Смена вкладки отменяет этот task.
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                        guard !Task.isCancelled else { return }
                        await model.load(settings: settings)
                    }
                }
                // Новое сообщение — точечно перечитываем ТОЛЬКО этот диалог (getHistory
                // одного пира — доли секунды против ~7с полного getConversations с его
                // серверным N+1). Потерянные события и чужие unread добирает 60с-таймер.
                .onReceive(longPoll.newMessage) { event in
                    model.noteIncoming(peer: event.peerID)
                    Task { await model.refreshPeer(event.peerID, settings: settings) }
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
        } else if model.pinnedConversations.isEmpty && model.unpinnedConversations.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 40))
                    .foregroundColor(OVK.Palette.textSecondary)
                Text("Нет сообщений")
                    .foregroundColor(OVK.Palette.textSecondary)
            }
        } else {
            List {
                // Закреплённые — обычные строки этого же списка (просто первые),
                // скроллятся вместе со всем остальным.
                if !model.pinnedConversations.isEmpty {
                    PinnedConversationsSection(model: model, onOpen: openChat) {
                        withAnimation { editMode = .active }
                    }
                }
                ForEach(model.unpinnedConversations) { convo in
                    Button {
                        openChat(peer: convo.peerID)
                    } label: {
                        row(convo)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { contextMenuItems(for: convo) }
                    .onAppear {
                        // Показалась последняя строка — догружаем следующую страницу.
                        if convo.id == model.unpinnedConversations.last?.id {
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
            .environment(\.editMode, $editMode)
        }
    }

    /// Общее меню долгого нажатия — закрепить/открепить, в архив/из архива.
    /// Используется и здесь, и в PinnedConversationsSection (см. её contextMenu).
    @ViewBuilder
    private func contextMenuItems(for convo: Conversation) -> some View {
        Button {
            model.togglePin(convo.peerID)
        } label: {
            Label(model.isPinned(convo.peerID) ? "Открепить" : "Закрепить",
                  systemImage: model.isPinned(convo.peerID) ? "pin.slash" : "pin")
        }
        Button {
            model.toggleArchive(convo.peerID)
        } label: {
            Label(model.isArchived(convo.peerID) ? "Из архива" : "В архив",
                  systemImage: model.isArchived(convo.peerID) ? "tray.and.arrow.up" : "archivebox")
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
        ConversationRow(
            convo: convo,
            author: model.authors[convo.peerID],
            isUnread: model.hasUnread(convo),
            unreadCount: model.localUnread[convo.peerID] ?? 0
        )
    }
}
