# LINK_ROUTES.md — OpenVK URL route reference for the iOS client

> Reference map of OpenVK URL routes for the native iOS client.
> Link-navigation implementation (`LinkParser` / `LinkRouter` / `LinkDestinationView`) must follow this document.

## Sources of truth

- **OpenVK server routes** — `Web/routes.yml` (`url` → `handler`) in the OpenVK repository.
- **Entity URL builders** — `Web/Models/Entities/*::getURL` / `::getPrettyId` / `Playlist::getURL`.
- **Away redirect** — `Web/Presenters/AwayPresenter.php` (`?to=<url>` query param).
- **Current client** — `Sources/Core/Navigation/LinkNavigation.swift` (`LinkParser`, `LinkRouter`, `LinkDestination`).

**Interception + presentation architecture.** Interception is **global**: one `.environment(\.openURL, …)` override at the `MainTabView` root (a shared `LinkRouter`), inherited by every tab and every pushed screen (incl. toolbar-pushed ones like Activity). Presentation is **push, VK-style** (page slides in from the right, native back, edge-swipe, tab bar stays): the override records the active tab; `.pushesGlobalLinks(tab:)` inside each of the 5 tabs' `NavigationView`s pushes the destination into that tab's stack via a hidden `NavigationLink`. `.handlesOVKLinks()` (a self-contained push handler) is applied only on **modal roots** (`.sheet`, e.g. comments — `openURL` doesn't cross a modal boundary) and **recursively** on the opened destination (chained links). Do **not** attach `.handlesOVKLinks()` to individual tabs. Genuinely-modal media/editor screens (player, avatar/photo viewer, full-screen video, compose, pickers, graffiti) stay modal.

**Confirmed vs. assumption.** The *URL pattern*, *entity type*, and *OpenVK source route* columns are confirmed against `routes.yml` and entity code. The *recommended opening behavior* column is a recommendation for the iOS client, not a server fact.

## How OpenVK routing works (context)

- Routes in `routes.yml` are matched **top to bottom**. `/id{num}` matches before the group fallback; the screen-name catch-all `/{?shortCode}` is **last**.
- `{num}` = digits. Web links for groups use the `club{n}` / `public{n}` / `event{n}` forms; negative owner ids only appear in the **API / mention** form (`[club-N|…]`, `wall-N_M`), not in normal web paths.
- The group route is `/{?!club}{num}` with placeholder `club: "club|public|event"` — **there is no `/group{n}` web route** (the client's extra `group` prefix is harmless but inaccurate). Bare `/{num}` also resolves to `Group->view`.
- Short-code (screen-name) placeholder is `[a-z][a-z0-9\@\._]{0,30}[a-z0-9]`: lowercase only, min length 3 (config `shortcodes.minLength`), may contain `@`, must start with a letter and end alphanumeric.

## Status legend

- **✅ Already supported** — handled today by `LinkParser` / `LinkRouter`.
- **🔨 Needs implementation** — a native screen exists (or is trivial to reach) but the parser does not route here yet.
- **🌐 Browser only** — intentionally sent to the external browser (no native screen).
- **❓ Unknown** — needs a decision or further investigation before implementing.

---

## Supported entity routes

| URL pattern | Entity | OpenVK source route | Client status | Recommended opening | Required data / API |
|---|---|---|---|---|---|
| `/id{userID}` | User | `/id{num}` → `User->view` | ✅ Already supported | Push navigation → `ProfileView` | `userID`; `ProfileView(userID:)` loads via `users.get` |
| `/club{groupID}` | Community | `/{?!club}{num}` → `Group->view` | ✅ Already supported | Push navigation → `GroupView` | `groupID`; `groups.getById` |
| `/public{groupID}` | Community | `/{?!club}{num}` → `Group->view` | ✅ Already supported | Push navigation → `GroupView` | `groupID`; `groups.getById` |
| `/event{groupID}` | Community | `/{?!club}{num}` → `Group->view` | ✅ Already supported | Push navigation → `GroupView` | `groupID`; `groups.getById` |
| `/group{groupID}` | Community | *(no such server route)* | ✅ Already supported (client-only) | Push navigation → `GroupView` | Accepted by client regex; not emitted by OpenVK |
| `/wall{ownerID}_{postID}` | Post | `/wall{num}_{num}` → `Wall->post` | ✅ Already supported | Push navigation → `CommentsView` | `ownerID`, `postID`; `wall.getById` |
| `/photo{ownerID}_{photoID}` | Photo | `/photo{num}_{num}` → `Photos->photo` | ✅ Already supported | Push navigation → `PhotoViewer` | `ownerID`, `photoID`; `photos.getById` |
| `/video{ownerID}_{videoID}` | Video | `/video{num}_{num}` → `Videos->view` | ✅ Already supported | Push navigation → `VideoPlayerScreen` | `ownerID`, `videoID`; `video.get` |
| `/topic{groupID}_{topicID}` | Topic | `/topic{num}_{num}` → `Topics->topic` | ✅ Already supported | Push navigation → `TopicView` | `groupID`, **`virtual_id`** (not DB id); `board.getComments` |
| `/playlist{ownerID}_{playlistID}` | Playlist | `/playlist{num}_{num}` → `Audio->playlist` | ✅ Already supported | Full-screen cover → `AlbumDetailView` (unified with all types) | `ownerID`, `playlistID`; `audio.getPlaylistById` |
| `/{shortcode}` | User **or** Community | `/{?shortCode}` → `UnknownTextRouteStrategy->delegate` | ✅ Already supported | Push navigation (after resolve) | `utils.resolveScreenName` → `{object_id, type}` |

**Notes**
- `/topic` uses the per-group `virtual_id`, not the DB id — see the board `virtual_id` workaround in `PROJECT_CONTEXT.md`.
- OpenVK **audio albums are `/playlist{owner}_{id}`**, not `/album…` (`Playlist::getURL`); the client already routes them correctly.
- The client screen-name regex (`^[A-Za-z][A-Za-z0-9_.]{1,31}$`) diverges from the server (lowercase, min 3, allows `@`) — see *Unknown or unsupported routes*.

---

## Audio and media routes

| URL pattern | Entity | OpenVK source route | Client status | Recommended opening | Required data / API |
|---|---|---|---|---|---|
| `/audio{ownerID}_{audioID}` | Audio | `/audio{num}_{num}` → `Audio->aloneAudio` | 🔨 Needs implementation | Needs decision — play in `AudioPlayer` or external | `ownerID`, `audioID`; a `getById`-style fetch, then enqueue |
| `/album{ownerID}_{albumID}` | Album (photo) | `/album{num}_{num}` → `Photos->album` | ❓ Unknown | Needs decision (no confirmed native photo-album screen) | `ownerID`, `albumID`; `photos.getAlbums` / `photos.get` |
| `/note{ownerID}_{noteID}` | Note | `/note{num}_{num}` → `Notes->view` | 🌐 Browser only | External browser (no native note viewer) | `instance.webURL` + path |
| `/doc{ownerID}_{docID}` | Document | `/doc{num}_{num}` → `Documents->page` | 🌐 Browser only | External browser (no native document viewer) | `instance.webURL` + path |
| `/poll{pollID}` | Poll | `/poll{num}` → `Poll->view` | 🌐 Browser only | External browser (no standalone poll viewer) | `instance.webURL` + path |
| `/app{appID}` | App | `/app{num}` → `Apps->play` | 🌐 Browser only | External browser (mini-apps unsupported) | `instance.webURL` + path |
| `/gift{ownerID}_{date}.png` | Gift image | `/gift{num}_{num}.png` → `Gifts->giftImage` | 🌐 Browser only | External browser (image asset, not navigation) | Image URL |

**Notes**
- `/audio{owner}_{id}` currently falls back to the browser (it is excluded from screen-name matching by `isReserved`). Routing it into the in-app player needs an audio lookup by `{owner}_{id}`.
- `/album` is ambiguous: OpenVK uses `/playlist` for audio albums, so `/album{o}_{id}` here is a **photo** album (`Photos->album`) — routing depends on whether a native photo-album screen is added.

---

## Owner-scoped routes

A trailing number is an **owner id** (user or negative-form group), addressing a sub-section of that owner. All are currently excluded by `isReserved` and fall back to the browser.

| URL pattern | Entity | OpenVK source route | Client status | Recommended opening | Required data / API |
|---|---|---|---|---|---|
| `/wall{ownerID}` | User/Community wall | `/wall{num}` → `Wall->wall` | 🌐 Browser only | Needs decision — could push owner's wall | `ownerID`; `wall.get` |
| `/friends{ownerID}` | User friends list | `/friends{num}` → `User->friends` | 🌐 Browser only | Needs decision — push `FriendsView(userID:)` | `ownerID`; `friends.get` |
| `/groups{ownerID}` | User groups list | `/groups{num}` → `User->groups` | 🌐 Browser only | Needs decision — push `GroupsView(userID:)` | `ownerID`; `groups.get` |
| `/albums{ownerID}` | Photo albums list | `/albums{num}` → `Photos->albumList` | 🌐 Browser only | Needs decision — push `PhotosView` | `ownerID`; `photos.getAlbums` |
| `/videos{ownerID}` | Videos list | `/videos{num}` → `Videos->list` | 🌐 Browser only | Needs decision — push `VideosView` | `ownerID`; `video.get` |
| `/audios{ownerID}` | Audios list | `/audios{num}` → `Audio->list` | 🌐 Browser only | Needs decision — push `UserAudiosView` | `ownerID`; `audio.get` |
| `/playlists{ownerID}` | Playlists list | `/playlists{num}` → `Audio->playlists` | 🌐 Browser only | Needs decision — push playlists list | `ownerID`; `audio.getPlaylists` |
| `/notes{ownerID}` | Notes list | `/notes{num}` → `Notes->list` | 🌐 Browser only | External browser (no native notes list) | `instance.webURL` + path |
| `/gifts{ownerID}` | Gifts list | `/gifts{num}` → `Gifts->userGifts` | 🌐 Browser only | External browser (no native gifts screen) | `instance.webURL` + path |
| `/board{groupID}` | Group topics list | `/board{num}` → `Topics->board` | 🌐 Browser only | Needs decision — push `TopicsView` | `groupID`; `board.getTopics` |

---

## Utility and external routes

### Away / external redirect

| URL pattern | Entity | OpenVK source route | Client status | Recommended opening | Required data / API |
|---|---|---|---|---|---|
| `/away.php?to=<url>` | External URL | `/away.php` → `Away->away` | ✅ Already supported | External browser — extract `to`, open target directly | `to` query param → `UIApplication.shared.open` |
| `/away.php/{linkID}` | Banned-link warning page | `/away.php/{num}` → `Away->view` | 🌐 Browser only | External browser | `linkID` (banned-link record) |

### Section routes (no id → browser, or future tab deep-links)

Currently reserved in `isReserved` and sent to the browser. Could later map to tab/section selection (larger scoped refactor):

`/feed` (`Wall->feed`), `/feed/all` (`Wall->globalFeed`), `/feed/hashtag/{tag}` (`Wall->hashtagFeed`), `/im` (`Messenger->index`), `/search` (`Search->index`), `/notifications` (`Notification->feed`), `/settings` (`User->settings`), `/docs` (`Documents->list`), `/gifts` (`Gifts->stub`), `/about` (`About->aboutInstance`), `/support` (`Support->index`), `/login` (`Auth->login`), `/logout` (`Auth->logout`), `/reg` (`Auth->register`), `/dev` (`About->dev`), `/admin` (`Admin->index`), `/fave` (`User->fave`), `/donate` (`About->donate`), `/terms` (`About->rules`), `/privacy` (`About->Privacy`).

### Service / API routes (never user-facing navigation)

Not link targets — keep out of the parser entirely:

- **VK API** — `/method/{m}.{fmt}` (`VKAPI->route`), `/method/execute` (`VKAPI->execute`), `/token`, `/oauth/token`, `/authorize`, `/2fa`, `/upload/photo/{text}`.
- **Internal / RPC** — `/rpc` (`InternalAPI->route`), `/iapi/*`, `/al_comments/*`, `/al_avatars`, `/al_abuse/search`.
- **Assets / blobs** — `/blob_{text}/…`, `/photos/thumbnails/…`, `/themepack/…`, `/gift{n}_{n}.png`, `/image.php`, `/robots.txt`, `/humans.txt`, `/.well-known/*`.
- **Action suffixes** on entity URLs — `/like`, `/repost`, `/delete`, `/pin`, `/edit`, `/remove`, `/action`, `/create`, `/makePost` (e.g. `/wall{n}_{n}/like`, `/comment{n}/like`, `/audio{n}/action`).

---

## Unknown or unsupported routes

Items requiring a decision or further investigation before implementation:

1. **`/album{ownerID}_{albumID}` (photo album)** — server route `Photos->album` is confirmed, but there is no confirmed dedicated native photo-album screen. Decide: build one, reuse the photo grid, or keep browser fallback.
2. **Bare `/{num}` → community** — `Group->view` accepts a plain numeric path. Low priority edge case; not currently handled by the client (falls through to browser).
3. **Screen-name regex divergence** — server: `[a-z][a-z0-9\@\._]{0,30}[a-z0-9]` (lowercase, min 3, allows `@`). Client: `^[A-Za-z][A-Za-z0-9_.]{1,31}$` (allows uppercase and 2-char names, no `@`). Aligning reduces needless `resolveScreenName` calls; verify case-insensitivity of resolution before tightening.
4. **Custom-instance hosts hardcoded** — `LinkParser.hosts` only matches `openvk.org` / `openvk.xyz` / `ovk.to`. On any other `settings.instance.webURL`, links are **not intercepted at all** and always open in the browser. Should compare against `settings.instance` instead of a hardcoded set.
5. **`/audio{owner}_{id}` opening behavior** — needs a decision between routing into the in-app `AudioPlayer` (requires an audio lookup by `{owner}_{id}`) vs. external browser.
6. **`/note` vs `/doc`** — these are distinct: `/note{o}_{id}` → `Notes->view`, `/doc{o}_{id}` → `Documents->page`. (Earlier notes conflated documents with a `blob` hash URL; `routes.yml` shows the `{num}_{num}` form for both.)
