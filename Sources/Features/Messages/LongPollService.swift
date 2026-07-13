import Foundation
import Combine

/// LongPoll-клиент личных сообщений: держит «висящий» запрос к `{host}/nim{userID}`
/// и мгновенно узнаёт о новых сообщениях — вместо периодического опроса.
///
/// Протокол (проверен по MessengerPresenter::renderVKEvents):
/// - адрес/ключ/ts выдаёт `messages.getLongPollServer`;
/// - запрос `{server}?act=a_check&key=&ts=&wait=60&version=3` висит до события
///   или таймаута (сервер капит wait на 60 сек; при таймауте тело ПУСТОЕ);
/// - событие: `{"ts": N, "updates": [[4, msgId, flags, peerId, time, text, ...]]}`;
/// - `{"failed": N}` — ключ протух, нужно взять новый.
/// Полям события не доверяем (сервер сам помечает их TODO) — по событию
/// перезагружаем данные обычным API.
@MainActor
final class LongPollService: ObservableObject {
    /// Событие «новое сообщение»: собеседник, id и текст (текст — для уведомлений).
    struct LPNewMessage {
        let peerID: Int
        let messageID: Int
        let text: String
    }

    /// Событие «новое сообщение в диалоге с peerID».
    let newMessage = PassthroughSubject<LPNewMessage, Never>()

    /// Время последнего успешно завершённого цикла (любой ответ сервера, включая пустой таймаут).
    @Published private(set) var lastCycleAt: Date?

    /// LongPoll жив (цикл завершался недавно) — резервные опросы можно прореживать.
    var isHealthy: Bool {
        guard let last = lastCycleAt else { return false }
        return Date().timeIntervalSince(last) < 90
    }

    private var task: Task<Void, Never>?

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 80 // больше wait=60, чтобы не рубить висящий запрос
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    private struct LPServer: Decodable {
        let key: String
        let server: String
        let ts: Int
    }

    // Дедупликация: сервер ИГНОРИРУЕТ ts и «доигрывает» последнее событие каждому
    // новому запросу, пока оно свежее ~1с (Chandler SignalManager::eventFor) —
    // одно сообщение приходит по 2-3 раза (а при сбоях часов сервера — десятки).
    private var seenIDs: [Int] = []          // кольцевой буфер порядка добавления
    private var seenSet: Set<Int> = []

    /// true, если это событие уже обрабатывали (эхо сервера).
    private func isDuplicate(_ messageID: Int) -> Bool {
        if seenSet.contains(messageID) { return true }
        seenSet.insert(messageID)
        seenIDs.append(messageID)
        if seenIDs.count > 300 {
            seenSet.remove(seenIDs.removeFirst())
        }
        return false
    }

    func start(settings: AppSettings) {
        guard task == nil, settings.isLoggedIn else { return }
        log("старт")
        task = Task { [weak self] in
            await self?.run(settings: settings)
        }
    }

    func stop() {
        guard task != nil else { return }
        log("стоп")
        task?.cancel()
        task = nil
    }

    /// Лог протокола в консоль Xcode (фильтр: [LongPoll]).
    private func log(_ message: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        print("[LongPoll] \(f.string(from: Date())) \(message)")
    }

    // MARK: - Private

    private func run(settings: AppSettings) async {
        var server: LPServer?
        var ts = 0
        var failureStreak = 0
        var echoStreak = 0 // подряд идущие ответы из одних повторов

        while !Task.isCancelled {
            // 1. Получаем/обновляем адрес LP-сервера и ключ.
            if server == nil {
                server = await fetchServer(settings: settings)
                guard let fresh = server else {
                    failureStreak += 1
                    log("getLongPollServer не ответил (попытка \(failureStreak)) — пауза")
                    await sleepWithBackoff(failureStreak)
                    continue
                }
                ts = fresh.ts
                failureStreak = 0
                log("сервер получен: \(fresh.server), ts=\(fresh.ts)")
            }
            guard let lp = server else { continue }

            // 2. Висящий запрос: ответит при событии или по таймауту wait.
            // `server` у OpenVK/VK приходит БЕЗ схемы (напр. "api.openvk.org/nim21510") —
            // клиент сам добавляет http(s). Без этого URLSession падал с «unsupported URL».
            var serverString = lp.server
            if !serverString.hasPrefix("http://"), !serverString.hasPrefix("https://") {
                let scheme = settings.instance.apiURL.scheme ?? "https"
                serverString = "\(scheme)://\(serverString)"
            }
            guard var comp = URLComponents(string: serverString) else {
                server = nil
                continue
            }
            comp.queryItems = [
                URLQueryItem(name: "act", value: "a_check"),
                URLQueryItem(name: "key", value: lp.key),
                URLQueryItem(name: "ts", value: String(ts)),
                URLQueryItem(name: "wait", value: "60"),
                URLQueryItem(name: "version", value: "3"),
                // Кэш-бастер: сервер игнорирует ts → URL повторяется, и кэш (локальный
                // или CDN) может «зациклить» один ответ. Уникальный параметр ломает это.
                URLQueryItem(name: "rnd", value: String(Int.random(in: 0..<Int.max)))
            ]
            guard let url = comp.url else {
                server = nil
                continue
            }

            do {
                log("ждём события… (ts=\(ts), wait=60)")
                let started = Date()
                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                request.timeoutInterval = 80
                request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
                let (data, urlResponse) = try await session.data(for: request)
                if Task.isCancelled { break }
                failureStreak = 0
                lastCycleAt = Date()
                let waited = Int(Date().timeIntervalSince(started))

                // Пустое тело = таймаут без событий — просто повторяем с тем же ts.
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    log("таймаут без событий (\(waited)с) — повторяем")
                    continue
                }
                if let failed = obj["failed"] {
                    log("failed=\(failed) — ключ протух, берём новый сервер")
                    server = nil
                    continue
                }
                if let newTS = obj["ts"] as? Int { ts = newTS }
                let updates = (obj["updates"] as? [[Any]]) ?? []
                log("ответ через \(waited)с: \(updates.count) событие(й), новый ts=\(ts)")
                var hadFresh = false
                for update in updates {
                    log("  событие: \(Array(update.prefix(6)))")
                    // Код 4 — новое сообщение: [4, msgId, flags, peerId, time, text, ...]
                    if update.count >= 4,
                       (update[0] as? Int) == 4,
                       let msgID = update[1] as? Int,
                       let peer = update[3] as? Int {
                        if isDuplicate(msgID) {
                            log("  повтор msgId=\(msgID) — игнорируем (эхо сервера)")
                            continue
                        }
                        log("  → новое сообщение msgId=\(msgID), peer=\(peer)")
                        let text = (update.count > 5 ? update[5] as? String : nil) ?? ""
                        newMessage.send(LPNewMessage(peerID: peer, messageID: msgID, text: text))
                        hadFresh = true
                    }
                }
                // Ответ состоял только из эха — пауза, чтобы не молотить запросами,
                // пока событие не выпадет из окна повтора (~1с) на сервере.
                if !updates.isEmpty && !hadFresh {
                    echoStreak += 1
                    // Диагностика: если ответ пришёл из кэша, тут будет Age/cf-cache-status.
                    if let http = urlResponse as? HTTPURLResponse {
                        let age = http.value(forHTTPHeaderField: "Age") ?? "-"
                        let cf = http.value(forHTTPHeaderField: "cf-cache-status") ?? "-"
                        log("только повторы (\(echoStreak) подряд); кэш-заголовки: Age=\(age), cf=\(cf)")
                    }
                    if echoStreak >= 5 {
                        // Эхо не рассасывается — форсируем новый ключ (заодно новый URL).
                        log("эхо зациклилось — берём новый LongPoll-ключ, пауза 5с")
                        echoStreak = 0
                        server = nil
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                    } else {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                    }
                } else {
                    echoStreak = 0
                }
            } catch {
                if Task.isCancelled { break }
                // Обрыв/оффлайн: пауза с бэкоффом и новый сервер.
                failureStreak += 1
                log("ошибка сети: \(error.localizedDescription) (попытка \(failureStreak)) — пауза и новый сервер")
                await sleepWithBackoff(failureStreak)
                server = nil
            }
        }
    }

    private func fetchServer(settings: AppSettings) async -> LPServer? {
        guard let token = settings.token else { return nil }
        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        return try? await client.call(
            "messages.getLongPollServer",
            params: ["need_pts": "0", "lp_version": "3"]
        )
    }

    /// Пауза 5с → 10с → … → 60с между повторами при сбоях (не душим сеть и батарею).
    private func sleepWithBackoff(_ streak: Int) async {
        let seconds = min(streak * 5, 60)
        try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
    }
}
