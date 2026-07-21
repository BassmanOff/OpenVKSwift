# iOS 7 Visual Refresh Plan

## Goal

Make every part of the app feel like the same product as the new player: a light,
flat VK interface inspired by iOS 7–10, while preserving modern accessibility,
reliable gestures, and smooth performance on older phones.

This is a visual refresh, not a redesign of the app's information architecture.
Existing navigation, data flows, and familiar VK layouts should remain unless a
visual change cannot be implemented cleanly without adjusting their structure.

## Delivery rules

- Work through the numbered items in order and review each item before starting the next.
- Reuse the existing theme and shared view components; do not add dependencies.
- Keep scrolling cells opaque and inexpensive to render.
- Do not push changes or create/update a pull request until explicitly requested.
- Keep each item as a separate local commit when practical, without co-author trailers.

## Visual rules

### Glass and surfaces

- Use bright `extraLight` glass only for persistent chrome: navigation bars,
  mini-player, tab bar, and chat composer.
- Use one blur layer when adjacent chrome surfaces can share it.
- Keep feed posts, list rows, message bubbles, profile modules, and settings rows opaque.
- Use flat white content surfaces over the existing pale-gray app background.
- Avoid gradients, drop shadows, and floating rounded-card stacks.
- Provide an opaque light fallback when Reduce Transparency is enabled.

### Color

- `OVK.Palette.primary` is the global control accent.
- `OVK.Palette.link` is reserved for tappable text links.
- Use `textPrimary` for titles and `textSecondary` for supporting information.
- Use red for destructive actions and notification badges.
- Use green only where it communicates a genuinely positive or online state;
  downloaded, added, playing, and selected states should normally use VK blue.

### Geometry and typography

- Use one physical-pixel hairline throughout the app.
- Use 4 pt corners for avatars, artwork, and compact media.
- Use 6 pt corners for contained controls where a radius is necessary.
- Use 8 pt between related sections and 16 pt horizontal content insets.
- Maintain at least 44 x 44 pt interactive targets.
- Keep navigation titles inline and centered.
- Prefer regular/light symbols and restrained font weights.
- Keep system fonts and Dynamic Type rather than reproducing fixed historical fonts.
- Keep rounded-square VK avatars; do not convert them globally to circles.

## Work items

### 1. Core visual foundation — complete

- [x] Enable the new player by default for users without a stored preference.
- [x] Preserve an explicitly saved Off choice.
- [x] Rename the player setting so it no longer looks like an unfinished debug option.
- [x] Apply VK blue as the root SwiftUI and navigation-bar tint.
- [x] Define shared spacing, radius, and minimum-target metrics.
- [x] Define and use one physical-pixel hairline for persistent chrome.
- [x] Give custom tab items a minimum 44 pt target.

Acceptance criteria:

- A fresh install opens the new player path by default.
- A user who switched the new player off remains on the old player.
- Native and custom controls use the same primary blue.
- The project builds without new warnings.

### 2. Bottom chrome and mini-player — implemented locally

- [x] Make the mini-player and tab bar one continuous bottom glass tray.
- [x] Use a single outer blur with one hairline between mini-player and tab bar.
- [x] Avoid a doubled bright band where the two bars meet.
- [x] Keep the tab bar visually close to the native 49 pt layout, excluding the safe area.
- [x] Let scrolling content visually continue behind the glass while preserving safe
  content insets, list scrolling, tab switching, and player swipe gestures.
- [x] Add a 40–44 pt square artwork tile to the mini-player with a 4 pt radius.
- [x] Use a black track title and blue artist, matching the full player.
- [x] Make artwork, labels, and unused panel space open the full player.
- [x] Keep visible transport controls uncluttered: play/pause, next, and More; Previous
  remains available in the full player instead of adding width heuristics on iOS 15.
- [x] Move Stop out of the leading `x` position into a secondary action.
- [x] Give every mini-player control a 44 pt hit target.
- [x] Replace the OS-dependent progress control appearance with a stable thin blue line.
- [x] Keep Reduce Transparency and Increase Contrast readable.

Acceptance criteria:

- Bottom chrome reads as one two-tier surface rather than stacked panels.
- No control is clipped or crowded on an iPhone SE-width screen.
- The full player still opens and closes smoothly by tap and swipe.
- Tab content is never hidden behind the mini-player or tab bar.
- Only one bottom blur layer is active during normal use.

Device validation still required: iPhone SE width, full-player swipe dismissal, Chat
keyboard/input-bar positioning, and screens with their own nested bottom safe-area inset.

### 3. Shared search and scope controls — implemented locally

- [x] Build one small reusable iOS 7-style search strip.
- [x] Place it directly beneath the translucent navigation bar.
- [x] Use a pale field, compact radius, restrained placeholder, and bottom hairline.
- [x] Build one shared scope/segmented selector: approximately 30–32 pt tall,
  thin blue outline, 4–6 pt radius, blue selected segment, and white selected text.
- [x] Replace modern system segmented pills in News and Music.
- [x] Replace modern navigation-bar search drawers in Friends and Music.
- [x] Preserve Music's primary library selector while showing search scope separately;
  do not replace one selector with another in the same unexplained position.
- [x] Keep focus, keyboard submission dismissal, VoiceOver labels, and 44 pt outer hit
  targets correct in the implementation.

Acceptance criteria:

- News, Friends, and Music use the same search and scope grammar.
- Controls do not change appearance across supported iOS versions.
- Entering and leaving search does not cause list content to jump unexpectedly.

Device validation still required: keyboard/focus behavior on iOS 15, VoiceOver selected
traits, and label fit on an iPhone SE-width screen.

### 4. Primary tab refinement

#### News

- [x] Keep posts full-width and opaque; do not introduce floating cards or per-post blur.
- [x] Use a lighter rhythm between posts: narrow gray separation plus crisp hairlines.
- [x] Keep the action row borderless, without a separator above it.
- [x] Use regular-weight action icons and a filled VK-blue heart for the active like state.
- [x] Standardize avatar, media, poll, and repost corner radii.
- [x] Flatten polls and replace oversized modern filled actions with compact blue or
  hairline actions.
- [x] Use a thin VK-blue repost accent instead of a heavy gray stripe.
- [x] Preserve identical post metrics between News and the Profile wall.

#### Messages

- [x] Use stronger name/preview weight only for unread conversations.
- [x] Add a quiet pinned-conversations label or divider.
- [x] Use rounded-square avatars in the chat header as well as the conversation list.
- [x] Keep incoming and outgoing bubbles opaque with moderate regular corners.
- [x] Make the chat composer a fixed glass surface with a top hairline.
- [x] Use a simple bordered or clear input field rather than a heavy modern pill.
- [x] Flatten the scroll-to-bottom button and remove its heavy shadow.
- [x] Keep reactions and post previews compact, opaque, and shadow-free.
- [x] Preserve swipe gestures as the discoverable archive/pin path.

#### Friends

- [x] Keep 44 pt rounded-square avatars and the blue online/platform line.
- [x] Unify local/global and online/offline section-header styling.
- [x] Use one quiet centered treatment for loading, empty, no-results, and error states.
- [x] During global search, retain local results and show progress without jumping rows.

#### Music

- [x] Rename `Online` to a clearer library label such as `My Music`.
- [x] Give every track row the same 44 pt artwork tile, including fallback artwork.
- [x] Use a black title and blue artist consistently with the player.
- [x] Limit the trailing area to duration plus one accessory at most.
- [x] Remove competing play, download, added, and status controls from the same row edge.
- [x] Use blue or muted gray for downloaded/added state instead of green.
- [x] Use filled symbols only for the playing or selected state.
- [x] Ensure album rows show only one disclosure indicator.
- [x] Give search failures an explicit retry state distinct from no results.
- [x] Keep album headers flat, white, editorial, and shadow-free.

#### Profile

- [x] Keep the existing 80 pt rounded-square profile avatar.
- [x] Make identity, counters, and basic information one calm white profile surface with
  hairline divisions; reserve gray gutters for genuinely separate groups and posts.
- [x] Put long status/listening information on a full-width row beneath identity.
- [x] Match listening text to the player hierarchy and link colors.
- [x] Present counters as borderless blue navigation targets with clear pressed feedback.
- [x] Replace the rounded action-button cluster with one clear 44 pt primary action and
  flat or hairline secondary actions.
- [x] Prefer direct, visible navigation to Settings over hiding it in a modern menu.
- [x] Keep Profile wall posts visually identical to News posts.

Acceptance criteria:

- Every primary tab follows the same palette, geometry, and hierarchy.
- No tab gains per-row blur, unnecessary shadows, or modern floating capsules.
- Essential labels and controls remain usable on an iPhone SE-width screen.

### 5. Secondary screens

- [ ] Restyle Responses/Activity as a plain full-width list with restrained section
  headers, hairlines, and flat blue actions.
- [ ] Replace modern inset-grouped Profile information and Settings forms with full-width
  rectangular white sections on gray.
- [ ] Apply the same treatment to archived chats, album details, comments, groups,
  attachments, and other pushed screens as they are encountered.
- [ ] Use the shared empty/loading/error states throughout secondary lists.
- [ ] Keep native alerts and action sheets where they already fit the interaction.

Acceptance criteria:

- Moving from a primary tab into a secondary screen does not feel like switching to a
  different iOS design era.
- Secondary-screen changes do not alter data behavior or navigation semantics.

## Validation after every item

- Build the Debug configuration for a generic iOS device without code signing.
- Run `git diff --check`.
- Confirm only intended files changed.
- Check player tap-to-open and swipe-to-close behavior.
- Check tab switching, scrolling, navigation swipe-back, and keyboard behavior.
- Check an iPhone SE-width device and one current larger device.
- Check with and without an active mini-player.
- Check Reduce Transparency, Increase Contrast, and larger Dynamic Type sizes.
- Watch for main-thread stalls, repeated blur layers, per-cell effects, and image-decoding
  work during scrolling.

## Final release gate

- Complete a visual pass through all five tabs and representative secondary screens.
- Confirm no regressions in player gestures, feed scrolling, or message navigation.
- Confirm the diff contains only intended source and explicitly approved documentation.
- Publish or update a pull request only after explicit approval.
