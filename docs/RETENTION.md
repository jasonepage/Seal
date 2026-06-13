# Seal — Week-1 Family Retention Punch List

*The goal: get the family using Seal **every day for a week**. Retention is won on two axes most messengers underinvest in — **notifications that fire every single time**, and **a reason to open when nothing is waiting** — not on feature count. The crypto/identity stack is done; this list is the messenger-feel layer that turns "an encrypted app that works" into "the chat my family lives in."*

**Scope note:** ForgeRank / the Square / proof-of-humanity are **irrelevant to this test** — the family already knows each other. Defer all of it. Spend the week on the boring features below.

Status keys: ✅ done · 🔨 in progress · ⬜ todo

---

## Tier 0 — Reliability (if this isn't flawless, nothing else matters)

**🔨 Push hardening (2026-06-13).** Several real gaps closed in code; one manual Xcode step + device retest remain.
- **Foreground banners now show.** `willPresent` previously returned `[]` (all foreground banners suppressed — the "no banner" complaint). Now returns `[.banner, .sound, .list]`, so activity in other chats is visible while the app is open. (`SealApp.swift`)
- **APNs registers unconditionally.** Was gated on the user granting alert permission; now registers regardless so CloudKit delivery + silent refresh work even if they tapped "Don't Allow". (`Views/HomeView.swift`)
- **App-icon badge + clear-on-open.** Subscriptions set `shouldBadge`; badge resets on `scenePhase == .active`. (`SyncEngine`, `HomeView`)
- **Background pre-fetch.** Subscriptions set `shouldSendContentAvailable` so the app wakes to decrypt before open. **MANUAL STEP REQUIRED:** enable Background Modes → *Remote notifications* (`UIBackgroundModes = remote-notification`) in the Xcode target, else this silently no-ops (alerts still fire).
- **Subscription config now versioned** (`seal.msgsub.v2` / `seal.invsub.v2`) and v1 retired on migration — existing installs were never reconfigured in place, so without this they'd never get the badge/title/content-available changes.
- **Diagnostics:** `didRegister`/`didFailToRegister` now `NSLog` so the "push didn't work" path is triageable.
- **Still to verify on device (two phones, app fully closed):** every message AND invite produces a banner 100% of the time; group-creation invite banner; badge increments/clears. The `ChatView` `.task` 4s poll stays as a belt-and-suspenders fallback.

**~ Kill false "Offline" noise.** `lastError` surfacing in `ChatView` (~line 35). Offline notices must self-clear and never cry wolf. (Partly addressed 6/12; verify on device.)

---

## Tier 1 — Make it feel *alive* (highest engagement per line of code)

**✅ Emoji reactions (FR-11).** Done 2026-06-13. Long-press a bubble → ❤️😂👍🔥😮😢. Rides the existing E2EE pipeline as a `kind:"reaction"` payload (same pattern as `screenshot`), pointing at a new stable `wireID` (`<sender>.e<epoch>.<index>`) so it lands on the right bubble across devices. One reaction per person; tap again to clear.
- Files touched: `Chat/ChatEngine.swift` (`ChatMessage.wireID`/`.reactions`, `MessagePayload.reactTo`/`.emoji`, `react()`, `applyReaction()`, send + receive branches), `Views/ChatView.swift` (`.contextMenu` picker + `reactionChips`).
- **Compat caveat (same as screenshots):** builds without this code render a reaction as an empty bubble. Harmless — family updates together. Device build still needs verifying on two phones.
- Next polish: a floating emoji bar on long-press instead of the system context menu; haptic on react.

**✅ Quote-replies.** Done 2026-06-13. Long-press → Reply; a compose banner shows above the input, the sent bubble carries a quoted header. Reuses the `wireID` plumbing but also carries its own `replyPreview` snippet + `replySenderHash`, so the quote renders even when replying to a message that predates `wireID` or isn't loaded (more robust than reactions).
- Files touched: `Chat/ChatEngine.swift` (`MessagePayload`/`ChatMessage` reply fields, `send(replyingTo:)`, `replyPreview()`, threaded through send/demo/receive), `Views/ChatView.swift` (`replyingTo` state, context-menu Reply, compose banner, `replyQuote`).
- Next polish: tap a quote to scroll to the original (needs the original loaded + `wireID` present); deep-link only works for post-`wireID` messages.

**✅ Presence: typing + read receipts.** Done 2026-06-13.
- **Read receipts:** `kind:"read"` ack carrying `readUpTo` (a timestamp, comparable across senders, not a wireID). `readMarks` (chat → reader → latest-seen date) persists so "Read" survives relaunch. "Read" (1:1) / "Read by N" (group) shows under your most recent message once others catch up. Acked from the poll loop, throttled to only emit when the high-water mark advances (no ack loops — read records aren't inbound bubbles).
- **Typing:** ephemeral `kind:"typing"` ping, throttled to 1/4s while composing; `typingBy` is transient (never persisted), auto-expires after 6s, and clears the moment a real message lands. **Caveat:** over the current 4s poll transport this is laggy by design — a nicety, not real-time. Real-time would need a push/streaming channel.
- Both ride the E2EE pipeline as non-bubble kinds (`isNonBubble`). Files: `Chat/ChatEngine.swift` (markRead/sendTyping/readerCount/typingMembers/applyRead/markTyping), `Views/ChatView.swift` (read label, typing row, send triggers).
- Cost note: read/typing each create a permanent CloudKit Message record (chain entry). Fine at family scale; a future ephemeral channel would avoid the clutter.

---

## Tier 2 — Reasons to come back daily

**⬜ Short video.** The most-felt content gap — families share kid/pet/"look at this" clips constantly. More work than Tier 1: E2EE video over `CKAsset`, size cap, compression, thumbnail.
- Reuse the photo path nearly wholesale: `Chat/ChatEngine.swift` `sendPhoto()` → generalize to `sendMedia()`; `MediaBubble` in `Views/ChatView.swift` → add an `AVPlayer` branch; `Camera/CameraController.swift` for capture.

**⬜ Camera-forward daily hook.** The Snapchat-energy open from VISION — launch toward the camera, or one lightweight daily prompt, so there's a reason to open with nothing waiting. Even a tiny "good morning" ritual turns 7 sessions into a habit.
- Files: `Views/HomeView.swift` / `Views/CameraTab.swift`, `ContentView.swift` (default tab).

---

## Tier 3 — Friction removers specific to this test

**⬜ Confirm disappearing messages actually work.** HANDOFF rates TTL only "i think it works." For a real week you want certainty — both surprise-vanishing and never-vanishing erode trust. `Chat/ChatEngine.swift` `purgeExpired()` + `expiresAt` enforcement; verify on device.

**⬜ Don't let Face ID lock nag.** Re-auth friction is a silent retention killer for a casual family chat. `Identity/AppLock.swift` — confirm it only prompts on cold launch / after backgrounding past a threshold, not every glance.

**⬜ Basic group hygiene.** Name the group, see the member list at a glance. Member list already lives in the verification drawer (`VerificationSheet`); surface group name + member count more prominently in `Views/ChatsView.swift` / the chat header `ColonyBar`.

---

## Suggested build order

1. 🔨 **Push reliability** (Tier 0) — hardened in code 6/13; needs the background-mode capability toggle + two-phone device retest.
2. ✅ **Reactions** — done.
3. ✅ **Replies** — done.
4. ✅ **Typing + read receipts** — done.
5. **Short video** — the one bigger lift worth it for families.
6. **Camera-forward daily hook.**

Items 2–4 are comparatively cheap and are exactly what a dense small group runs on.
