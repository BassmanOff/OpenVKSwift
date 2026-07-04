import SwiftUI

/// Переписка с одним собеседником: messages.getHistory + messages.send.
/// Новые сообщения подтягиваются периодическим опросом, пока экран открыт
/// (LongPoll у OpenVK есть — можно перейти на него позже).
@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var messages: [Message] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var text = ""
    @Published var isSending = false

    var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func client(_ settings: AppSettings) -> OVKClient? {
        guard let token = settings.token else { return nil }
        return OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
    }

    func load(peerID: Int, settings: AppSettings) async {
        guard let client = client(settings) else { return }
        // Мгновенно показываем закэшированную переписку (в т.ч. офлайн), потом обновляем.
        if messages.isEmpty, let cached = Self.loadCache(peer: peerID) {
            messages = cached
        }
        isLoading = messages.isEmpty
        errorMessage = nil
        defer { isLoading = false }
        do {
            // rev=0 — новые первыми; на экране разворачиваем в хронологию.
            let res: HistoryResponse = try await client.call(
                "messages.getHistory",
                params: ["peer_id": String(peerID), "count": "100"]
            )
            messages = res.items.reversed()
            Self.saveCache(messages, peer: peerID)
        } catch {
            if error.isCancellation { return }
            // Оффлайн/ошибка: кэш остаётся без сообщения об ошибке.
            if messages.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    /// Тихий опрос новых сообщений (без спиннеров/ошибок).
    /// Оптимизация для медленного сервера: сперва лёгкая проверка «хвоста» (20 сообщений);
    /// полную страницу тянем, только если хвост изменился.
    func poll(peerID: Int, settings: AppSettings) async {
        guard let client = client(settings), !isSending else { return }
        let tail: HistoryResponse? = try? await client.call(
            "messages.getHistory",
            params: ["peer_id": String(peerID), "count": "20"]
        )
        guard let tailFresh = tail?.items.reversed() else { return }
        let tailArray = Array(tailFresh)
        let currentTail = Array(messages.suffix(tailArray.count))
        guard tailArray != currentTail else { return } // изменений нет — 5 КБ вместо 25

        let res: HistoryResponse? = try? await client.call(
            "messages.getHistory",
            params: ["peer_id": String(peerID), "count": "100"]
        )
        guard let fresh = res?.items.reversed() else { return }
        let freshArray = Array(fresh)
        if freshArray != messages {
            messages = freshArray
            Self.saveCache(freshArray, peer: peerID)
        }
    }

    // MARK: - Дисковый кэш последней страницы переписки

    private static func cacheURL(peer: Int) -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("chat_cache_\(peer).json")
    }

    private static func saveCache(_ messages: [Message], peer: Int) {
        if let data = try? JSONEncoder().encode(messages) {
            try? data.write(to: cacheURL(peer: peer), options: .atomic)
        }
    }

    private static func loadCache(peer: Int) -> [Message]? {
        guard let data = try? Data(contentsOf: cacheURL(peer: peer)) else { return nil }
        return try? JSONDecoder().decode([Message].self, from: data)
    }

    /// Стирает кэши всех переписок (при выходе из аккаунта — это личные данные).
    static func clearAllCaches() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let files = (try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("chat_cache_") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func send(peerID: Int, settings: AppSettings) async {
        guard let client = client(settings), canSend, !isSending else { return }
        isSending = true
        defer { isSending = false }
        do {
            let _: Int = try await client.call(
                "messages.send",
                params: ["peer_id": String(peerID), "message": text]
            )
            text = ""
            await load(peerID: peerID, settings: settings)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ChatView: View {
    let peerID: Int
    let title: String

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var longPoll: LongPollService
    @StateObject private var model = ChatViewModel()
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            list
            inputBar
        }
        .background(OVK.Palette.background.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        // Мгновенная доставка: LongPoll сигналит о новом сообщении в этом диалоге.
        .onReceive(longPoll.newMessage) { event in
            guard event.peerID == peerID else { return }
            Task {
                await model.poll(peerID: peerID, settings: settings)
                // Сервер отдаёт только САМОЕ СВЕЖЕЕ событие: при очереди сообщений
                // «средние» проглатываются. Контрольный опрос подбирает хвост очереди.
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                await model.poll(peerID: peerID, settings: settings)
            }
        }
        .task {
            await model.load(peerID: peerID, settings: settings)
            // Резервный опрос: при живом LongPoll — раз в 60с (нужен только ради своих
            // сообщений с других устройств, о них LongPoll молчит); при мёртвом — раз в 30с.
            var lastPoll = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                let interval: TimeInterval = longPoll.isHealthy ? 60 : 30
                if Date().timeIntervalSince(lastPoll) >= interval - 1 {
                    await model.poll(peerID: peerID, settings: settings)
                    lastPoll = Date()
                }
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        if model.isLoading && model.messages.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.errorMessage, model.messages.isEmpty {
            ErrorRetry(message: error) { Task { await model.load(peerID: peerID, settings: settings) } }
        } else if model.messages.isEmpty {
            Text("Напишите первое сообщение")
                .foregroundColor(OVK.Palette.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.messages) { message in
                            bubble(message)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .onAppear { scrollToBottom(proxy, animated: false) }
                .onChange(of: model.messages.last?.id) { _ in
                    scrollToBottom(proxy, animated: true)
                }
            }
        }
    }

    private func bubble(_ message: Message) -> some View {
        HStack {
            if message.isOut { Spacer(minLength: 40) }
            VStack(alignment: .trailing, spacing: 2) {
                Text(linkifiedText(message.text))
                    .font(.subheadline)
                    .foregroundColor(message.isOut ? .white : OVK.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.timeText(message.date))
                    .font(.caption2)
                    .foregroundColor(message.isOut ? .white.opacity(0.7) : OVK.Palette.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(message.isOut ? OVK.Palette.primary : OVK.Palette.card)
            )
            if !message.isOut { Spacer(minLength: 40) }
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
                    Task { await model.send(peerID: peerID, settings: settings) }
                } label: {
                    Image(systemName: "paperplane.fill").foregroundColor(OVK.Palette.primary)
                }
                .disabled(!model.canSend)
            }
        }
        .padding(8)
        .background(OVK.Palette.card)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let lastID = model.messages.last?.id else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if animated {
                withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
            } else {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }

    // DateFormatter дорог в создании — держим статически (вызывается в каждом пузыре).
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static func timeText(_ timestamp: Int) -> String {
        timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }
}
