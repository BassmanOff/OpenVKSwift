import SwiftUI
import UIKit

/// Переписка с одним собеседником: messages.getHistory + messages.send.
/// Новые сообщения подтягиваются периодическим опросом, пока экран открыт
/// (LongPoll у OpenVK есть — можно перейти на него позже).
@MainActor
final class ChatViewModel: ObservableObject {
    /// Реальные сообщения (сообщения-реакции отфильтрованы в reactions).
    @Published private(set) var messages: [Message] = []
    /// Оптимистичные исходящие: показаны мгновенно, до подтверждения сервером.
    @Published private(set) var pending: [PendingMessage] = []
    /// Реакции: id целевого сообщения → (id автора реакции → эмодзи). Последняя побеждает.
    @Published private(set) var reactions: [Int: [Int: String]] = [:]
    /// До какого id собеседник прочитал наши сообщения (для двойной галочки).
    @Published private(set) var outRead: Int = 0
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var text = ""

    private var isSending = false
    private var raw: [Message] = []   // сырьё (с реакциями) для кэша и пересчёта

    var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    struct PendingMessage: Identifiable, Hashable {
        let id = UUID()
        let text: String
        let date: Int
        var failed = false
    }

    enum ChatRow: Identifiable, Hashable {
        case message(Message)
        case pending(PendingMessage)
        var id: String {
            switch self {
            case .message(let m): return "m\(m.id)"
            case .pending(let p): return "p\(p.id.uuidString)"
            }
        }
    }

    /// Что рисуем в ленте: реальные сообщения + оптимистичные исходящие в конце.
    var rows: [ChatRow] { messages.map(ChatRow.message) + pending.map(ChatRow.pending) }

    private func client(_ settings: AppSettings) -> OVKClient? {
        guard let token = settings.token else { return nil }
        return OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
    }

    /// Раскладывает сырые сообщения на реальные + реакции.
    private func process(_ items: [Message]) {
        raw = items
        var real: [Message] = []
        var reacts: [Int: [Int: String]] = [:]
        for m in items {
            if let (target, emoji, remove) = HiddenReaction.decode(m.text) {
                if remove { reacts[target]?.removeValue(forKey: m.fromID) }
                else { reacts[target, default: [:]][m.fromID] = emoji }
            } else {
                real.append(m)
            }
        }
        messages = real
        reactions = reacts
    }

    func load(peerID: Int, settings: AppSettings) async {
        guard let client = client(settings) else { return }
        // Мгновенно показываем закэшированную переписку (в т.ч. офлайн), потом обновляем.
        if messages.isEmpty, pending.isEmpty, let cached = Self.loadCache(peer: peerID) {
            process(cached)
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
            process(Array(res.items.reversed()))
            Self.saveCache(raw, peer: peerID)
        } catch {
            if error.isCancellation { return }
            // Оффлайн/ошибка: кэш остаётся без сообщения об ошибке.
            if messages.isEmpty { errorMessage = error.localizedDescription }
        }
        await fetchReadState(peerID: peerID, settings: settings)
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
        if let tailFresh = tail?.items.reversed() {
            let tailArray = Array(tailFresh)
            let currentTail = Array(raw.suffix(tailArray.count))
            if tailArray != currentTail { // хвост изменился — тянем полную страницу
                let res: HistoryResponse? = try? await client.call(
                    "messages.getHistory",
                    params: ["peer_id": String(peerID), "count": "100"]
                )
                if let fresh = res?.items.reversed() {
                    let freshArray = Array(fresh)
                    if freshArray != raw { process(freshArray); Self.saveCache(raw, peer: peerID) }
                }
            }
        }
        await fetchReadState(peerID: peerID, settings: settings)
    }

    /// Тянет out_read (до какого нашего сообщения собеседник прочитал) — двойная галочка.
    private func fetchReadState(peerID: Int, settings: AppSettings) async {
        guard let client = client(settings) else { return }
        struct Resp: Decodable {
            struct Item: Decodable {
                let outRead: Int?
                enum CodingKeys: String, CodingKey { case outRead = "out_read" }
            }
            let items: [Item]
        }
        if let r: Resp = try? await client.call(
            "messages.getConversationsById",
            params: ["peer_ids": String(peerID)]
        ), let value = r.items.first?.outRead {
            outRead = value
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
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client = client(settings), !body.isEmpty else { return }
        text = ""
        // Мгновенно показываем сообщение как «отправляется» (оптимистично).
        let optimistic = PendingMessage(text: body, date: Int(Date().timeIntervalSince1970))
        pending.append(optimistic)
        isSending = true
        defer { isSending = false }
        do {
            let _: Int = try await client.call(
                "messages.send",
                params: ["peer_id": String(peerID), "message": body]
            )
            await reloadAfterSend(peerID: peerID, settings: settings) // подтягиваем настоящее
            pending.removeAll { $0.id == optimistic.id }               // убираем оптимистичное
        } catch {
            // Не отправилось — помечаем крестиком (сообщение остаётся видимым).
            if let i = pending.firstIndex(where: { $0.id == optimistic.id }) { pending[i].failed = true }
        }
    }

    private func reloadAfterSend(peerID: Int, settings: AppSettings) async {
        guard let client = client(settings) else { return }
        if let res: HistoryResponse = try? await client.call(
            "messages.getHistory", params: ["peer_id": String(peerID), "count": "100"]
        ) {
            process(Array(res.items.reversed()))
            Self.saveCache(raw, peer: peerID)
        }
        await fetchReadState(peerID: peerID, settings: settings)
    }

    /// Ставит/снимает реакцию (тоггл) на сообщение — скрытым сообщением-эмодзи.
    func react(targetID: Int, emoji: String, peerID: Int, settings: AppSettings) async {
        guard let client = client(settings) else { return }
        let myID = settings.userID ?? 0
        let remove = reactions[targetID]?[myID] == emoji  // тот же эмодзи ещё раз → снять
        if remove { reactions[targetID]?.removeValue(forKey: myID) }
        else { reactions[targetID, default: [:]][myID] = emoji }
        let payload = HiddenReaction.encode(targetID: targetID, emoji: emoji, remove: remove)
        _ = try? await client.rawResponse(
            "messages.send", params: ["peer_id": String(peerID), "message": payload]
        )
        // Подтягиваем сообщение-реакцию в raw/кэш, чтобы реакция пережила перезапуск
        // (собственная реакция не приходит через LongPoll — только явным reload).
        await reloadAfterSend(peerID: peerID, settings: settings)
    }

    /// Отправляет статус «печатает» собеседнику (messages.setActivity type=typing).
    /// Статус на сервере живёт ~6с — чаще раза в ~4с слать незачем (троттлинг).
    private var lastTypingSent = Date.distantPast
    func sendTyping(peerID: Int, settings: AppSettings) async {
        guard let client = client(settings) else { return }
        guard Date().timeIntervalSince(lastTypingSent) > 4 else { return }
        lastTypingSent = Date()
        // peer_id и user_id — для 1-на-1 диалога это один и тот же id собеседника.
        _ = try? await client.rawResponse(
            "messages.setActivity",
            params: ["peer_id": String(peerID), "user_id": String(peerID), "type": "typing"]
        )
    }
}

struct ChatView: View {
    let peerID: Int
    let title: String
    var avatarURL: URL? = nil

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var longPoll: LongPollService
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ChatViewModel()

    /// Нижняя граница экрана диалога (глобальные координаты) и верх клавиатуры —
    /// их пересечение = насколько клавиатура перекрывает диалог. Считаем сами, т.к.
    /// таб-бар в MainTabView отключает системный keyboard-avoidance (.ignoresSafeArea).
    @State private var containerMaxY: CGFloat = 0
    @State private var keyboardTop: CGFloat = .greatestFiniteMagnitude
    /// Длительность анимации клавиатуры (из системного уведомления) — ею же анимируем
    /// сдвиг и прокрутку, иначе прокрутка «отстаёт» от подъёма клавиатуры.
    @State private var keyboardAnim: Double = 0.25
    @State private var toast: String?
    /// id сообщения, для которого открыта панель выбора реакции (long-press).
    @State private var reactionTargetID: Int?
    private var keyboardInset: CGFloat { max(0, containerMaxY - keyboardTop) }

    private let bottomAnchor = "chat_bottom_anchor"

    var body: some View {
        VStack(spacing: 0) {
            list
            inputBar
        }
        .overlay(reactionPicker)
        .padding(.bottom, keyboardInset) // приподнимаем диалог над клавиатурой
        .background(
            // Замер нижней границы диалога (без учёта padding — оно только внутри).
            GeometryReader { geo in
                Color.clear
                    .onAppear { containerMaxY = geo.frame(in: .global).maxY }
                    .onChange(of: geo.frame(in: .global).maxY) { containerMaxY = $0 }
            }
        )
        .background(OVK.Palette.background.ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            keyboardAnim = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
            // Тем же таймингом, что и клавиатура — сдвиг диалога синхронен с ней.
            withAnimation(.easeOut(duration: keyboardAnim)) { keyboardTop = frame.minY }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { note in
            let d = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
            withAnimation(.easeOut(duration: d)) { keyboardTop = .greatestFiniteMagnitude }
        }
        .navigationBarTitleDisplayMode(.inline)
        // Своя стрелка без текста: системная подпись то «Назад», то «Сообщения»
        // (iOS обрезает заголовок предыдущего экрана) и съедает место под имя.
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.backward")
                        .font(.body.weight(.semibold))
                        .foregroundColor(OVK.Palette.primary)
                }
            }
            // Аватар + имя по центру — тап открывает профиль собеседника.
            ToolbarItem(placement: .principal) {
                Button { openProfile() } label: {
                    HStack(spacing: 8) {
                        CachedImage(url: avatarURL) {
                            ZStack {
                                OVK.Palette.background
                                Image(systemName: "person.crop.circle").foregroundColor(OVK.Palette.textSecondary)
                            }
                        }
                        .frame(width: 30, height: 30)
                        .clipShape(Circle())
                        // ФИКСИРОВАННЫЙ размер шрифта (не Dynamic Type .headline): иначе
                        // после анимации перехода имя «подрастало» и обрезалось. Длинное
                        // имя мягко ужимается вместо резкого обрезания.
                        Text(title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(OVK.Palette.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .frame(maxWidth: 230)
                }
                .buttonStyle(.plain)
            }
        }
        .toast($toast)
        // Пользователь печатает — сообщаем собеседнику (троттлинг внутри модели).
        .onChange(of: model.text) { newValue in
            if !newValue.isEmpty {
                Task { await model.sendTyping(peerID: peerID, settings: settings) }
            }
        }
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
        if model.isLoading && model.rows.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.errorMessage, model.rows.isEmpty {
            ErrorRetry(message: error) { Task { await model.load(peerID: peerID, settings: settings) } }
        } else if model.rows.isEmpty {
            Text("Напишите первое сообщение")
                .foregroundColor(OVK.Palette.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.rows) { row in
                            bubble(row)
                                .id(row.id)
                        }
                        // Якорь низа: скроллим ровно к нему — надёжнее, чем к последнему
                        // пузырю (в LazyVStack его высота на первом кадре ещё не известна).
                        Color.clear.frame(height: 1).id(bottomAnchor)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                // Тап по переписке закрывает клавиатуру (как в Telegram). simultaneous —
                // не мешает прокрутке и тапам по ссылкам в сообщениях.
                .simultaneousGesture(TapGesture().onEnded { hideKeyboard() })
                // Открытие — всегда в самый низ (к последним сообщениям).
                .onAppear { scrollToBottom(proxy, animation: nil) }
                // Пришли/загрузились сообщения (в т.ч. кэш→сеть) — к низу.
                .onChange(of: model.rows.count) { _ in scrollToBottom(proxy, animation: .default) }
                // Клавиатура: прокрутка ТЕМ ЖЕ таймингом, что и её подъём (синхронно).
                .onChange(of: keyboardInset) { inset in
                    if inset > 0 { scrollToBottom(proxy, animation: .easeOut(duration: keyboardAnim), retry: false) }
                }
            }
        }
    }

    @ViewBuilder
    private func bubble(_ row: ChatViewModel.ChatRow) -> some View {
        switch row {
        case .message(let m):
            messageBubble(text: m.text, date: m.date, isOut: m.isOut,
                          status: m.isOut ? (m.id <= model.outRead ? .read : .sent) : nil,
                          reactions: model.reactions[m.id], targetID: m.id)
        case .pending(let p):
            messageBubble(text: p.text, date: p.date, isOut: true,
                          status: p.failed ? .failed : .sending,
                          reactions: nil, targetID: nil)
        }
    }

    private enum Delivery { case sending, sent, read, failed }

    private func messageBubble(text: String, date: Int, isOut: Bool, status: Delivery?,
                               reactions: [Int: String]?, targetID: Int?) -> some View {
        HStack {
            if isOut { Spacer(minLength: 40) }
            VStack(alignment: isOut ? .trailing : .leading, spacing: 3) {
                // Сам пузырь.
                VStack(alignment: .trailing, spacing: 2) {
                    Text(linkifiedText(text))
                        .font(.subheadline)
                        .foregroundColor(isOut ? .white : OVK.Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 3) {
                        Text(Self.timeText(date))
                            .font(.caption2)
                            .foregroundColor(isOut ? .white.opacity(0.7) : OVK.Palette.textSecondary)
                        if isOut, let status { deliveryMark(status) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isOut ? OVK.Palette.primary : OVK.Palette.card)
                )
                // Long-press по реальному сообщению → выбор реакции.
                .onLongPressGesture(minimumDuration: 0.4) {
                    if let targetID {
                        hideKeyboard()
                        withAnimation(.spring(response: 0.3)) { reactionTargetID = targetID }
                    }
                }

                // Чипы реакций под пузырём.
                if let reactions, !reactions.isEmpty {
                    reactionChips(reactions, isOut: isOut, targetID: targetID)
                }
            }
            if !isOut { Spacer(minLength: 40) }
        }
    }

    /// Галочки статуса: часы — отправляется, одна — отправлено, две — прочитано, «!» — ошибка.
    @ViewBuilder
    private func deliveryMark(_ status: Delivery) -> some View {
        switch status {
        case .sending:
            Image(systemName: "clock").font(.system(size: 9)).foregroundColor(.white.opacity(0.7))
        case .sent:
            Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.75))
        case .read:
            ZStack {
                Image(systemName: "checkmark").offset(x: -2)
                Image(systemName: "checkmark").offset(x: 2)
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.white)
        case .failed:
            Image(systemName: "exclamationmark.circle").font(.system(size: 9))
                .foregroundColor(.yellow)
        }
    }

    /// Реакции под пузырём (эмодзи + счётчик; моя — подсвечена).
    private func reactionChips(_ reactions: [Int: String], isOut: Bool, targetID: Int?) -> some View {
        let myID = settings.userID ?? 0
        // Группируем: эмодзи → (счётчик, моя ли).
        var groups: [(emoji: String, count: Int, mine: Bool)] = []
        for (fromID, emoji) in reactions {
            if let idx = groups.firstIndex(where: { $0.emoji == emoji }) {
                groups[idx].count += 1
                if fromID == myID { groups[idx].mine = true }
            } else {
                groups.append((emoji, 1, fromID == myID))
            }
        }
        return HStack(spacing: 4) {
            ForEach(groups, id: \.emoji) { g in
                Button {
                    if let targetID {
                        Task { await model.react(targetID: targetID, emoji: g.emoji, peerID: peerID, settings: settings) }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text(g.emoji).font(.system(size: 13))
                        if g.count > 1 { Text("\(g.count)").font(.caption2).foregroundColor(OVK.Palette.textSecondary) }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(g.mine ? OVK.Palette.primary.opacity(0.18) : OVK.Palette.card)
                    )
                    .overlay(Capsule().stroke(g.mine ? OVK.Palette.primary.opacity(0.5) : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Всплывающая панель выбора реакции (по long-press).
    @ViewBuilder
    private var reactionPicker: some View {
        if let targetID = reactionTargetID {
            ZStack {
                Color.black.opacity(0.25).ignoresSafeArea()
                    .onTapGesture { withAnimation { reactionTargetID = nil } }
                HStack(spacing: 10) {
                    ForEach(HiddenReaction.palette, id: \.self) { emoji in
                        Button {
                            Task { await model.react(targetID: targetID, emoji: emoji, peerID: peerID, settings: settings) }
                            withAnimation { reactionTargetID = nil }
                        } label: {
                            Text(emoji).font(.system(size: 30))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(OVK.Palette.card).shadow(radius: 8))
            }
            .transition(.opacity)
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 4) {
            // Скрепка — вложения (пока в разработке).
            Button { toast = "В разработке…" } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 22))
                    .foregroundColor(OVK.Palette.textSecondary)
                    .frame(width: 38, height: 38)
            }

            // Многострочное поле: Return переносит строку, поле растёт с текстом.
            GrowingTextEditor(text: $model.text, placeholder: "Сообщение…", maxHeight: 120)
                .frame(minHeight: 38)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(OVK.Palette.background)
                )

            // Отправка мгновенная (оптимистичная) — спиннер не нужен, кнопка всегда видна.
            Button {
                // Клавиатуру НЕ закрываем — удобно писать дальше (как в Telegram).
                Task { await model.send(peerID: peerID, settings: settings) }
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 22))
                    .foregroundColor(model.canSend ? OVK.Palette.primary : OVK.Palette.textSecondary)
                    .frame(width: 38, height: 38)
            }
            .disabled(!model.canSend)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(OVK.Palette.card)
    }

    private func openProfile() {
        guard let url = URL(string: "https://openvk.org/id\(peerID)") else { return }
        openURL(url) // перехватывается handlesOVKLinks → профиль внутри приложения
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animation: Animation? = .default, retry: Bool = true) {
        guard !model.rows.isEmpty else { return }
        func go() {
            if let animation {
                withAnimation(animation) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            } else {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        }
        go()
        // Второй проход после раскладки LazyVStack (высота ленивых ячеек на 1-м кадре
        // ещё неизвестна). Для клавиатуры не нужен — там раскладка уже готова.
        if retry { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { go() } }
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

/// UITextView, который сам сообщает свою высоту по контенту (до maxHeight, дальше скроллит).
fileprivate final class SelfSizingTextView: UITextView {
    var maxHeight: CGFloat = 120

    override var intrinsicContentSize: CGSize {
        let fit = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        let over = fit.height > maxHeight
        if isScrollEnabled != over { isScrollEnabled = over } // за пределом — внутренний скролл
        return CGSize(width: UIView.noIntrinsicMetric, height: min(fit.height, maxHeight))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        invalidateIntrinsicContentSize() // ширина стала известна → пересчитать высоту
    }
}

/// Растущее многострочное поле ввода в стиле Telegram: Return переносит строку,
/// высота тянется за текстом, при переполнении скроллит внутри. Работает на iOS 15
/// (TextField(axis:) — только iOS 16+).
fileprivate struct GrowingTextEditor: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var maxHeight: CGFloat = 120

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> SelfSizingTextView {
        let tv = SelfSizingTextView()
        tv.maxHeight = maxHeight
        tv.delegate = context.coordinator
        tv.font = .preferredFont(forTextStyle: .body)
        tv.backgroundColor = .clear
        tv.isScrollEnabled = false
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        tv.setContentCompressionResistancePriority(.required, for: .vertical)
        tv.setContentHuggingPriority(.required, for: .vertical)

        let ph = UILabel()
        ph.text = placeholder
        ph.font = tv.font
        ph.textColor = .placeholderText
        ph.translatesAutoresizingMaskIntoConstraints = false
        tv.addSubview(ph)
        NSLayoutConstraint.activate([
            ph.leadingAnchor.constraint(equalTo: tv.leadingAnchor, constant: 12),
            ph.topAnchor.constraint(equalTo: tv.topAnchor, constant: 8)
        ])
        context.coordinator.placeholder = ph
        return tv
    }

    func updateUIView(_ tv: SelfSizingTextView, context: Context) {
        if tv.text != text {
            tv.text = text
            tv.invalidateIntrinsicContentSize()
        }
        context.coordinator.placeholder?.isHidden = !text.isEmpty
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let parent: GrowingTextEditor
        weak var placeholder: UILabel?
        init(_ parent: GrowingTextEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            placeholder?.isHidden = !textView.text.isEmpty
            textView.invalidateIntrinsicContentSize()
        }
    }
}
