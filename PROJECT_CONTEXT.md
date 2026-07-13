# PROJECT_CONTEXT.md — Долгосрочная память проекта

> Перед каждым изменением кода читать этот файл.

## Обзор

Нативный iOS-клиент OpenVK (VK-совместимая соцсеть), стилизованный под VK 2014–2016. Swift + SwiftUI, iOS 15 минимум, iPhone-only, всегда светлая тема. Строка UI, комментарии и коммиты — на русском.

**Дистрибуция:** сайдлоад через TrollStore / SideStore / AltStore. Сертификата Apple нет → настоящий APNs-push невозможен. Уведомления: локальные `UNUserNotificationCenter` + LongPoll + тихое аудио (KeepAlive) + BGAppRefresh.

## Архитектура приложения

### Слои

```
Sources/App          — точка входа, корневая маршрутизация, ориентация
Sources/Core         — сеть, авторизация, настройки, навигация, уведомления
Sources/Models       — Decodable-модели API
Sources/DesignSystem — VK-цвета, кэшированные изображения, тосты
Sources/Features     — один фолдер на экран (MVVM, ~90% кода)
```

### Точка входа

- **`OVKApp.swift`** — `@main`, создаёт глобальные `@StateObject` как `@EnvironmentObject`: `AppSettings`, `AudioPlayer`, `AudioDownloadManager`, `LibraryManager`, `LikesManager`, `LongPollService`, `PhotoHeroCoordinator`, `KeepAliveService`. Настраивает `URLCache` (16МБ RAM / 200МБ disk), `.preferredColorScheme(.light)`.
- **`RootView.swift`** — `settings.isLoggedIn` → `MainTabView` / `LoginView`. При логауте: остановка воспроизведения, LongPoll, очистка всех личных кэшей.
- **`AppDelegate.swift`** — блокировка ориентации (портрет, ландшафт только для видео), регистрация BGAppRefresh, маршрутизация уведомлений.

### Глобальное состояние (EnvironmentObject)

| Объект | Ответственность |
|--------|-----------------|
| `AppSettings` | Сессия (токен в Keychain, userID в UserDefaults, инстанс JSON в UserDefaults), настройки, API v5.131 |
| `AudioPlayer` | Очередь AVPlayer, локскрин, shuffle/repeat, `PlaybackClock` для тиков |
| `AudioDownloadManager` | Офлайн-треки в Application Support, `downloads.json` |
| `LibraryManager` | Оптимистичное добавление/удаление из «Моей музыки» |
| `LikesManager` | Оптимистичные лайки постов/комментариев |
| `LongPollService` | Висящий `a_check` для реалтайм-сообщений |
| `PhotoHeroCoordinator` | Галерея фото (UIKit, hero-анимации) |
| `KeepAliveService` | Тихое аудио для фоновой активности |

## Сеть

### OVKClient

Лёгкая структура, создаётся per-call из `(instance, token, apiVersion)`. Нет синглтона.

- `call(_:params:)` — декодированный `response`
- `execute(_:)` — запись/скалярные методы (валидация: валидный JSON с `"response"`; HTML = ошибка)
- `rawResponse(_:)` — сырой JSON для кэширования
- `uploadImage(_:to:)` / `uploadWallPhoto(jpeg:)` — multipart-загрузка фото

**Каждый запрос** содержит `_ovk=<random>` (кэш-бастер) и `request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData`.

### Формат ошибок OpenVK

Ошибки приходят на верхнем уровне JSON (`{"error_code", "error_msg"}`), часто с HTTP 400. Это НЕ VK-style `error`-объект. См. `OVKError`.

### Инстансы

- `openvk.org` — HTTPS, API на `api.openvk.org`
- `openvk.xyz` — HTTP-only (`NSAllowsArbitraryLoads` включён)
- Авторизация идёт через `api.openvk.org` (не `openvk.org` — там anti-bot JS challenge)

## Модели API

| Файл | Типы |
|------|------|
| `User.swift` | `User` (id, имя, аватары, онлайн, платформа, счётчики, статус) |
| `Post.swift` | `Post`, `WallResponse`, `Repost` (вложения: photos/audios/videos) |
| `Audio.swift` | `Audio`, `ItemsResponse<T>` (audioID, artist, title, url, manifest, album) |
| `Album.swift` | `Album` (albumID, ownerID, title, cover, bookmarked) |
| `Photo.swift` | `Photo` (sizes[], bestURL, thumbURL, aspectRatio) |
| `Video.swift` | `Video` (mp4URL, playerURL, platform) |
| `Message.swift` | `Message`, `Conversation`, `ConversationsResponse`, `HistoryResponse` |
| `Comment.swift` | `Comment`, `CommentsResponse` |
| `Group.swift` | `Community` (НЕ `Group` — конфликт с SwiftUI.Group) |
| `Topic.swift` | `Topic` (topicID, title, comments, isClosed) |
| `ActivityNotification.swift` | `ActivityNotification`, `NotifObject`, `NotificationsResponse` |
| `Lyrics.swift` | `Lyrics` (lines[{time,text}], synced, source; LRC-парсер) |

## Кэширование

### Паттерн View-Model кэширования

Используется в Feed/Profile/Messages/Audio:

1. Каждый VM имеет `static func clearCache()` и персистит **сырой JSON-ответ** на диск
2. При загрузке: мгновенный показ из кэша → тихое обновление сетью
3. `generation`-счётчик для отбрасывания устаревших ответов
4. **Никогда не очищать данные до прихода ответа** (иначе List исчезает mid-gesture → баг «cancelled»)
5. Раздельные флаги `isLoading` (пустой стейт) и `isLoadingMore` (футер)

### Файлы кэша

| Путь | Содержимое |
|------|-----------|
| `Documents/feed_cache_my.json` | Лента (моя) |
| `Documents/feed_cache_global.json` | Лента (все) |
| `Documents/my_tracks_cache.json` | Мои треки |
| `Documents/dialogs_cache.json` | Список диалогов |
| `Documents/chat_cache_{peer}.json` | Переписка с пользователем |
| `Documents/profile_cache_{id}.json` | Профиль пользователя |
| `Documents/wall_cache_{id}.json` | Стена (пользователя/группы) |
| `Caches/cover_art_cache.json` | Обложки из iTunes |
| `Caches/lyrics_cache.json` | Тексты песен |

### Изображения

- `ImageCache` (NSCache, 128МБ byte-limited) — память декодированных обложек
- `CachedImage` — конфигурируемый `maxPixelSize` (= ширина экрана)
- Даунсэмплинг через ImageIO (`CGImageSourceCreateThumbnailAtIndex`)
- Фоновые декоды: `nonisolated async func` (НЕ `Task.detached` — detached не наследует отмену)

## Сообщения

### Загрузка диалогов

`messages.getConversations(count, extended=1)` → `{count, items:[{conversation, last_message}], profiles}`

- Пагинация: `fetchLimit`-паттерн (расширяемый limit, перечитывание с offset=0)
- Кэш: `Documents/dialogs_cache.json`

### Загрузка истории

`messages.getHistory(peer_id, count)` — новые первые (разворачиваем)

- Первая страница: 30 сообщений
- Пагинация: `willDisplay` на indexPath.item >= total-5 → `loadOlder`
- `offset = raw.count + bias` (bias для компенсации новых сообщений)
- **Инвертированный список** (Telegram-стиль): offset 0 == низ, старые сообщения = конец snapshot
- `merge(existing:freshTail:)` в load/poll/reloadAfterSend

### LongPoll

`LongPollService` — висящий `a_check` к `{host}/nim{userID}`

- Протокол: `messages.getLongPollServer` → `{key, server, ts}` → `{server}?act=a_check&key&ts&wait=60&version=3`
- События: `{ts, updates:[[4, msgId, flags, peerId, time, text,...]]}`
- `{failed:N}` → перезапрос сервера
- **Дедуп по msgId** (кольцевой буфер 300 id)
- **Эхо-фикс**: если только повторы → пауза 2с перед реконнектом
- Кэш-бастер `rnd=<random>` + `.reloadIgnoringLocalAndRemoteCacheData`
- Флаги расширены: бит 2 = исходящее, time из update[2]/update[4]

### Оптимистичная отправка

`ChatViewModel.pending: [PendingMessage]` — UUID, текст, дата, failed

- `send()`: сначала pending (мгновенно на экране) → потом `messages.send` → `reloadAfterSend` → убрать pending
- При ошибке: `failed=true`
- `rows: [ChatRow]` = messages + pending

### Галочки доставки

`outRead` из `messages.getConversationsById(peer_ids)` (поле `out_read`)

- `sending` (часы) / `sent` (1 галка, id > outRead) / `read` (2 галки, id ≤ outRead) / `failed` (!)

### Реакции (HiddenReaction)

Реакции НЕ поддерживаются сервером. Реализация через невидимые сообщения:

- Сообщение = «видимый эмодзи + zero-width-метка»
- Кодировка: U+200B=0, U+200C=1 для битов targetID
- Старт: U+2060×2, конец: U+2061
- **ВСЕГДА работать через `unicodeScalars`, никогда `Character`** (zero-width сливаются в grapheme-кластеры)
- Три ветки `react()`: тот же эмодзи → `messages.delete`; другой + id>0 → `messages.edit`; нет自己的 → `messages.send`
- `MessageReaction { emoji, messageID }` — messageID=0 для оптимистичной

### Read receipts

`messages.markAsRead` НЕ существует. Непрочитанное снимается только когда получатель ответил/прочитал на вебе. Клиент фейчит локальный read-state (`localUnread` + `seenLastID` в UserDefaults).

## Музыка

### AudioPlayer

AVPlayer-based очередь. Приоритет: локальный файл > стриминг. Локскрин-управление. `PlaybackClock` — отдельный объект для тиков (чтобы per-second ticks не перерисовывали списки).

### Поиск

- `audio.search` → MySQL `MATCH ... AGAINST IN BOOLEAN MODE` (целые слова, min 3 символа)
- Решение: wildcard `*` к каждому слову (`jew` → `jew*`)
- `audio.searchAlbums` → `LIKE %query%` (подстрока) — wildcard НЕ нужен

### Библиотека

- `LibraryManager` — оптимистичное состояние с откатом
- Трек: `audio.add` / `audio.delete`
- Альбом: `audio.bookmarkAlbum` / `audio.unBookmarkAlbum`

### Broadcast

`audio.setBroadcast(audio="{owner}_{vid}", target_ids="{uid}")` — ставит «слушаю» + регистрирует прослушивание. НЕ звать с пустым аудио (серверный 500).

### Автозагрузка

ОБА триггера: при добавлении в «Мою музыку» И при прослушивании. Один тумблер `autoDownloadMyTracks`.

### Кэш обложек

`CoverArtService` — обложки из iTunes Search API для треков без `coverURL` в OpenVK. Дисковый кэш `cover_art_cache.json`.

### Тексты песен

Источники: LRCLIB (приоритет) → OpenVK `audio.getLyrics` (фолбэк, без таймкодов). Кэш: `lyrics_cache.json`.

## Видео

**MobileVLCKit** — единственный движок видео. Причина: OpenVK кодирует видео как H.264 + MP3-в-MP4. Apple AVFoundation не декодирует MP3 внутри MP4.

`VLCVideoView` (UIViewRepresentable над VLCMediaPlayer). YouTube → WebView.

**Мёртвые пути (не возрождать):**
- Кастомный видеодвижок (MP4 demux → HLS/TS remux) — удалён 2026-07-07
- SwiftUI-просмотрщик фото (v1–v3.1) — заменён на UIKit `PhotoHero`

## Профиль

- `ProfileView` — шапка (аватар, имя, онлайн, статус), счётчики (друзья/фото/аудио/видео/группы), стена
- Счётчики: NavigationLink → `FriendsView`, `PhotosView`, `UserAudiosView`, `VideosView`, `GroupsView`
- Чужие профили: `ProfileView(userID:)` — без NavigationView
- Стена: `WallViewModel` (wall.get extended=1, cursor-пагинация)
- Посты: `PostRow` (аватар, имя, платформа, текст, фото-сетка, аудио, видео, лайки/комменты/репосты)
  - `commentTapEnabled: Bool = true` — отключает интерактивность кнопки комментариев (для встраивания в CommentsView)
- Создание поста: `NewPostView` (TextEditor + фото + граффити PencilKit)
- Комментарии: `CommentsView` / `CommentsViewModel` (wall.getComments, wall.createComment)
  - Принимает `post: Post?` — показывает пост в шапке экрана комментариев
  - Если пост не передан — загружает через `wall.getById`
  - Переиспользует `PostRow` с `commentTapEnabled: false` для рендера поста
- Лайки: `LikesManager` (оптимистично, likes.add/delete)

## Сообщества

- `GroupsView` — вкладки «Сообщества» / «Управление», поиск, админ-значок
- `GroupView` — шапка, описание, стена (reuse WallViewModel с `owner_id=-groupID`)
- Категории: Участники → `MembersView`, Аудио → `UserAudiosView`, Обсуждения → `TopicsView`
- Вступить/Покинуть: `groups.join` / `groups.leave` (оптимистично)

### Обсуждения (board)

- `board.getTopics` отдаёт DB id, а `getComments`/`createComment` ищут по `virtual_id` — разные числа
- Обход: `TopicsViewModel.vidGuess[dbid]=ранг`, резолв через `board.getTopics?topic_ids=guess`
- Комменты от имени groups: `from_id` без минуса → ручная инверсия если `fromID>0 ∈ clubIDs`

## Навигация по ссылкам

- `LinkParser` (regex) распознаёт хосты openvk.org/xyz + ovk.to и пути
- `linkifiedText(_:)` — `AttributedString` с ссылками + упоминаниями `[id123|Имя]`
- `LinkRouter` (env object) + `.handlesOVKLinks()` модификатор (рекурсивный, для вложенных экранов)
- `LinkDestinationView` (sheet) — профиль, сообщество, плейлист, тема

## Уведомления

- **Нет APNs** → локальные `UNUserNotificationCenter`
- LongPoll при живом приложении в фоне (если `player.isPlaying` или `backgroundKeepAlive`)
- BGAppRefresh (`com.ovkclient.app.refresh`) — ~15-60 мин по усмотрению iOS
- KeepAliveService — тихое аудио для держания процесса (1-3%/ч батареи)
- Тап по уведомлению → `NotificationRouter` → диалог

## Ориентация

Портрет по умолчанию через `AppDelegate.orientationLock`. Ландшафт только для полного экрана видео (`setVideoOrientation` / `forceRotate`).

## Таб-бар

Кастомный (НЕ системный `TabView`) — `.safeAreaInset(edge: .bottom)` на iOS 15 перекрывает системный таб-бар.

- `VStack { content(ZStack с opacity/allowsHitTesting) ; MiniPlayerView ; tabBar }`
- Все вкладки смонтированы (ZStack с opacity) — сохранение навигации
- Потерян системный «тап по вкладке = pop to root»

## iOS 15 / SwiftUI — критические ограничения

1. **НЕ класть несколько `NavigationLink` в строку `List`** — самоактивируются при прокрутке
2. **`.buttonStyle(.plain)`** на ВСЕ кнопки в строках List
3. `.refreshable` работает ТОЛЬКО на `List`, не на голом `ScrollView`
4. Условный `if` внутри `.toolbar{}` требует iOS 16 — класть `if` ВНУТРЬ ToolbarItem
5. **НЕ называть тип `Group`** (коллизия с `SwiftUI.Group`) → `Community`
6. `.navigationViewStyle(.stack)` на ВСЕ `NavigationView`
7. В body строк: НИКАКИХ `NSDataDetector`/`NSRegularExpression`/`DateFormatter` — только статические + кэш
8. Контекст-меню: нативный SwiftUI `.contextMenu`, НЕ UIKit-жесты

## Известные ограничения API OpenVK

- `messages.markAsRead` не существует
- Вложения в ЛС API не отдаёт
- `last_seen` только для онлайн-пользователей
- `board.getTopics` → DB id, `getComments` → virtual_id (нет конвертации)
- `groups.getMembers` нет фильтра managers
- `notifications.get` нет friend requests → `friends.getRequests`
- Likes: серверный баг в `Notification::emit()` — лайк чужого поста через API может не сохраняться

## Правила разработки

1. Перед изменением кода — прочитать этот файл
2. Не переписывать рабочую архитектуру без веской причины
3. Предпочитать минимальные точечные фиксы
4. Кэш-бастер `_ovk=<random>` на ВСЕ запросы, особенно запись
5. `execute()` требует валидный JSON с `"response"` (HTML = ошибка)
6. При refresh — никогда не очищать данные до ответа
7. `HiddenReaction` — только `unicodeScalars`, никогда `Character`
8. `Error.isCancellation` для отменённых запросов
9. Производительность — только отсоединённо от Xcode (`OS_ACTIVITY_MODE=disable`)
10. Новые Swift-файлы под `Sources/` → `xcodegen generate` перед сборкой
