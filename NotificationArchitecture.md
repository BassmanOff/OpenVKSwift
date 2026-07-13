# Архитектура уведомлений OpenVK iOS

## Обзор

Приложение работает **без APNs** (sideloaded через TrollStore). Уведомления строятся на трёх механизмах:

1. **LongPoll** — мгновенные уведомления о сообщениях (пока приложение на экране или живо в фоне)
2. **BGAppRefresh** — фоновые проверки сообщений и активности (когда LongPoll не работает)
3. **Опрос (polling)** — `ActivityViewModel` опрашивает `notifications.get` каждые 30 секунд

Бейджи: `ConversationsViewModel` считает непрочитанные сообщения → обновляет badge приложения.

---

## Компоненты

### LongPollService (`Sources/Features/Messages/LongPollService.swift`)

**Роль:** Мгновенная доставка событий о новых сообщениях.

- Держит висящий запрос к `{host}/nim{userID}` с `wait=60`
- Событие кода 4 `[4, msgId, flags, peerId, time, text]` → `newMessage` PassthroughSubject
- Дедупликация: кольцевой буфер `seenIDs` (300 элементов) — сервер повторяет события ~1 сек
- При `failed` или ошибке — переподключение с экспоненциальной задержкой (5с → 60с)
- Запускается в `MainTabView.task`, останавливается при уходе в фон (если нет keepAlive)

**Кто слушает `newMessage`:**

| Место | Действие |
|-------|----------|
| `ConversationsView.task` | `noteIncoming(peer:)` — увеличивает `localUnread[peer]`; перезагружает список через 2.5 сек |
| `MainTabView.onReceive` | Создаёт локальное push-уведомление через `NotificationService.notifyMessage()` (если `scenePhase != .active`) |

---

### NotificationService (`Sources/Core/Notifications/NotificationService.swift`)

**Роль:** Планирование и отправка локальных `UNUserNotificationCenter` уведомлений.

**Статические методы:**

- `requestPermission()` — запрос разрешения на уведомления (вызывается из `MainTabView.task`)
- `notifyMessage(peerID:messageID:text:author:badge:)` — создаёт уведомление с `threadIdentifier = "msg_\(peerID)"`, `userInfo = ["peerID": peerID]`

**BackgroundRefresh** (вложенный тип):

- `register()` — регистрация `BGAppRefresh` задачи с id `com.ovkclient.app.refresh` (вызывается из `AppDelegate.didFinishLaunching`)
- `schedule()` — планирует следующий запуск через 15 минут (вызывается при уходе в фон и при первом запуске)

**Фоновая задача `refresh()`** (8 сек лимит):

1. Если `notifyMessages` включены → `checkMessages(client:)`:
   - `messages.getConversations` (count=50, extended=1, fields=photo_50)
   - Сравнивает `lastMessage.id` с `UserDefaults["msg_seen_last_ids"]`
   - Для каждого непрочитанного → `notifyMessage()` + обновляет badge
   - Сохраняет `notifiedKey` чтобы не дублировать уведомления

2. Всегда → `checkActivity(client:)`:
   - `notifications.get` (count=20)
   - Сравнивает `date` с `UserDefaults["activity_notified_date"]` и `lastViewed` от сервера
   - Создаёт одно уведомление со счётчиком新鲜ных событий

---

### ActivityViewModel (`Sources/Features/Activity/ActivityViewModel.swift`)

**Роль:** Загрузка уведомлений «Ответы» (лайки, репосты, комментарии) для UI и бейджа.

- Загружает `notifications.get` (count=30) — это **не** push-уведомления, а серверные «ответы»
- `unreadCount` — число уведомлений новее `lastViewed` (серверный маркер)
- `lastViewed` обновляется через `notifications.markViewed` (вызывается при открытии вкладки «Ответы»)
- 30-секундный таймер опроса живёт в `MainTabView.task` (работает на всех вкладках)
- `loadIfNeeded()` — первичная загрузка (с кэшем), `reload()` — принудительное обновление

**Бейджи:**
- `activity.unreadCount` → бейдж на вкладке «Новости» (`MainTabView.tabBar`)
- `activity.unreadCount` → бейдж колокольчика в `NewsfeedView` (кнопка «Ответы»)

---

### ConversationsViewModel (`Sources/Features/Messages/ConversationsView.swift`)

**Роль:** Список диалогов + бейдж на иконке приложения.

**Система непрочитанных:**

| Источник | Значение |
|----------|----------|
| `localUnread[peerID]` | Точное число по LongPoll-событиям (пока диалог не открыт) |
| `seenLastID[peerID]` | id последнего просмотренного сообщения (UserDefaults) |
| `convo.unreadCount` | Серверный флаг (максимум 1, проверяет только последнее сообщение) |

- `noteIncoming(peer:)` — при LongPoll-событии: `localUnread[peer] += 1` (если диалог не активен)
- `markSeen(peer:)` — при открытии диалога: обнуляет `localUnread`, фиксирует `seenLastID`
- `unreadDialogsCount` — число диалогов с непрочитанными → бейдж вкладки «Сообщения»
- `unreadMessagesCount` — общее число непрочитанных → badge приложения (`applicationIconBadgeNumber` / `setBadgeCount`)

**Обновления:**
- 60-секундный polling в `ConversationsView.task` (свои сообщения с других устройств не дают LongPoll-событий)
- LongPoll `newMessage` → перезагрузка списка (двойная: сразу + через 2.5 сек для «проглоченных»)
- Переключение на вкладку «Сообщения» → `conversations.load()`

---

### MainTabView (`Sources/Features/Main/MainTabView.swift`)

**Роль:** Точка интеграции всех механизмов.

**Создаёт:**
- `@StateObject var conversations = ConversationsViewModel()` — единый экземпляр
- `@StateObject var activity = ActivityViewModel()` — единый экземпляр

**Task-生命周期:**

| Условие | Задача |
|--------|--------|
| `.task` (вход в MainTabView) | `longPoll.start()`, `requestPermission()` + `BackgroundRefresh.schedule()`, 240с online ping |
| `.task` (вход в MainTabView) | `activity.loadIfNeeded()` + 30с polling `activity.reload()` |
| `.onChange(of: .active)` | `longPoll.start()`, `conversations.load()`, `activity.reload()` |
| `.onChange(of: .background)` | `longPoll.stop()` (если нет keepAlive), `BackgroundRefresh.schedule()` |
| `.onChange(of: selection == .messages)` | `conversations.load()` |

**Обработчики:**
- `onReceive(longPoll.newMessage)` → `NotificationService.notifyMessage()` (если фон + `notifyMessages`)
- `onReceive(NotificationRouter.shared.$pendingPeerID)` → `selection = .messages`
- `onDismiss(of: scenePhase)` → keepAlive start/stop

---

### AppDelegate (`Sources/App/AppDelegate.swift`)

**Роль:** Регистрация BGAppRefresh + обработка тапов по уведомлениям.

- `didFinishLaunching` → `BackgroundRefresh.register()` + `UNUserNotificationCenter.current().delegate = self`
- `didReceive response` → извлекает `peerID` из `userInfo` → `NotificationRouter.shared.pendingPeerID = peer`

---

### NotificationRouter (`Sources/Core/Notifications/NotificationService.swift`, вложенный тип)

**Роль:** Маршрутизация тапов по уведомлениям между AppDelegate и View-слоем.

- `@Published var pendingPeerID: Int?` — публикует целевой диалог
- Слушается в `MainTabView.onReceive` (переключает на вкладку «Сообщения») и `ConversationsView.onReceive` (открывает диалог)

---

## Потоки данных

### Новое сообщение (приложение на экране)

```
Сервер → LongPollService.run() → isDuplicate? → newMessage.send(LPNewMessage)
  ├─→ ConversationsView.onReceive → noteIncoming(peer:) → localUnread[peer]++ → updateAppBadge()
  │                                          └→ load() через 2.5 сек
  └─→ MainTabView.onReceive → scenePhase == .active → пропуск (не шлём уведомление)
```

### Новое сообщение (приложение в фоне, LongPoll жив)

```
Сервер → LongPollService.run() → newMessage.send(LPNewMessage)
  ├─→ MainTabView.onReceive → scenePhase != .active → NotificationService.notifyMessage()
  │                                                       └→ UNUserNotificationCenter.add()
  └─→ ConversationsView.onReceive → noteIncoming(peer:) → localUnread[peer]++
```

### Новое сообщение (приложение закрыто, LongPoll мёртв)

```
iOS → BGAppRefresh.refresh() → NotificationService.checkMessages()
  → messages.getConversations → сравнение lastMessage.id с seenLastID
  → notifyMessage() для каждого нового → updateAppBadge()
```

### Тап по уведомлению

```
iOS → AppDelegate.didReceive → userInfo["peerID"] → NotificationRouter.shared.pendingPeerID = peer
  ├─→ MainTabView.onReceive → selection = .messages
  └─→ ConversationsView.onReceive → openChat(peer:) → openPeerID = peer → NavigationLink → ChatView
```

### Активность («Ответы»)

```
MainTabView.task (30с polling) → ActivityViewModel.reload()
  → notifications.get → unreadCount = число элементов > lastViewed
  → ActivityView читает unreadCount → бейдж колокольчика

MainTabView.task (30с polling) → BGAppRefresh.refresh()
  → NotificationService.checkActivity() → notifications.get → локальное уведомление (если新鲜)
```

---

## Источники бейджей

| Бейдж | Источник | Обновляется |
|-------|----------|-------------|
| Badge на иконке приложения | `ConversationsViewModel.unreadMessagesCount` | LongPoll `noteIncoming`, BGAppRefresh `checkMessages`, polling 60с |
| Бейдж вкладки «Сообщения» | `ConversationsViewModel.unreadDialogsCount` | LongPoll `noteIncoming`, polling 60с |
| Бейдж вкладки «Новости» | `ActivityViewModel.unreadCount` | Polling 30с |
| Бейдж колокольчика в ленте | `ActivityViewModel.unreadCount` | Polling 30с |

---

## Известные проблемы

1. **`markAsRead` не существует** — сервер не поддерживает пометку прочитанным через API. Клиент компенсирует через `seenLastID` (UserDefaults), но это неточно при нескольких устройствах.

2. **Серверный `unreadCount` ≤ 1** — `messages.getConversations` проверяет только последнее сообщение. Точное число только через LongPoll (`localUnread`).

3. **Нет LongPoll для активности** — OpenVK не шлёт событий о лайках/комментариях. Polling каждые 30 сек — единственный путь.

4. **Свои сообщения не дают событий** — LongPoll получает только ВХОДЯЩИЕ. Исходящие с другого устройства видны только через polling 60с.

5. **Badge не сбрасывается при открытии** — `unreadMessagesCount` считает все диалоги кроме активного (`activePeerID`). При открытии списка — badge обнуляется, но при открытии конкретного диалога — только этот диалог исключается.

6. **Дублирование уведомлений** — BGAppRefresh и LongPoll могут одновременно создать уведомление для одного сообщения (если LongPoll сработал перед уходом в фон). Механизм `notifiedKey` в `checkMessages` частично решает это, но не гарантирует.

---

## Возможные улучшения

| # | Проблема | Решение |
|---|----------|---------|
| 1 | `markAsRead` отсутствует | Клиент уже компенсирует через `seenLastID`. Улучшить: синхронизировать `seenLastID` между устройствами через Keychain/CloudKit (если будет поддержка). |
| 2 | Серверный `unreadCount` ≤ 1 | Уже компенсируется через `localUnread`. Улучшить: при BGAppRefresh считать точное число через `messages.getConversations` (count=50). |
| 3 | Нет LongPoll для активности | Ограничение сервера. Улучшить: уменьшить polling до 15с или добавить push через APNs (если будет сервер). |
| 4 | Свои сообщения не дают событий | Polling 60с уже решает. Улучшить: уменьшить до 30с. |
| 5 | Badge неточен | Уже компенсируется. Улучшить: сбрасывать badge при входе в приложение (`setBadgeCount(0)`). |
| 6 | Дублирование уведомлений | Добавить общий `lastNotifiedMessageID` в UserDefaults, проверять перед созданием уведомления. |
| 7 | BGAppRefresh ненадёжный | iOS может не запустить задачу. Альтернатива: silent push (APNs) или longer background task (beginBackgroundTask). |
| 8 | polling 30с для активности | Расход батареи. Улучшить: увеличить до 60с (как для сообщений) или добавить backoff при отсутствии新鲜ых. |
