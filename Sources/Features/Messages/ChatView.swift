import SwiftUI
import UIKit

/// Реакция на сообщение: эмодзи + id СКРЫТОГО сообщения-носителя в истории OpenVK.
/// messageID нужен, чтобы смену реакции делать через messages.edit, а снятие — через
/// messages.delete (не плодя новых сообщений). 0 = оптимистичная, ещё не подтверждена
/// сервером (id узнаем после reload).
struct MessageReaction: Hashable {
    let emoji: String
    let messageID: Int
}

/// Переписка с одним собеседником: messages.getHistory + messages.send.
/// Новые сообщения подтягиваются периодическим опросом, пока экран открыт
/// (LongPoll у OpenVK есть — можно перейти на него позже).
@MainActor
final class ChatViewModel: ObservableObject {
    /// Реальные сообщения (сообщения-реакции отфильтрованы в reactions).
    @Published private(set) var messages: [Message] = []
    /// Оптимистичные исходящие: показаны мгновенно, до подтверждения сервером.
    @Published private(set) var pending: [PendingMessage] = []
    /// Реакции: id целевого сообщения → (id автора → реакция). Последняя по истории побеждает.
    @Published private(set) var reactions: [Int: [Int: MessageReaction]] = [:]
    /// До какого id собеседник прочитал наши сообщения (для двойной галочки).
    @Published private(set) var outRead: Int = 0
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var text = ""

    private var isSending = false
    private var raw: [Message] = []   // сырьё (с реакциями) для кэша и пересчёта
    private let cacheScope = AccountCacheScope.current()

    // MARK: Пагинация истории
    /// Первая страница — маленькая (быстрое открытие); старое догружается прокруткой вверх.
    private static let initialPageSize = 30
    private static let olderPageSize = 30
    /// Идёт догрузка старой истории (защита от дублей/гонок при быстрой прокрутке).
    private(set) var isLoadingOlder = false
    /// false — история исчерпана (сервер вернул неполную/пустую страницу).
    private(set) var canLoadOlder = true
    /// Компенсация сдвига offset: пока листали, пришли новые сообщения → страница по
    /// старому offset вернула сплошные дубли — следующий запрос копает глубже.
    private var olderOffsetBias = 0

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
    /// `interpretReactions == false` (тумблер отладки) — payload НЕ интерпретируем: скрытые
    /// сообщения-реакции показываются как обычный текст (как в веб-версии OpenVK).
    private func process(_ items: [Message], interpretReactions: Bool) {
        raw = items
        var real: [Message] = []
        var reacts: [Int: [Int: MessageReaction]] = [:]
        for m in items {
            if interpretReactions, let (target, emoji, remove) = HiddenReaction.decode(m.text) {
                // remove-флаг больше не отправляем (снятие = messages.delete), но СТАРЫЕ
                // истории содержат такие сообщения — реплей должен их учитывать.
                if remove { reacts[target]?.removeValue(forKey: m.fromID) }
                else { reacts[target, default: [:]][m.fromID] = MessageReaction(emoji: emoji, messageID: m.id) }
            } else {
                real.append(m)
            }
        }
        messages = real
        reactions = reacts
    }

    /// Склейка догруженной истории со свежим «хвостом» с сервера: свежая страница — истина
    /// для новейших сообщений, а СТАРАЯ история (догруженная пагинацией или из кэша, id
    /// меньше первого свежего) сохраняется перед ней. Пустой хвост = переписка пуста.
    private static func merge(existing: [Message], freshTail: [Message]) -> [Message] {
        guard let minFresh = freshTail.first?.id else { return [] }
        return existing.filter { $0.id < minFresh } + freshTail
    }

    func load(peerID: Int, settings: AppSettings) async {
        guard let client = client(settings) else { return }
        // Мгновенно показываем закэшированную переписку (в т.ч. офлайн), потом обновляем.
        // outRead восстанавливаем ИЗ КЭША ДО process: история и прочитанность публикуются
        // в одном тике → первый рендер сразу с верными галочками (без «одна → две»).
        if messages.isEmpty, pending.isEmpty, let cached = loadCache(peer: peerID) {
            if let cachedRead = loadReadCache(peer: peerID) { outRead = cachedRead }
            process(cached, interpretReactions: settings.enableCustomReactions)
        }
        isLoading = messages.isEmpty
        errorMessage = nil
        defer { isLoading = false }
        do {
            // rev=0 — новые первыми; на экране разворачиваем в хронологию.
            // Маленькая первая страница = быстрое открытие; старое догрузит прокрутка.
            let res: HistoryResponse = try await client.call(
                "messages.getHistory",
                params: ["peer_id": String(peerID), "count": String(Self.initialPageSize)]
            )
            // out_read тянем ДО публикации истории: оба await завершены → outRead и
            // сообщения публикуются в одном тике → ячейки не перерисовываются со
            // «отправлено» на «прочитано» после первого рендера.
            let read = await fetchReadStateValue(peerID: peerID, settings: settings)
            if let read {
                outRead = read
                saveReadCache(read, peer: peerID)
            }
            let freshPage = Array(res.items.reversed())
            process(Self.merge(existing: raw, freshTail: freshPage),
                    interpretReactions: settings.enableCustomReactions)
            saveCache(raw, peer: peerID)
            if freshPage.count < Self.initialPageSize { canLoadOlder = false } // вся история уже тут
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
        if let tailFresh = tail?.items.reversed() {
            let tailArray = Array(tailFresh)
            let currentTail = Array(raw.suffix(tailArray.count))
            if tailArray != currentTail { // хвост изменился — тянем полную страницу
                let res: HistoryResponse? = try? await client.call(
                    "messages.getHistory",
                    params: ["peer_id": String(peerID), "count": "100"]
                )
                if let fresh = res?.items.reversed() {
                    // merge: свежий хвост НЕ выбрасывает историю, догруженную пагинацией.
                    let merged = Self.merge(existing: raw, freshTail: Array(fresh))
                    if merged != raw {
                        process(merged, interpretReactions: settings.enableCustomReactions)
                        saveCache(raw, peer: peerID)
                    }
                }
            }
        }
        await fetchReadState(peerID: peerID, settings: settings)
    }

    /// МГНОВЕННАЯ вставка события LongPoll — БЕЗ ожидания перезагрузки истории с сервера
    /// (раньше сообщение показывалось только после 1-2 сетевых раундтрипов poll'а — на
    /// медленном сервере это и были «несколько секунд задержки»). id у события настоящий,
    /// серверный → фоновая синхронизация (poll) потом дедуплицирует по id и сверит поля.
    func applyIncoming(messageID: Int, peerID: Int, text: String, flags: Int, time: Int,
                       settings: AppSettings) {
        guard !raw.contains(where: { $0.id == messageID }) else {
            #if DEBUG
            print("[ViewModel] \(debugNow()) applyIncoming: id=\(messageID) уже есть — пропуск")
            #endif
            return
        }
        let myID = settings.userID ?? 0
        let isOut = flags & 2 != 0    // наше сообщение с другого устройства
        let message = Message(
            id: messageID,
            fromID: isOut ? myID : peerID,
            date: time > 0 ? time : Int(Date().timeIntervalSince1970),
            text: text,
            isOut: isOut
        )

        if settings.enableCustomReactions,
           let (target, emoji, remove) = HiddenReaction.decode(text) {
            // Реакция собеседника прилетела LongPoll'ом — рисуем чип сразу.
            if remove { reactions[target]?.removeValue(forKey: message.fromID) }
            else { reactions[target, default: [:]][message.fromID] = MessageReaction(emoji: emoji, messageID: messageID) }
            raw.append(message)
        } else {
            raw.append(message)
            messages.append(message)
        }
        saveCache(raw, peer: peerID)
        #if DEBUG
        print("[ViewModel] \(debugNow()) applyIncoming: id=\(messageID) вставлено (messages=\(messages.count))")
        #endif
    }

    /// Догрузка СТАРОЙ истории (юзер докрутил до визуального верха инвертированного списка).
    /// offset-пагинация: сервер отдаёт новейшие первыми, offset = сколько уже загружено.
    /// В инвертированном списке старые строки добавляются В КОНЕЦ контента → contentOffset
    /// и рамки видимых ячеек не меняются — позиция прокрутки сохраняется сама собой.
    func loadOlder(peerID: Int, settings: AppSettings) async {
        guard canLoadOlder, !isLoadingOlder, !raw.isEmpty,
              let client = client(settings) else { return }
        isLoadingOlder = true                      // ставится ДО await → дубли отсечены
        defer { isLoadingOlder = false }

        let res: HistoryResponse? = try? await client.call(
            "messages.getHistory",
            params: ["peer_id": String(peerID),
                     "count": String(Self.olderPageSize),
                     "offset": String(raw.count + olderOffsetBias)]
        )
        guard let items = res?.items else { return }        // сеть упала — можно повторить
        if items.isEmpty { canLoadOlder = false; return }    // история исчерпана

        // Дедуп по id: пока листали, могли прийти новые сообщения → offset сдвинулся.
        let older = Array(items.reversed())
        let known = Set(raw.map(\.id))
        let fresh = older.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else {
            olderOffsetBias += items.count                   // сплошные дубли — копаем глубже
            return
        }
        olderOffsetBias = 0
        process(fresh + raw, interpretReactions: settings.enableCustomReactions)
        saveCache(raw, peer: peerID)
        if items.count < Self.olderPageSize { canLoadOlder = false }
    }

    /// Тянет out_read (до какого нашего сообщения собеседник прочитал), НЕ публикуя —
    /// вызывающий сам решает, когда обновить состояние (в load — вместе с историей).
    private func fetchReadStateValue(peerID: Int, settings: AppSettings) async -> Int? {
        guard let client = client(settings) else { return nil }
        struct Resp: Decodable {
            struct Item: Decodable {
                let outRead: Int?
                enum CodingKeys: String, CodingKey { case outRead = "out_read" }
            }
            let items: [Item]
        }
        let r: Resp? = try? await client.call(
            "messages.getConversationsById",
            params: ["peer_ids": String(peerID)]
        )
        return r?.items.first?.outRead
    }

    /// out_read с публикацией и обновлением кэша — для poll/reloadAfterSend (экран уже
    /// стабилен, смена галочек там — настоящее живое событие, не мерцание загрузки).
    private func fetchReadState(peerID: Int, settings: AppSettings) async {
        if let value = await fetchReadStateValue(peerID: peerID, settings: settings) {
            outRead = value
            saveReadCache(value, peer: peerID)
        }
    }

    // MARK: - Дисковый кэш последней страницы переписки

    private func cacheURL(peer: Int) -> URL {
        cacheScope.file("chat_cache_\(peer).json")
    }

    private func saveCache(_ messages: [Message], peer: Int) {
        if let data = try? JSONEncoder().encode(messages) {
            try? data.write(to: cacheURL(peer: peer), options: .atomic)
        }
    }

    private func loadCache(peer: Int) -> [Message]? {
        guard let data = try? Data(contentsOf: cacheURL(peer: peer)) else { return nil }
        return try? JSONDecoder().decode([Message].self, from: data)
    }

    // Кэш out_read — отдельным крошечным файлом (формат кэша сообщений не меняем):
    // холодное открытие из кэша сразу рисует ПРАВИЛЬНЫЕ галочки, без «одна → две».
    private func readCacheURL(peer: Int) -> URL {
        cacheScope.file("chat_read_\(peer).json")
    }

    private func saveReadCache(_ value: Int, peer: Int) {
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: readCacheURL(peer: peer), options: .atomic)
        }
    }

    private func loadReadCache(peer: Int) -> Int? {
        guard let data = try? Data(contentsOf: readCacheURL(peer: peer)) else { return nil }
        return try? JSONDecoder().decode(Int.self, from: data)
    }

    /// Стирает кэши всех переписок (при выходе из аккаунта — это личные данные).
    static func clearAllCaches() {
        AccountCacheScope.current().removeFiles(prefixes: ["chat_cache_", "chat_read_"])
    }

    func send(peerID: Int, settings: AppSettings) async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        text = ""
        await sendBody(body, peerID: peerID, settings: settings)
    }

    /// Загружает фото в отдельный альбом отправителя (getHistory не возвращает вложения ЛС)
    /// и шлёт прямую ссылку на .jpeg обычным сообщением — на приёме она рисуется фото-баблом.
    /// `onProgress`/`onError` — для тоста в UI (загрузка идёт заметное время).
    func sendPhoto(_ image: UIImage, peerID: Int, settings: AppSettings,
                   onProgress: (String) -> Void, onError: (String) -> Void) async {
        guard let token = settings.serviceAccountToken else {
            onError("Сервисный аккаунт для фото не настроен")
            return
        }
        guard let userID = settings.userID, userID > 0 else {
            onError("Не удалось определить отправителя фото")
            return
        }
        guard let data = image.normalizedOrientation().jpegData(compressionQuality: 0.9) else { return }
        let client = OVKClient(instance: .openvkOrg, token: token, apiVersion: settings.apiVersion)
        onProgress("Загрузка фото…")
        do {
            let photo: Photo?
            do {
                photo = try await client.uploadPhotoToAlbum(
                    jpeg: data,
                    albumID: try await ensurePMAlbum(client: client, settings: settings, userID: userID)
                )
            } catch OVKError.api(let code, _) where code == 114 {
                // Сохранённый альбом удалён на сайте — сбрасываем кэш, пересоздаём, повторяем раз.
                settings.setServicePMPhotoAlbumID(nil, for: userID)
                photo = try await client.uploadPhotoToAlbum(
                    jpeg: data,
                    albumID: try await ensurePMAlbum(client: client, settings: settings, userID: userID)
                )
            }
            guard let photo, let url = photo.bestURL,
                  let reference = ServicePhotoReference(ownerID: photo.ownerID, photoID: photo.photoID) else {
                onError("Не удалось загрузить фото")
                return
            }
            let messageID = await sendBody(
                url.absoluteString, peerID: peerID, settings: settings, servicePhoto: reference
            )
            if messageID == nil {
                // Сообщение не ушло — загруженное фото не должно остаться сиротой.
                try? await client.execute("photos.delete", params: [
                    "owner_id": String(reference.ownerID), "photo_id": String(reference.photoID)
                ])
            }
        } catch {
            if error.isCancellation { return }
            onError(error.localizedDescription)
        }
    }

    /// id альбома фото-ЛС: берём сохранённый или создаём. Если сохранённый протух (альбом
    /// удалили на сайте) — upload упадёт кодом 114, тогда сбрасываем кэш и пересоздаём (один раз).
    private func ensurePMAlbum(client: OVKClient, settings: AppSettings, userID: Int) async throws -> Int {
        if let id = settings.servicePMPhotoAlbumID(for: userID) { return id }
        let title = "_OVK_iOS_PM_id\(userID)"
        let albums: ItemsResponse<Album> = try await client.call(
            "photos.getAlbums", params: ["need_system": "0", "count": "1000"]
        )
        if let album = albums.items.first(where: { $0.title == title }) {
            settings.setServicePMPhotoAlbumID(album.albumID, for: userID)
            return album.albumID
        }
        // ponytail: две одновременные первые загрузки одного пользователя могут создать дубликаты;
        // backend позже сериализует создание альбома.
        let album = try await client.createPhotoAlbum(
            title: title,
            description: "Фото из личных сообщений пользователя id\(userID) (OVK iOS)"
        )
        settings.setServicePMPhotoAlbumID(album.albumID, for: userID)
        return album.albumID
    }

    /// В истории ЛС нет сериализованных аудио-вложений, поэтому шлём страницу выбранного
    /// трека и подпись: на компьютере запись можно открыть и добавить в коллекцию.
    func sendAudio(_ track: Audio, peerID: Int, settings: AppSettings) async {
        let payload = track.messageAttachmentText(webURL: settings.instance.webURL)
        await sendBody(payload, peerID: peerID, settings: settings)
    }

    @discardableResult
    private func sendBody(_ body: String, peerID: Int, settings: AppSettings,
                          servicePhoto: ServicePhotoReference? = nil) async -> Int? {
        guard let client = client(settings), !body.isEmpty else { return nil }
        // Мгновенно показываем сообщение как «отправляется» (оптимистично).
        let optimistic = PendingMessage(text: body, date: Int(Date().timeIntervalSince1970))
        pending.append(optimistic)
        isSending = true
        defer { isSending = false }
        do {
            let serverID: Int = try await client.call(
                "messages.send",
                params: ["peer_id": String(peerID), "message": body]
            )
            #if DEBUG
            print("[Send] \(debugNow()) отправлено: serverID=\(serverID) text=\"\(body.prefix(30))\"")
            #endif
            if let servicePhoto, let userID = settings.userID {
                settings.setServicePMPhotoReference(servicePhoto, for: serverID, userID: userID)
            }

            // ЗАМЕНЯЕМ оптимистичное настоящим ДО reload — чтобы ни один промежуточный
            // reloadFromModel / DispatchQueue.main.async не застал оба в одном снапшоте.
            // (Корень дубля: process() внутри reloadAfterSend публикует серверное сообщение,
            //  a pending.removeAll ещё не выполнился → rows = serverMsg + pending.)
            pending.removeAll { $0.id == optimistic.id }
            let myID = settings.userID ?? 0
            let real = Message(id: serverID, fromID: myID, date: optimistic.date, text: body, isOut: true)
            if settings.enableCustomReactions,
               let (target, emoji, remove) = HiddenReaction.decode(body) {
                if remove { reactions[target]?.removeValue(forKey: myID) }
                else { reactions[target, default: [:]][myID] = MessageReaction(emoji: emoji, messageID: serverID) }
                raw.append(real)
            } else {
                raw.append(real)
                messages.append(real)
            }
            saveCache(raw, peer: peerID)
            #if DEBUG
            print("[Send] \(debugNow()) оптимистичное \(optimistic.id) заменено на m\(serverID) (messages=\(messages.count))")
            #endif

            // Фоновая сверка с сервером: сообщение m(serverID) уже в raw → merge() внутри
            // reloadAfterSend не создаст дубль (merge фильтрует existing.id < minFresh).
            await reloadAfterSend(peerID: peerID, settings: settings)
            return serverID
        } catch {
            // Не отправилось — помечаем крестиком (сообщение остаётся видимым).
            if let i = pending.firstIndex(where: { $0.id == optimistic.id }) { pending[i].failed = true }
            return nil
        }
    }

    private func reloadAfterSend(peerID: Int, settings: AppSettings) async {
        guard let client = client(settings) else { return }
        if let res: HistoryResponse = try? await client.call(
            "messages.getHistory", params: ["peer_id": String(peerID), "count": "100"]
        ) {
            // merge: свежий хвост НЕ выбрасывает историю, догруженную пагинацией.
            process(Self.merge(existing: raw, freshTail: Array(res.items.reversed())),
                    interpretReactions: settings.enableCustomReactions)
            saveCache(raw, peer: peerID)
        }
        await fetchReadState(peerID: peerID, settings: settings)
    }

    /// Реакция на сообщение — как в Telegram, БЕЗ мусора в истории OpenVK:
    /// • добавление — ОДНО новое скрытое сообщение (messages.send);
    /// • смена — messages.edit СУЩЕСТВУЮЩЕГО сообщения-реакции (id тот же, payload новый);
    /// • снятие — messages.delete существующего (remove-сообщения больше не шлём).
    func react(targetID: Int, emoji: String, peerID: Int, settings: AppSettings) async {
        guard let client = client(settings) else { return }
        let myID = settings.userID ?? 0
        let existing = reactions[targetID]?[myID]

        if let existing, existing.emoji == emoji {
            // Тот же эмодзи ещё раз → СНЯТЬ: удаляем сообщение-носитель.
            reactions[targetID]?.removeValue(forKey: myID)                     // оптимистично
            if existing.messageID > 0 {
                _ = try? await client.rawResponse(
                    "messages.delete", params: ["message_ids": String(existing.messageID)]
                )
            }
            // messageID == 0 — реакция ещё не подтверждена сервером; reload ниже покажет правду.
        } else if let existing, existing.messageID > 0 {
            // СМЕНА: редактируем существующее сообщение-реакцию, нового НЕ создаём.
            reactions[targetID, default: [:]][myID] =
                MessageReaction(emoji: emoji, messageID: existing.messageID)   // оптимистично
            let payload = HiddenReaction.encode(targetID: targetID, emoji: emoji, remove: false)
            _ = try? await client.rawResponse(
                "messages.edit",
                params: ["message_id": String(existing.messageID),
                         "peer_id": String(peerID), "message": payload]
            )
        } else {
            // ДОБАВЛЕНИЕ (или смена неподтверждённой): одно новое скрытое сообщение.
            reactions[targetID, default: [:]][myID] =
                MessageReaction(emoji: emoji, messageID: 0)                    // оптимистично
            let payload = HiddenReaction.encode(targetID: targetID, emoji: emoji, remove: false)
            _ = try? await client.rawResponse(
                "messages.send", params: ["peer_id": String(peerID), "message": payload]
            )
        }
        // Подтягиваем историю в raw/кэш: реакция получает настоящий messageID и переживает
        // перезапуск (собственная реакция не приходит через LongPoll — только явным reload).
        await reloadAfterSend(peerID: peerID, settings: settings)
    }

    /// Редактирование своего сообщения (messages.edit).
    func edit(messageID: Int, newText: String, peerID: Int, settings: AppSettings) async {
        let body = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client = client(settings), !body.isEmpty else { return }
        _ = try? await client.rawResponse(
            "messages.edit",
            params: ["message_id": String(messageID), "peer_id": String(peerID), "message": body]
        )
        await reloadAfterSend(peerID: peerID, settings: settings)
    }

    /// Удаление сообщения (messages.delete). Оптимистично убираем из списка.
    func delete(messageID: Int, peerID: Int, settings: AppSettings) async {
        guard let client = client(settings) else { return }
        let userID = settings.userID
        let photo = userID.flatMap { settings.servicePMPhotoReference(for: messageID, userID: $0) }
        messages.removeAll { $0.id == messageID }
        raw.removeAll { $0.id == messageID }
        saveCache(raw, peer: peerID)
        do {
            try await client.execute("messages.delete", params: ["message_ids": String(messageID)])
        } catch {
            return // Сообщение осталось на сервере — фото пока тоже оставляем.
        }
        guard let photo, let userID, let token = settings.serviceAccountToken else { return }
        let serviceClient = OVKClient(instance: .openvkOrg, token: token, apiVersion: settings.apiVersion)
        try? await serviceClient.execute("photos.delete", params: [
            "owner_id": String(photo.ownerID), "photo_id": String(photo.photoID)
        ])
        settings.setServicePMPhotoReference(nil, for: messageID, userID: userID)
    }

    /// Отправляет статус «печатает» собеседнику (messages.setActivity type=typing).
    /// Статус на сервере живёт ~6с — чаще раза в ~4с слать незачем (троттлинг).
    private var lastTypingSent = Date.distantPast
    func sendTyping(peerID: Int, settings: AppSettings) async {
        guard settings.instance.supportsTypingActivity else { return }
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

/// Метка времени с миллисекундами для замера пути «LongPoll → экран».
func debugNow() -> String {
    debugTimeFormatter.string(from: Date())
}

private let debugTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

/// Экран переписки: тонкая SwiftUI-обёртка (навбар, опрос, тосты) вокруг UIKit-контроллера
/// `ChatScreenController` (список UICollectionView + поле ввода + клавиатура + меню действий).
struct ChatView: View {
    let peerID: Int
    let title: String
    var avatarURL: URL? = nil

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var longPoll: LongPollService
    @EnvironmentObject private var photoHero: PhotoHeroCoordinator
    @EnvironmentObject private var library: LibraryManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ChatViewModel()
    /// Свой роутер, а НЕ @Environment(\.openURL): тот резолвится из окружения ChatView САМОГО
    /// (заданного предком — глобальным роутером MainTabView), а .handlesOVKLinks() ниже влияет
    /// только на детей ChatView, не на его собственное чтение environment. Со старым кодом
    /// (openURL из environment) тап по ссылке/карточке записи уходил в ГЛОБАЛЬНЫЙ роутер,
    /// который пушит из корня вкладки «Сообщения» (см. .pushesGlobalLinks в ConversationsView) —
    /// это выталкивало ChatView из стека, и «закрыть» возвращало к списку диалогов, а не в чат.
    @StateObject private var linkRouter = LinkRouter()
    @State private var toast: String?
    @State private var showAttachMenu = false
    @State private var showPhotoPicker = false
    @State private var showCameraPicker = false
    @State private var showAudioPicker = false
    @State private var showPhotoNotice = false
    @State private var openCameraAfterNotice = false

    var body: some View {
        ZStack {
            ChatScreen(model: model, peerID: peerID,
                       onToast: { toast = $0 },
                       onOpenURL: { url in
                           // Внутренние ссылки пушим в стек чата; аудио и внешние URL —
                           // системно, иначе нераспознанный LinkRouter оставлял тап без действия.
                           if !linkRouter.open(url) { UIApplication.shared.open(url) }
                       },
                       onOpenImage: { url, view in
                           // Тот же полноэкранный UIKit-просмотрщик, что в ленте/комментариях.
                           let photo = Photo.remote(url: url)
                           photoHero.registerSource(view, for: photo.id) // закрытие «влетит» обратно
                           photoHero.present(photos: [photo], index: 0, post: nil, from: view)
                       },
                       onAttach: { showAttachMenu = true })
                // Клавиатуру обрабатывает UIKit-контроллер (нативные уведомления).
                .ignoresSafeArea(.keyboard, edges: .bottom)

            if let error = model.errorMessage, model.rows.isEmpty {
                ErrorRetry(message: error) { Task { await model.load(peerID: peerID, settings: settings) } }
            }
        }
        .background(OVK.Palette.background.ignoresSafeArea())
        // Пуш назначений linkRouter — В СТЕК ЭТОГО ЧАТА (см. комментарий у linkRouter выше),
        // а не в корень вкладки. Тот же приём, что .handlesOVKLinks() использует для модалок.
        .background(
            NavigationLink(
                isActive: Binding(
                    get: { linkRouter.destination != nil },
                    set: { if !$0 { linkRouter.destination = nil } }
                )
            ) {
                if let dest = linkRouter.destination {
                    LinkDestinationView(destination: dest).handlesOVKLinks()
                }
            } label: { EmptyView() }
            .hidden()
        )
        .confirmationDialog("Прикрепить", isPresented: $showAttachMenu) {
            Button("Фото") {
                openCameraAfterNotice = false
                if settings.didWarnPMPhoto { showPhotoPicker = true }
                else { showPhotoNotice = true }
            }
            Button("Камера") {
                guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                    toast = "Камера недоступна"
                    return
                }
                openCameraAfterNotice = true
                if settings.didWarnPMPhoto { showCameraPicker = true }
                else { showPhotoNotice = true }
            }
            Button("Аудио") { showAudioPicker = true }
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPicker { image in
                Task {
                    await model.sendPhoto(image, peerID: peerID, settings: settings,
                                          onProgress: { toast = $0 }, onError: { toast = $0 })
                }
            }
        }
        .fullScreenCover(isPresented: $showCameraPicker) {
            CameraPicker { image in
                Task {
                    await model.sendPhoto(image, peerID: peerID, settings: settings,
                                          onProgress: { toast = $0 }, onError: { toast = $0 })
                }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showAudioPicker) {
            AudioAttachPicker { track in
                Task {
                    await model.sendAudio(track, peerID: peerID, settings: settings)
                }
            }
        }
        .alert("Фото в личных сообщениях", isPresented: $showPhotoNotice) {
            Button("Отмена", role: .cancel) {}
            Button("Продолжить") {
                settings.didWarnPMPhoto = true
                if openCameraAfterNotice { showCameraPicker = true }
                else { showPhotoPicker = true }
            }
        } message: {
            Text("OpenVK не возвращает вложения в истории личных сообщений. Отправляемые фото "
                 + "временно сохраняются в отдельном альбоме вашего аккаунта на сервисном аккаунте "
                 + "и доступны по прямой ссылке. "
                 + "Не отправляйте так конфиденциальные изображения.")
        }
        .handlesOVKLinks() // без этого ссылки в сообщениях пушатся в корень вкладки «Сообщения», а не сюда
        .navigationBarTitleDisplayMode(.inline)
        // Своя стрелка без текста: системная подпись то «Назад», то «Сообщения»
        // (iOS обрезает заголовок предыдущего экрана) и съедает место под имя.
        .navigationBarBackButtonHidden(true)
        .toolbar {
            // ВСЕ размеры в тулбаре — АБСОЛЮТНЫЕ (фиксированные шрифты и рамки, никакого
            // Dynamic Type): элементы тулбара замеряются UIKit'ом на ПЕРВОМ кадре до полной
            // прогрузки окружения и перемеряются при первом же re-render (первый publish
            // модели, ~1с). С абсолютными метриками оба замера идентичны — «подрастания»
            // кнопки и аватара после открытия нет. Загрузка картинки размер не меняет:
            // слот аватара жёстко 30×30 при любом состоянии CachedImage.
            ToolbarItem(placement: .navigationBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
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
                        .cornerRadius(OVK.Metrics.compactCornerRadius)
                        // Фиксированный размер шрифта: иначе после анимации перехода имя
                        // «подрастало» и обрезалось. Длинное имя мягко ужимается.
                        Text(title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .frame(maxWidth: 230)
                    .frame(height: 36)
                }
                .buttonStyle(.plain)
            }
        }
        .toast($toast)
        .toast($library.toast)
        // Мгновенная доставка: событие LongPoll вставляется в переписку СРАЗУ (один publish,
        // ~кадр), а серверная сверка идёт следом в фоне (дедуп по id внутри merge/poll).
        .onReceive(longPoll.newMessage) { event in
            guard event.peerID == peerID else { return }
            model.applyIncoming(messageID: event.messageID, peerID: peerID, text: event.text,
                                flags: event.flags, time: event.time, settings: settings)
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

    private func openProfile() {
        _ = linkRouter.open(
            settings.instance.webURL.appendingPathComponent("id\(peerID)")
        ) // пушится в стек этого чата, см. linkRouter
    }
}
