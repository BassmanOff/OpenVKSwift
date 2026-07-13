import SwiftUI

@MainActor
final class TopicViewModel: ObservableObject {
    @Published private(set) var comments: [Comment] = []
    @Published private(set) var authors: [Int: WallViewModel.Author] = [:]
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var text = ""
    @Published var isSending = false

    /// Реальный virtual_id темы (нужен board.getComments/createComment); резолвится один раз.
    private var resolvedVID: Int?

    /// БАГ API: Comment::toVkApiStruct пишет from_id = id владельца БЕЗ минуса, поэтому
    /// коммент от имени группы 11307 выглядит как от пользователя 11307. Отличаем по
    /// спискам extended-ответа: у board.getComments клубы приходят отдельно в groups.
    private var clubIDs: Set<Int> = []
    private var profileIDs: Set<Int> = []

    /// Скорректированный id автора коммента (отрицательный для групп).
    func effectiveAuthorID(_ comment: Comment) -> Int {
        if comment.fromID > 0, clubIDs.contains(comment.fromID), !profileIDs.contains(comment.fromID) {
            return -comment.fromID
        }
        return comment.fromID
    }

    var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Подставляет упоминание автора в поле ответа (формат `[id123|Имя]` / `[club45|Имя]`).
    func prefillReply(to authorID: Int, name: String?) {
        let screen = authorID >= 0 ? "id\(authorID)" : "club\(-authorID)"
        let display = name ?? screen
        text = "[\(screen)|\(display)], "
    }

    private func makeClient(_ settings: AppSettings) -> OVKClient? {
        guard let token = settings.token else { return nil }
        return OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
    }

    func load(groupID: Int, topicDBID: Int?, virtualIDGuess: Int, settings: AppSettings) async {
        guard let client = makeClient(settings) else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        if resolvedVID == nil {
            resolvedVID = await resolveVID(client: client, groupID: groupID, topicDBID: topicDBID, guess: virtualIDGuess)
        }
        guard let vid = resolvedVID else {
            errorMessage = "Не удалось открыть тему (ограничение API OpenVK)."
            return
        }
        do {
            let res: CommentsResponse = try await client.call(
                "board.getComments",
                params: ["group_id": String(groupID), "topic_id": String(vid),
                         "need_likes": "1", "count": "100", "extended": "1"]
            )
            profileIDs = Set((res.profiles ?? []).map { $0.id })
            clubIDs = Set((res.groups ?? []).map { $0.groupID })
            for u in res.profiles ?? [] {
                authors[u.id] = WallViewModel.Author(name: u.fullName, avatar: u.avatarURL)
            }
            for g in res.groups ?? [] {
                authors[-g.groupID] = WallViewModel.Author(name: g.name, avatar: g.avatarURL)
            }
            comments = res.items
            await loadGroupAuthors(client: client)
        } catch {
            if error.isCancellation { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Дозапрашивает данные групп-авторов одним groups.getById:
    /// (a) from_id < 0, которых нет в extended-ответе; (b) клубы из extended-ответа —
    /// board отдаёт их через Club::toVkApiStruct БЕЗ полей фото, аватарки нет.
    private func loadGroupAuthors(client: OVKClient) async {
        var need = Set(comments.map { $0.fromID }.filter { $0 < 0 }.map { -$0 })
            .filter { authors[-$0] == nil }
        need.formUnion(clubIDs.filter { authors[-$0]?.avatar == nil })
        guard !need.isEmpty else { return }
        let ids = need.map(String.init).joined(separator: ",")
        let clubs: [Community]? = try? await client.call(
            "groups.getById",
            params: ["group_ids": ids, "fields": "photo_100,photo_50"]
        )
        for g in clubs ?? [] {
            authors[-g.groupID] = WallViewModel.Author(name: g.name, avatar: g.avatarURL)
        }
    }

    func send(groupID: Int, topicDBID: Int?, virtualIDGuess: Int, settings: AppSettings) async {
        guard let client = makeClient(settings), canSend, !isSending, let vid = resolvedVID else { return }
        isSending = true
        defer { isSending = false }
        do {
            // from_group=0 — отвечаем от своего имени.
            try await client.execute(
                "board.createComment",
                params: ["group_id": String(groupID), "topic_id": String(vid), "message": text, "from_group": "0"]
            )
            text = ""
            await load(groupID: groupID, topicDBID: topicDBID, virtualIDGuess: virtualIDGuess, settings: settings)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Резолв virtual_id (обход бага API: список отдаёт DB id, а тут нужен virtual_id)

    /// Реальный virtual_id ≥ ранга (guess): удаления сдвигают его только вверх. Поэтому
    /// проверяем guess, а если не совпало — пробуем vid выше по возрастанию.
    private func resolveVID(client: OVKClient, groupID: Int, topicDBID: Int?, guess: Int) async -> Int? {
        // Из ссылки virtual_id известен точно (guess), резолвить не нужно.
        guard let topicDBID else { return guess }
        if await dbID(client, groupID, guess) == topicDBID { return guess }

        let upper = guess + 60
        return await withTaskGroup(of: Int?.self) { group -> Int? in
            for vid in (guess + 1)...upper {
                group.addTask { await self.dbID(client, groupID, vid) == topicDBID ? vid : nil }
            }
            var found: Int?
            for await vid in group {
                if let vid { found = min(found ?? Int.max, vid) }
            }
            return found
        }
    }

    /// Возвращает DB id темы, у которой virtual_id == vid (через board.getTopics?topic_ids=vid).
    private func dbID(_ client: OVKClient, _ groupID: Int, _ vid: Int) async -> Int? {
        let res: ItemsResponse<Topic>? = try? await client.call(
            "board.getTopics",
            params: ["group_id": String(groupID), "topic_ids": String(vid), "count": "10"]
        )
        return res?.items.first?.topicID
    }
}

struct TopicView: View {
    let groupID: Int
    /// nil — когда открыто по ссылке (virtualIDGuess уже точный virtual_id).
    var topicDBID: Int?
    let virtualIDGuess: Int
    let title: String

    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = TopicViewModel()
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            list
            inputBar
        }
        .background(OVK.Palette.background.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.load(groupID: groupID, topicDBID: topicDBID, virtualIDGuess: virtualIDGuess, settings: settings)
        }
    }

    @ViewBuilder
    private var list: some View {
        if model.isLoading && model.comments.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.errorMessage, model.comments.isEmpty {
            ErrorRetry(message: error) {
                Task { await model.load(groupID: groupID, topicDBID: topicDBID, virtualIDGuess: virtualIDGuess, settings: settings) }
            }
        } else if model.comments.isEmpty {
            Text("Пока нет сообщений")
                .foregroundColor(OVK.Palette.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.comments) { comment in
                        // from_id у board-комментов от имени группы приходит без минуса —
                        // берём скорректированный id (см. TopicViewModel.effectiveAuthorID).
                        let authorID = model.effectiveAuthorID(comment)
                        CommentRow(
                            comment: comment,
                            author: model.authors[authorID],
                            authorID: authorID,
                            ownerID: -groupID,
                            onReply: {
                                model.prefillReply(to: authorID, name: model.authors[authorID]?.name)
                                inputFocused = true
                            }
                        )
                            .background(OVK.Palette.card)
                        Divider().padding(.leading, 58)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Сообщение…", text: $model.text)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
            if model.isSending {
                ProgressView()
            } else {
                Button {
                    Task { await model.send(groupID: groupID, topicDBID: topicDBID, virtualIDGuess: virtualIDGuess, settings: settings) }
                } label: {
                    Image(systemName: "paperplane.fill").foregroundColor(OVK.Palette.primary)
                }
                .disabled(!model.canSend)
            }
        }
        .padding(8)
        .background(OVK.Palette.card)
    }
}
