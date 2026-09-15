# UI Design Specification: Seal

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
ONE shell, no tab bar (docs/COLDSTART.md Part 2)

Chats  ..............  the app
  toolbar leading  ..  identity ring, opens You as a sheet
  toolbar trailing ..  People, then a compose menu
                       (Add someone / New group / Note to self)
  inside a chat  ....  the composer opens Camera as a full-screen
                       cover, pre-aimed at that chat
  You  ..............  everyday settings, then Advanced one tap down
                       (identity card, devices, backup keys,
                        History, Handovers)

Modal layer: ceremony flows as full-screen covers, not swipe-dismissable
             mid-tap.

Every navigation title is .inline. There are no large-title blocks.
```

## 3. Screen Specs

### 3.1 Onboarding & Registration
1. **Three-panel intro** — "Your key is your identity / Friends are made in person / Nothing is recoverable, by design." Plain language, no crypto jargon.
2. **Tier choice (FR-21):** "Set up with Face ID" (passkey, one tap) vs. "I have a security key" (Verified). Verified path shows the NFC coaching sheet: animated phone-meets-key illustration, USB-C fallback button.
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

### 3.5 People (who you've met) · key management now lives in You → Advanced
- Friend grid of identity rings; tap → profile with fingerprint phrase, shared groups, "Remove friend" (FR-8).
- **Keys panel:** every registered hardware key and device as a card (nickname, added date, last used). Revoke = drag card to a shredder zone + hardware-key tap confirm (FR-19). Revocation plays a deliberate, slightly somber animation — it should feel consequential.
- New-device QR flow (U4) lives here.

### 3.6 Demo Mode (FR-22/23)
Persistent brass "DEMO" watermark badge in the safe-area corner of every screen; demo friends have a dashed identity ring. Otherwise identical UX so the reviewer experiences the real product.

## 4. Component Inventory
`IdentityRing` (animatable, tier-aware) · `CeremonySheet` (NFC coaching, state machine: idle → searching → reading → sealed/failed) · `FingerprintPhrase` · `EpochBadge` · `BurnBubble` (TTL dissolve) · `KeyCard` · `SealAnimation` (shared brass-stamp Lottie/Metal shader).

## 5. Accessibility
Every haptic/sound cue has a visual twin; ceremony flows fully VoiceOver-scripted ("Hold the key flat against the top of your phone"); fingerprint phrases are speakable by design; Dynamic Type through XL on all chat surfaces (and through **accessibility XL** on every surface Parent Mode touches, §6); reduced-motion swaps springs for crossfades except trust events, which become instant-with-haptic rather than animated.

## 6. Bigger text

A per-**device** presentation flag. Implementation: `Seal/Theme/ParentMode.swift`.
The type name and the keychain key `seal.parentmode.<hash>` are unchanged so
nobody's setting is lost on upgrade. Only the meaning and the label narrowed.

**History.** It was "Parent Mode", then "Simplified mode": a second shell for a
phone an adult child had set up and handed to a parent. That shell is now the
only shell (§2), so this flag no longer chooses between two apps.

**What it does.** Bigger type and bigger tap targets. That is the whole list.
Type size is a floor and not a ceiling: somebody already on accessibility XL
gets one step beyond it rather than a reset. Tap targets go to 52pt, above the
44pt HIG floor, because the cost of a mis-tap on a screen carrying payment
instructions is not symmetric.

**Called "Bigger text" in every user-visible string.** Never "elderly mode",
never "parent mode", and no longer "Simplified mode": a switch should be named
for what it does, not for who somebody assumes is pressing it. The toggle lives
in Profile beside the Face ID lock, in **silver**, because it changes how Seal
looks and makes no claim about trust (§1.1).

**Copy must never branch on this flag.** If a sentence is clearer in plain words
it is clearer for everybody, and the technical version belongs in a Details
disclosure, not behind a type-size switch.

**It is presentation and nothing else.** Wire format, identity, friends,
signatures and directory behaviour are untouched, and no peer can tell whether
it is on.

### 6.1 Where the plain language went

The plain sentences written for the old mode are everyone's now, and every
technical counterpart stayed reachable. Full table in COLDSTART Part 2 §8.

- **Card bubble:** the "Sealed means this really came from X's phone" explainer
  and the scam pause on an inbound money card, both unconditional.
- **Card detail sheet:** one collapsed **Details** disclosure holding the
  fingerprint phrase, the signing key, the epoch and the sent time.
- **Chat verification drawer:** the plain encryption sentence at the top, and a
  **Details** disclosure holding the technical sentence verbatim, every member's
  fingerprint phrase, the read-aloud instruction and the epoch line.
- **Introductions** are available to everyone. They used to disappear whenever
  the old mode was on, which would have hidden a headline feature from anybody
  who turned the type up.

### 6.2 Demo

`-SealParentDemo` still forces the flag on for screenshots without writing the
keychain, so a demo launch cannot leave the setting behind on a real identity.
