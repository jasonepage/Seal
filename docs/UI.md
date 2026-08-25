# UI Design Specification — Seal

**Version:** 0.1 · **Companions:** [SRS.md](SRS.md) · [SDS.md](SDS.md)

## 1. Design Language: "Vault Warmth"

The tension to resolve: hardware-key security reads as cold and corporate; Snapchat-style social reads as playful and disposable. Seal's identity is **warm metal** — the intimacy of a small, deliberately chosen friend group, expressed with the material confidence of something machined.

- **Palette:** near-black ink backgrounds (`#0C0E12`), warm brass accent (`#D9A441`) reserved exclusively for trust moments (key taps, verified badges, endorsements), per-group accent hues chosen at creation. Light mode exists but dark is the hero.
- **Type:** SF Pro / SF Rounded hybrid — Rounded for names and social surfaces, Pro for security surfaces. Security text is never small print: key fingerprints render as large, friendly **emoji-word phrases** (e.g., "🦊 meadow violet anchor"), not hex.
- **Materials:** chat surfaces use soft glass (`.ultraThinMaterial`); trust ceremonies use an opaque, machined-metal visual treatment. The material shift itself signals "you are now doing something that matters."
- **Motion:** physical metaphors only. Keys *click* into place (haptic `rigid`), endorsements *stamp* (scale-down + heavy haptic), new friendships *forge* (two rings fuse with a brass glow). 120 Hz spring animations, no fades for trust events — security actions deserve mass.
- **Sound + haptics:** the NFC tap success is the signature moment: triple haptic pulse + a short brass chime. It should feel like a wax seal.

### 1.1 The Seal (character)

The app has a mascot: a seal 🦭. The pun carries the brand's dual nature — the *animal* is the warmth, the *wax seal* is the trust. Strict separation rule: the mascot lives only on **social surfaces** (empty states, onboarding coaching, celebrations, group counts); it never appears on **security surfaces** (verification drawer, key management, revocation, ceremony confirmation), which stay machined and serious. Voice: dry, brief, a little proud of you ("Seals make friends in person. So do you.").

**Colonies:** a group of seals is called a colony, and so is a Seal group chat. Member visibility is ambient: every chat header shows the colony — overlapping identity rings plus "🦭 n" — and tapping it opens the verification drawer, so the playful surface is literally the doorway to the serious one. Group rows in the chat list carry a 🦭 count badge.

## 2. Information Architecture

```
TabView (4 tabs as shipped)
├─ Chats      — conversation list, pinned groups
├─ Camera     — capture-first (Snapchat pattern)
├─ Circle     — friends, forge ceremony, forge log
└─ You        — profile, devices, key management
Modal layer: Ceremony flows (full-screen covers, can't be swiped away mid-tap)

Parent Mode collapses this to Chats alone — see §6.
```

## 3. Screen Specs

### 3.1 Onboarding & Registration
1. **Three-panel intro** — "Your key is your identity / Friends are made in person / Nothing is recoverable, by design." Plain language, no crypto jargon.
2. **Tier choice (FR-21):** "Start with Face ID" (passkey, one tap) vs. "I have a security key" (Verified). Verified path shows the NFC coaching sheet: animated phone-meets-key illustration, USB-C fallback button.
3. **The first tap** is the brand moment — on success the brass seal animation plays and the user's identity ring renders for the first time.
4. **Backup key prompt (FR-3):** blocking card, brutally honest copy: "Lose every key, lose this identity. Nobody can reset it — not us, not Apple." Add-backup-key or explicit "I accept the risk" acknowledgment.

### 3.2 Friend Ceremony (the hero flow)
Full-screen, two phases, designed to be performed while standing next to someone:
1. **Exchange:** your identity ring + QR on screen; friend scans (prefills their claimed identity), then the screen flips to **"Now tap [Friend]'s key"** with the NFC sheet.
2. **Forge:** on a valid assertion, both identity rings slide together and fuse with the brass glow; the emoji-word fingerprint phrase appears beneath — *say it out loud to each other* is suggested in-UI (human-layer verification of the channel).
Failure states (wrong key, stale challenge, timeout) get plain-language explanations and one-tap retry — never a raw error.

### 3.3 Chats & Conversation
- **List:** large avatars (identity rings double as avatars — brass ring = Verified, silver = passkey), unread as a filled ring segment, ephemeral groups show a subtle hourglass tint.
- **Conversation:** bubbles on glass; sender ring-color accents. Verified-only groups show a brass header band. Ephemeral messages burn with a particle dissolve at TTL (FR-12); screenshot detection posts a system row ("Nathan took a screenshot"), Snapchat-style.
- **Verification drawer:** pull down on any chat header → epoch number, member rings, each member's fingerprint phrase, and a green "transcript verified" check (per-sender hash chain, SDS §2). Security status is *ambient and one gesture away*, never buried in settings.

### 3.4 Camera
Capture-first, minimal chrome: shutter, flip, flash, group-send tray after capture. Media previews show an encryption shimmer as the upload encrypts — progress UI doubles as a security cue.

### 3.5 Circle (friends + key management)
- Friend grid of identity rings; tap → profile with fingerprint phrase, shared groups, "Remove friend" (FR-8).
- **Keys panel:** every registered hardware key and device as a card (nickname, added date, last used). Revoke = drag card to a shredder zone + hardware-key tap confirm (FR-19). Revocation plays a deliberate, slightly somber animation — it should feel consequential.
- New-device QR flow (U4) lives here.

### 3.6 Demo Mode (FR-22/23)
Persistent brass "DEMO" watermark badge in the safe-area corner of every screen; demo friends have a dashed identity ring. Otherwise identical UX so the reviewer experiences the real product.

## 4. Component Inventory
`IdentityRing` (animatable, tier-aware) · `CeremonySheet` (NFC coaching, state machine: idle → searching → reading → sealed/failed) · `FingerprintPhrase` · `EpochBadge` · `BurnBubble` (TTL dissolve) · `KeyCard` · `SealAnimation` (shared brass-stamp Lottie/Metal shader).

## 5. Accessibility
Every haptic/sound cue has a visual twin; ceremony flows fully VoiceOver-scripted ("Hold the key flat against the top of your phone"); fingerprint phrases are speakable by design; Dynamic Type through XL on all chat surfaces (and through **accessibility XL** on every surface Parent Mode touches, §6); reduced-motion swaps springs for crossfades except trust events, which become instant-with-haptic rather than animated.

## 6. Parent Mode

A per-**device** presentation mode for the family anti-scam case: an adult
child sets Seal up on an aging parent's phone and hands it over simplified.
Implementation: `Seal/Theme/ParentMode.swift`.

**It is presentation and nothing else.** Wire format, identity, friends,
signatures and directory behaviour are identical in both modes; a chat between
a Parent Mode phone and a normal phone works unchanged in both directions, and
no peer can tell which mode the other is in. The flag is per identity in the
keychain (`seal.parentmode.<hash>`, presence = on — the AppLock pattern) and is
wiped by sign-out and by delete.

**Called "Simplified mode" in every user-visible string.** Never "elderly
mode", never "parent mode": the person reading those strings is the one holding
the phone, and the point is that the phone doesn't treat them as a category.
The toggle lives in Profile beside the Face ID lock, in **silver** — it changes
how Seal looks and makes no claim about trust, so brass would be wrong (§1.1).

### 6.1 What changes when it's on

1. **Chats only.** No tab bar at all — a one-tab TabView is a stripe of wasted
   screen. The chat list *is* the app; Profile is an identity-ring button in its
   toolbar. Camera and Circle tabs are gone.
2. **Photos survive the missing Camera tab.** The composer inside a chat opens
   the *same* `CameraTab` as a full-screen cover with that chat pre-selected in
   the send tray. No second photo UI exists.
3. **The friend ceremony is not reachable in this mode** — by design: the helper
   who set the phone up forges friendships. Profile says so in plain words, and
   the way back is the same toggle.
4. **One Dynamic Type class larger,** applied ONCE at the top of the chat list's
   split view so it covers the list, the open chat and every sheet those
   present. The user's own setting is a **floor, not a ceiling**: someone
   already at accessibility XL gets one step beyond it, never a reset down.
   Minimum tap target 52pt (above the 44pt HIG floor).
5. **Plain words, moved not deleted.** The verification drawer leads with "This
   is really \<name\>." and the card detail sheet with "This really came from
   \<name\>'s phone." Keys, epochs and fingerprint phrases move behind a
   **Details** disclosure on both screens — they must stay reachable, because
   "prove it" is the question those screens exist to answer.
6. **Sealed Card prominence.** Larger title, and under the verification line a
   one-line explainer: "Sealed means this really came from \<name\>'s phone."
   The value never truncates — it wraps, however tall, at any text size.
7. **Scam-pause on money requests.** An inbound `paymentInstructions` or
   `cryptoAddress` card carries one calm orange line, styled like the TTL
   notice: "Take your time. If anything feels off, call \<name\> before
   acting." On the bubble *and* in the detail sheet — a caution that only
   appears after you tap the seal is one most people never see. It blocks
   nothing and adds no tap; the card stays fully readable.
8. **Compose stays.** Nothing is read-only. Text, photos, cards, reactions,
   replies, TTL, block and report all work exactly as they do in normal mode.

### 6.2 What must never change

Specification copy from [CARDS.md](CARDS.md) is not softened for Parent Mode. A
card is **sealed**, never "verified" or "safe"; the honesty paragraph stays
where it is; and the §5 sentence about what the re-check proves stays on screen
verbatim, with the plain-words line *above* it rather than in place of it. The
TTL disclosure in the verification drawer stays visible in both modes —
a limitation tucked behind a disclosure is how honest copy quietly becomes
dishonest.

### 6.3 Demo

`-SealParentDemo` implies `-SealDemoMode` and forces the mode on **without**
writing the keychain flag, so a screenshot run leaves nothing behind.
`-SealDemoHideWatermark` still applies. Fixtures seed two inbound cards: the BTC
address in the Sam chat and a multi-line payment-instructions card in the family
chat, which is the one that renders the scam-pause and the wrap-don't-truncate
behaviour.
