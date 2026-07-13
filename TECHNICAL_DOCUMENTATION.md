# OpenVK iOS - Technical Documentation

Native iOS client for OpenVK (VK-compatible social network), styled after VK 2014–2016 / OpenVK Legacy. Swift + SwiftUI, iOS 15 minimum, iPhone-only, always light mode. UI strings, comments, and commit messages are in Russian.

**Distribution:** Sideloaded via TrollStore / SideStore / AltStore — **not** the App Store. No Apple developer certificate, so **real APNs push is impossible**. Notifications use local `UNUserNotificationCenter` + LongPoll + optional silent-audio keep-alive + BGAppRefresh.

---

## Architecture Overview

### Layer Structure

```
Sources/
  App/                    — Entry point, root routing, orientation lock
  Core/
    Networking/           — OVKClient (VK-compatible API calls), errors
    Auth/                 — Token acquisition, Keychain storage
    Settings/             — Instance selection, session state
    Navigation/           — Deep-link parsing & routing
    Notifications/        — Local notifications, BGAppRefresh, KeepAlive
  Models/                 — Decodable API models (User, Post, Audio, etc.)
  DesignSystem/           — VK colors, cached images, toasts
  Features/               — One folder per screen area (MVVM, ~90% of code)
```

### App Entry Point (`OVKApp.swift`)

- `@main` struct creating global `@StateObject` instances injected as `@EnvironmentObject`:
  - `AppSettings` — Session, instance, token, userID, preferences
  - `AudioPlayer` — Queue, playback, lock-screen controls
  - `AudioDownloadManager` — Offline track storage
  - `LibraryManager` — Optimistic "My Music" state
  - `LikesManager` — Optimistic post/comment likes
  - `LongPollService` — Hanging `a_check` for instant messages
  - `PhotoHeroCoordinator` — Photo gallery (UIKit, hero animations)
  - `KeepAliveService` — Silent audio for background process survival
- Configures `URLCache` (16 MB RAM / 200 MB disk)
- Forces light mode: `.preferredColorScheme(.light)`
- Configures opaque navigation bar appearance (prevents iOS 15 scroll-edge animation jumps)

### Root View (`RootView.swift`)

- Switches between `LoginView` and `MainTabView` based on `settings.isLoggedIn`
- On sign-out: stops playback, stops LongPoll, clears all personal caches

### App Delegate (`AppDelegate.swift`)

- Portrait lock via `orientationLock`; landscape enabled only for full-screen video
- Registers `BGAppRefresh` task (`com.ovkclient.app.refresh`)
- Handles notification tap → extracts `peerID` → routes via `NotificationRouter`

---

## Core Systems

### Networking: `OVKClient` (`Sources/Core/Networking/OVKClient.swift`)

Lightweight struct created **per-call** from `(instance, token, apiVersion)` — no shared singleton.

Key methods:
- `call<T: Decodable>(_:params:)` → decoded `response`
- `execute(_:params:)` — write/scalar methods; validates success = valid JSON with `"response"` key; HTML responses = failure
- `rawResponse(_:params:)` — raw JSON string for disk caching
- `decode(_:)` — re-decode cached raw JSON via same envelope logic
- `uploadWallPhoto(jpeg:)` / `uploadImage(_:to:)` — multipart photo upload

**Every request** includes:
- Cache-buster `_ovk=<random>`
- `cachePolicy = .reloadIgnoringLocalAndRemoteCacheData`

**OpenVK error envelope** (top-level, not nested `error` object):
```json
{ "error_code": 5, "error_msg": "Not found" }
```
Often returns HTTP 400. `OVKClient.call` parses envelope **before** checking HTTP status.

### Authentication (`AuthService.swift`, `KeychainStore.swift`)

- Token obtained via `/token` endpoint (password grant + optional 2FA code)
- Token stored in **Keychain** (`KeychainStore` with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`)
- User ID + feature toggles in `UserDefaults`
- Instance encoded as JSON in `UserDefaults`
- API version: `5.131`

### Global State: `AppSettings` (`AppSettings.swift`)

`@MainActor` `ObservableObject` — source of truth for:
- `instance` (persisted JSON in UserDefaults)
- `token` (Keychain)
- `userID` (UserDefaults)
- Feature flags: `autoDownloadMyTracks`, `notifyMessages`, `backgroundKeepAlive`, `imageOptimization`, `enableCustomReactions`
- `reportOnline()` — `account.setOnline` every 5 min
- `broadcastListen(ownerID:audioID:)` — `audio.setBroadcast` (sets "now playing" + registers play count via internal beacon)

---

## Caching Architecture

### View-Model Cache Pattern (Feed, Profile, Messages, Audio)

Each VM has:
- `static func clearCache()` — wipes disk cache on sign-out
- Persists **raw JSON response** to disk (Documents or Caches)
- Re-decodes via `OVKClient.decode` on load
- Rationale: re-encoding complex models is fragile; raw body is stable

**Load flow:**
1. Show cached content instantly (if any)
2. Silent network refresh
3. Atomic replace on success

**Critical rule:** On pull-to-refresh **never clear data before response arrives**. Clearing `posts = []` removes the `List` mid-gesture, killing the spinner and cancelling the in-flight request ("cancelled" error). Use a monotonically increasing `generation` counter to discard stale responses.

Separate flags: `isLoading` (empty-state spinner) vs `isLoadingMore` (footer spinner).

### Cache Files

| Path | Contents |
|------|----------|
| `Documents/feed_cache_my.json` | My feed (friends + groups) |
| `Documents/feed_cache_global.json` | Global feed (all posts) |
| `Documents/my_tracks_cache.json` | My audio tracks |
| `Documents/dialogs_cache.json` | Conversations list |
| `Documents/chat_cache_{peer}.json` | Chat history with peer |
| `Documents/profile_cache_{id}.json` | User profile |
| `Documents/wall_cache_{id}.json` | Wall (user/group) |
| `Caches/cover_art_cache.json` | iTunes cover art |
| `Caches/lyrics_cache.json` | Song lyrics |

### Image Caching (`CachedImage.swift`, `ImageCache`)

- `ImageCache` — `NSCache` with **byte-limited cost** (128 MB decoded bitmaps). Key includes `maxPixelSize` and `raw` mode.
- `CachedImage` — configurable `maxPixelSize` (default = screen width in pixels)
- Downsampling via ImageIO (`CGImageSourceCreateThumbnailAtIndex`) — decodes directly to target size
- Background decode: `nonisolated async func` (NOT `Task.detached` — detached doesn't inherit cancellation)
- Decode size = device screen pixels

---

## Messaging & Real-Time

### Conversations Loading

`messages.getConversations(count, extended=1)` → `{count, items:[{conversation, last_message}], profiles}`

- Pagination: "fetchLimit" pattern (extend limit, re-read from offset 0)
- Cache: `Documents/dialogs_cache.json`

### History Loading (`ChatViewModel.swift`)

`messages.getHistory(peer_id, count)` — newest first (reversed for display)

- First page: 30 messages
- Pagination: `willDisplay` at `indexPath.item >= total-5` → `loadOlder`
- `offset = raw.count + bias` (bias compensates for new messages arriving)
- **Inverted list** (Telegram-style): offset 0 = bottom, older messages = end of snapshot
- `merge(existing:freshTail:)` used in load/poll/reloadAfterSend

### LongPoll (`LongPollService.swift`)

Hanging `a_check` to `{host}/nim{userID}` for instant message delivery.

Protocol:
1. `messages.getLongPollServer` → `{key, server, ts}`
2. `{server}?act=a_check&key&ts&wait=60&version=3`
3. Events: `{ts, updates:[[4, msgId, flags, peerId, time, text,...]]}`
4. `{"failed:N"}` → refetch server

Features:
- Deduplication via ring buffer of 300 message IDs (server echoes events)
- Echo-fix: if only duplicates → 2s pause before reconnect
- Cache-buster `rnd=<random>` + `.reloadIgnoringLocalAndRemoteCacheData`
- Event fields untrusted (reload via normal API on any event)

### Optimistic Send

`ChatViewModel.pending: [PendingMessage]` — UUID, text, date, failed flag

1. `send()`: append pending immediately → `messages.send` → `reloadAfterSend` → remove pending
2. On error: `failed=true`
3. `rows: [ChatRow]` = messages + pending

### Delivery Receipts

`outRead` from `messages.getConversationsById(peer_ids)` (field `out_read`)

- `sending` (clock) / `sent` (1 check, id > outRead) / `read` (2 checks, id ≤ outRead) / `failed` (!)

### HiddenReaction (`HiddenReaction.swift`)

Reactions **not supported by server**. Implemented via invisible messages:
- Message = "visible emoji + zero-width payload encoding target message id"
- Encoding: U+200B=0, U+200C=1 for bits of targetID
- Start: U+2060×2, End: U+2061
- **ALWAYS operate on `unicodeScalars`, NEVER `Character`** (zero-width scalars merge into grapheme clusters and corrupt the id)
- Three branches in `react()`: same emoji → `messages.delete`; different + id>0 → `messages.edit`; none own → `messages.send`
- `MessageReaction { emoji, messageID }` — messageID=0 for optimistic

### Read Receipts

`messages.markAsRead` **does not exist**. Unread clears only when recipient replies or reads on web. Client fakes local read-state (`localUnread` + `seenLastID` in UserDefaults). LongPoll never sends read events (only event code 4).

---

## Audio System

### AudioPlayer (`AudioPlayer.swift`)

AVPlayer-based queue. Prefers local file over streaming. Drives lock-screen controls. Splits fast-ticking playback position into separate `PlaybackClock` object so per-second ticks don't re-render observing lists.

- `isShuffled` / `toggleShuffle` (preserves unshuffled queue, current track stays)
- `repeatMode`: off / all / one + `cycleRepeatMode`
- Track end via `trackDidEnd` (repeat one → replay, else `advance(auto:)` with wrap for .all)

### Search

- `audio.search` → MySQL `MATCH ... AGAINST IN BOOLEAN MODE` (whole words, `ft_min_word_len` 3–4)
- Solution: append `*` wildcard per word (`jew` → `jew*`), enforce 3-char minimum
- `audio.searchAlbums` → `LIKE %q%` (substring) — **do NOT add wildcard there**

### Library (`LibraryManager`)

Optimistic state with rollback:
- Track: `audio.add` / `audio.delete`
- Album: `audio.bookmarkAlbum` / `audio.unBookmarkAlbum`

### Broadcast

`audio.setBroadcast(audio="{owner}_{vid}", target_ids="{uid}")` — sets "listening now" + registers play count. **Do NOT call with empty audio** (server 500).

### Auto-Download

BOTH triggers: on add to "My Music" AND on playback. Single toggle `autoDownloadMyTracks`.

### Cover Art (`CoverArtService`)

iTunes Search API for tracks without `coverURL` in OpenVK. Disk cache `cover_art_cache.json`.

### Lyrics

Sources: LRCLIB (priority) → OpenVK `audio.getLyrics` (fallback, no timestamps). LRC parser. Cache: `lyrics_cache.json`.

---

## Video

**MobileVLCKit** (`Vendor/MobileVLCKit.xcframework`, gitignored, ~large binary) — **only video engine**. Reason: OpenVK encodes video as H.264 + MP3-in-MP4. Apple AVFoundation cannot decode MP3 inside MP4.

- `VLCVideoView` (UIViewRepresentable over VLCMediaPlayer)
- YouTube → WebView

**Dead ends removed — do not resurrect:**
- Custom VLC-free video engine (MP4 demux → HLS/TS remux via local HTTP server) — removed 2026-07-07. MP3-in-MP4 files interleave per-frame, ranged fetch useless, remux start slower than VLC.
- SwiftUI photo viewer (v1–v3.1) — replaced by pure-UIKit `PhotoHero` gallery. SwiftUI hero transitions gave zero/singular frames and drag-gesture deadlocks.
- TrollStore-specific second build target / entitlements / process-assertion keep-alive — removed 2026-07-07. Back to single `OVK` target with silent-audio keep-alive.

---

## Profile & Wall

### ProfileView (`ProfileView.swift`)

- Header: avatar, name, online dot, status
- **Now Playing**: Shows currently playing track when user is listening to music (loaded from `audio.getBroadcastList` for other profiles, from local `AudioPlayer` for own profile)
- Counters: friends/photos/audios/videos/groups → NavigationLink
- Other profiles: `ProfileView(userID:)` — pushed without NavigationView
- Wall: `WallViewModel` (`wall.get` extended=1, cursor pagination)
- Posts: `PostRow` (avatar, name, platform icon, text, photo grid, audio, video, like/comment/repost counts)
  - `commentTapEnabled: Bool = true` — disables comment button interaction (for embedding in CommentsView)
- Create post: `NewPostView` (TextEditor + photos + graffiti via PencilKit)
- Comments: `CommentsView` / `CommentsViewModel` (`wall.getComments`, `wall.createComment`)
  - Accepts `post: Post?` — shows post in header
  - If post not passed — loads via `wall.getById`
  - Reuses `PostRow` with `commentTapEnabled: false` for post rendering
- Likes: `LikesManager` (optimistic, `likes.add`/`delete`)

### Current Feature Implementation Status

**"Now Playing" in Profile** — **IMPLEMENTED** but **UNTESTED**

Implementation details:
- For own profile: reads from local `AudioPlayer` (`player.current`) — creates `BroadcastUser` with `statusAudio` from `AudioPlayer.current`
- For other profiles: calls `audio.getBroadcastList` (filter=all) via `AppSettings.fetchBroadcastTrack` → finds matching user ID → extracts `statusAudio` → wraps in `BroadcastUser` → assigns to `currentBroadcast` state
- UI: Shows "Слушает: Track Title" with music.note icon below status text in profile header
- **Known issues**: Not yet tested on device; may need adjustment of `BroadcastUser` initializer and `fetchBroadcastTrack` return type (currently returns `Audio?` but should return `BroadcastUser?`)

### WallViewModel (`WallViewModel.swift`)

- Cursor pagination (`offset`/`count`)
- Raw JSON cache for first page only
- Never clears before response (same pattern as Feed)

---

## Communities

- `GroupsView` — tabs "Communities" / "Management", search, admin badge
- `GroupView` — header, description, wall (reuse `WallViewModel` with `owner_id=-groupID`)
- Categories: Members → `MembersView`, Audio → `UserAudiosView`, Discussions → `TopicsView`
- Join/Leave: `groups.join` / `groups.leave` (optimistic)

### Discussions (board)

- `board.getTopics` returns DB ids but `getComments`/`createComment` want `virtual_id` (per-group counter) — no conversion method
- Workaround: `TopicsViewModel.vidGuess[dbid]=rank`, resolve by guess-and-verify via `board.getTopics?topic_ids=guess`
- Comments on behalf of groups: `from_id` without minus → manual inversion if `fromID>0 ∈ clubIDs`

---

## Link Navigation (`LinkNavigation.swift`)

### LinkParser

Regex-based recognition of OpenVK hosts (`openvk.org`, `openvk.xyz`, `ovk.to`) and paths:
- `/id{userID}`, `/club|public|group|event{groupID}`, `/wall{owner}_{post}`, `/photo{owner}_{id}`, `/video{owner}_{id}`, `/topic{group}_{virtualID}`, `/playlist{owner}_{id}`, `/{shortcode}`

### LinkRouter

Single `@Published var destination: LinkDestination?` + `@Published var targetTab: Int?`

Two roles:
1. **Global router** (one per `MainTabView`): `open(_:activeTab:)` records TAB at tap time → background `NavigationLink` in that tab's stack pushes destination (tab bar stays, native back swipe works)
2. **Local router** (`.handlesOVKLinks()` on modal roots & recursively on opened screen): `open(_)` without tab → push in surrounding `NavigationView`

### Presentation Architecture

- Interception is **global**: one `.environment(\.openURL, …)` override at `MainTabView` root (shared `LinkRouter`), inherited by every tab and every pushed screen (incl. toolbar-pushed like Activity)
- Presentation is **push, VK-style** (page slides from right, native back, edge-swipe, tab bar stays)
- `.pushesGlobalLinks(tab:)` inside each tab's `NavigationView` pushes into that tab's stack via hidden `NavigationLink`
- `.handlesOVKLinks()` (self-contained push handler) applied only on **modal roots** (`.sheet`, e.g. comments) and **recursively** on opened destination (chained links)
- Genuinely-modal media/editor screens (player, avatar/photo viewer, full-screen video, compose, pickers, graffiti) stay modal

---

## Notifications Architecture (`NotificationArchitecture.md`)

No APNs → local `UNUserNotificationCenter` + three mechanisms:

### 1. LongPoll (instant, while app alive in foreground/background)
- `LongPollService` hanging request → `newMessage` subject
- `ConversationsView` listens: `noteIncoming(peer:)` → increments `localUnread[peer]`, reloads after 2.5s
- `MainTabView.onReceive` (if `scenePhase != .active`) → `NotificationService.notifyMessage()`

### 2. BGAppRefresh (periodic, when app frozen/killed)
- Registered in `AppDelegate` (`com.ovkclient.app.refresh`)
- `BackgroundRefresh.refresh()` (8s limit):
  1. If `notifyMessages` → `checkMessages()`: `messages.getConversations`, compare `lastMessage.id` with `UserDefaults["msg_seen_last_ids"]`, notify each new, update badge, save `notifiedKey`
  2. Always → `checkActivity()`: `notifications.get`, compare with `lastViewed` + `activity_notified_date`, create one notification with fresh count

### 3. Polling (Activity tab)
- `ActivityViewModel` polls `notifications.get` every 30s
- `unreadCount` = items newer than `lastViewed` (server marker)
- `lastViewed` updated via `notifications.markViewed` on tab open
- Drives badge on "News" tab + bell icon in feed

### Badge Sources

| Badge | Source | Updated By |
|-------|--------|------------|
| App icon | `ConversationsViewModel.unreadMessagesCount` | LongPoll `noteIncoming`, BGAppRefresh `checkMessages`, 60s polling |
| Messages tab | `ConversationsViewModel.unreadDialogsCount` | LongPoll, 60s polling |
| News tab | `ActivityViewModel.unreadCount` | 30s polling |
| Bell in feed | `ActivityViewModel.unreadCount` | 30s polling |

### ConversationsViewModel Unread System

| Source | Value |
|--------|-------|
| `localUnread[peerID]` | Exact count from LongPoll events (while dialog not open) |
| `seenLastID[peerID]` | ID of last viewed message (UserDefaults) |
| `convo.unreadCount` | Server flag (max 1, checks only last message) |

- `noteIncoming(peer:)` on LongPoll: `localUnread[peer]++` (if dialog not active)
- `markSeen(peer:)` on open: zero `localUnread`, record `seenLastID`
- `unreadDialogsCount` → Messages tab badge
- `unreadMessagesCount` → app icon badge

### Tap Routing

`AppDelegate.didReceive` → extracts `peerID` from `userInfo` → `NotificationRouter.shared.pendingPeerID = peer`
- `MainTabView.onReceive` → `selection = .messages`
- `ConversationsView.onReceive` → `openChat(peer:)` → `NavigationLink` → `ChatView`

---

## Background / "Always Online"

No APNs server exists. `KeepAliveService` plays looping silent audio (background `audio` mode) to keep process alive so LongPoll stays awake and message notifications arrive instantly — at battery cost (1–3%/hr), off by default (`backgroundKeepAlive`).

`BGAppRefresh` (registered in `AppDelegate`, id `com.ovkclient.app.refresh`) does periodic background message checks.

`AppSettings.reportOnline()` / `broadcastListen()` maintain online/now-playing status (5-min window).

---

## Orientation

Portrait-locked via `AppDelegate.orientationLock`; only full-screen video temporarily enables landscape (`setVideoOrientation` / `forceRotate`).

---

## Tab Bar

Custom (NOT system `TabView`) — `.safeAreaInset(edge: .bottom)` on iOS 15 overlaps system tab bar.

```
VStack {
  content(ZStack with opacity/allowsHitTesting)
  MiniPlayerView
  tabBar
}
```

All tabs mounted (ZStack with opacity) — navigation state preserved. Lost system "tap tab = pop to root".

---

## iOS 15 / SwiftUI Critical Constraints

1. **Never put multiple `NavigationLink`s in a `List` row** — they self-activate on scroll/layout (random screens open). Use `Button` setting `@State route` + one programmatic `NavigationLink(isActive:)` in `.background`.
2. **Buttons in `List` rows need `.buttonStyle(.plain)`** or tap anywhere in row triggers them.
3. `.refreshable` only works on `List`, not bare `ScrollView`.
4. Conditional `if` directly inside `.toolbar {}` needs iOS 16 — put `if` *inside* one `ToolbarItem`.
5. **Never name a type `Group`** (or `Section`/`List`/`Text`…) — collides with SwiftUI. Community model is `Community`.
6. Use `.navigationViewStyle(.stack)` on every `NavigationView` (avoids split layout / mispositioned bars on notchless devices).
7. In list-row `body`: no `NSDataDetector`/`NSRegularExpression`/`DateFormatter` construction — use static instances + result cache (`LinkifyCache`). Building them per-row caused touch-down freeze.
8. Context menus: native SwiftUI `.contextMenu`, NOT UIKit gestures.

---

## OpenVK API Limits (Server-Side — No Client Fix)

| Limit | Details |
|-------|---------|
| `messages.markAsRead` | Does not exist. Unread clears only when recipient replies or reads on web. Read receipts via `out_read` from `messages.getConversations` are inherently partial; client fakes local read-state. |
| Audio search | MySQL `MATCH ... AGAINST IN BOOLEAN MODE` (whole words, `ft_min_word_len` 3–4). `SearchViewModel` appends `*` wildcard per word, enforces 3-char minimum. Album search uses `LIKE %q%` — do NOT add wildcard there. |
| PM attachments | Not returned by API (`getHistory` builds messages without them) |
| Chats | 1-on-1 only (`chat_id` → fail 946) |
| Stickers | Not supported |
| Offline "last seen" | Unavailable — `last_seen` only sent for online users; `notifications.get` has no friend requests (use `friends.getRequests`) |
| Online platform | Coarse code (2=iPhone, 4=Android, 7=web, 1=mobile), never raw client name |
| Board topic IDs | `board.getTopics` returns DB ids but `getComments`/`createComment` want `virtual_id` (per-group counter) with no conversion; `TopicViewModel` resolves by guess-and-verify |

---

## Hard-Won Gotchas — Do Not Re-Litigate

### iOS 15 / SwiftUI (min deployment target)

- **Never put multiple `NavigationLink`s in a `List` row** — they self-activate on scroll/layout
- **Buttons in `List` rows need `.buttonStyle(.plain)`**
- `.refreshable` only works on `List`, not `ScrollView`
- Conditional `if` inside `.toolbar{}` needs iOS 16 — put `if` *inside* `ToolbarItem`
- **Never name a type `Group`** — collides with SwiftUI
- `.navigationViewStyle(.stack)` on every `NavigationView`
- In list-row `body`: no `NSDataDetector`/`NSRegularExpression`/`DateFormatter` construction — use static instances + result cache (`LinkifyCache`)
- Context menus: native SwiftUI `.contextMenu`, NOT UIKit gestures

### Refresh Pattern

On pull-to-refresh **never clear data before response arrives** — clearing `posts = []` removes `List` mid-gesture, killing spinner and cancelling in-flight request ("cancelled" error). Replace atomically, use `generation` counter to drop stale responses, split `isLoading` (empty-state spinner) from `isLoadingMore` (footer). Explicit actions (tab switch) may clear immediately.

### Zero-Width Protocols (`HiddenReaction`)

**Always iterate `unicodeScalars`, never `Character`.** Zero-width scalars merge into neighbouring grapheme clusters, corrupting the encoded id (reactions "disappeared" after restart).

### Cancellation

`OVKClient.call` wraps transport errors in `OVKError.network`, so `as? URLError` misses cancellations. Use `Error.isCancellation` (in `ErrorHelpers.swift`) and `return` early in VM catch blocks before setting `errorMessage`.

### Performance

The ~100 ms touch-down lag was Xcode's synchronous `os_log` bridge, silenced by `OS_ACTIVITY_MODE=disable` in scheme (in `project.yml`) — **only profile detached from Xcode.**

Image cache byte-limits must be sized to feed content (~128 MB); background decodes must be cancellable (`nonisolated async func`, NOT `Task.detached` — detached doesn't inherit cancellation); decode size = device screen pixels.

### Dead Ends Already Removed — Do Not Resurrect Without Being Asked

- **Custom VLC-free video engine** (MP4 demux → HLS/TS remux via local HTTP server) — built, then removed 2026-07-07. MP3-in-MP4 files interleave per-frame, ranged fetch useless and remux start slower than VLC. **MobileVLCKit is the only video engine.**
- **SwiftUI photo viewer** (v1–v3.1) — replaced by pure-UIKit `PhotoHero` gallery. SwiftUI hero transitions gave zero/singular frames and drag-gesture deadlocks.
- **TrollStore-specific second build target / entitlements / process-assertion keep-alive** — removed 2026-07-07; project back to one `OVK` target with silent-audio keep-alive as "always online" option.

---

## Build & Run

```bash
# Regenerate project after ANY change to project.yml or after adding/removing/moving source files
.tools/xcodegen/bin/xcodegen generate      # vendored copy; `brew install xcodegen` also works

# Build for simulator (device build needs signing team + connected iPhone)
xcodebuild -project OVK.xcodeproj -scheme OVK -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' -configuration Debug build
```

- `.xcodeproj` is **generated from `project.yml` by XcodeGen and is gitignored** — never edit by hand, never rely on manual Xcode settings persisting (regeneration resets them). Anything that must survive (version, signing team, bundle id, Info.plist keys) belongs in `project.yml`.
- Scheme/target name is `OVK`; product/display name "OpenVK", bundle id `com.ovkclient.app`.
- Adding a Swift file under `Sources/` requires re-running `xcodegen generate` before it's in the build.
- No test target and no lint config.
- Free Apple ID signing lasts 7 days; re-run from Xcode to re-sign. `DEVELOPMENT_TEAM` is pinned in `project.yml` for the same reason signing must not be edited in the IDE.

---

## OpenVK API Reference (Server Source)

When exact API/field behavior is needed, read the PHP source directly (VKAPI handlers and `Web/Models/Entities`) at `https://raw.githubusercontent.com/openvk/openvk/master/...` rather than guessing — this is how existing models were reverse-engineered.

---

## Reference Documents

- `CLAUDE.md` — Long-term project memory (architecture, read before code changes)
- `PROJECT_CONTEXT.md` — Same as CLAUDE.md (duplicate for different tools)
- `TASK_TRACKER.md` — Task history and known bugs
- `LINK_ROUTES.md` — Complete OpenVK URL route map for client link navigation
- `NotificationArchitecture.md` — Notification system design (no APNs)
- `ovk-ios-roadmap.md` — Development phases and completed features