# Prompt for Fable: redo Seal's first minute

Paste everything below the line into a new session with the Seal folder
connected.

---

You are rebuilding the onboarding for Seal, an iOS 26.5+ SwiftUI app in
`~/Documents/GitHub/Seal` (Mac "jasons-macbook-air-local"). I have no
compiler here. I build in Xcode and paste back errors and screenshots. Get
this right in one pass: read first, plan once, write carefully, and check
your own work before you hand it back.

## Read these first, in this order, before touching anything

1. `HANDOFF.md` (top sections, everything dated 2026-09-16)
2. `docs/PRODUCT.md` (all of it, section 7 and 9 most of all)
3. `docs/GOTCHAS.md`
4. `docs/RELEASE.md` sections 1 to 4, 9, 10, 11
5. `Seal/Views/Onboarding/SealOnboardingView.swift`, `OnboardingFigures.swift`,
   `SealMark.swift`, `GuardedRoleCard.swift`
6. `Seal/Views/RegistrationView.swift` (where first launch shows the
   onboarding), `Seal/ContentView.swift` (the backup key prompt after
   registration), `Seal/Views/BackupKeysView.swift` (`BackupKeyPrompt`),
   `Seal/Views/CoupleSetupView.swift`, `Seal/Views/SponsoredKeyView.swift`,
   `Seal/Views/SealPaywallView.swift`, `Seal/Store/SealPurchase.swift`,
   `Seal/Theme/ParentMode.swift`, `Seal/Theme/SealButtonStyle.swift`
7. Every place the onboarding is opened from: `RegistrationView`
   (`WelcomeCarousel`), `ProfileView` ("How Seal works"),
   `GuardedRoleCard` and `EstateHomeView` ("See how it opens", with an
   estate's real numbers).

## Why we are doing this

The first minute is the whole sale. Seal costs a one-time purchase, and
using it well also means buying a security key or two. Someone who opens
the app has to understand, before they are asked for anything:

- what Seal is for (the things only you know, for the people you leave
  behind: passwords, seed phrases, where the papers are, a letter);
- why it is safe (nobody can open anything early, not Apple, not us; one
  key alone reveals nothing);
- why it is worth paying for (it replaces a sticky note in a drawer or a
  password in a will that anyone can read once it goes to court, and the
  family gets a letter, the steps to take, and the secrets, in order);
- what they will actually do, tonight, for their situation.

The current onboarding was written before most of the features below
existed. It has good bones: two shared screens, a fork by role, one
figure per screen, skippable, re-openable, a Chapters menu. Keep that
shape. Rewrite the content and add the paths.

## The paths

The "Which one are you?" screen becomes four choices:

1. **Just me.** One person setting it up for their family.
2. **Me and my partner.** A couple, two phones, each holds a key for the
   other. Ends by pointing at "Set up with my partner" (`CoupleSetupView`),
   which already exists and runs after sign-up. Do not rebuild it.
3. **I was handed a key.** A key holder. Keep today's content, tightened.
4. **Someone wrote me an envelope.** A recipient. Keep today's content,
   tightened.

The two sealer paths (1 and 2) must, between them, teach every one of
these, each in one plain sentence or one screen, never all at once:

- An envelope per person: letter, photos, a voice message, a short video,
  the secrets, and "what to do first" steps.
- Seal notices a seed phrase typed into a letter and offers to move it
  somewhere safer.
- Opening the app is the check-in. Siri ("Check in with Seal") and the
  widget make it one tap.
- The rule: silence days, then daily warnings, then quiet grace days, then
  M of N key taps. One tap from the owner stops everything, with no key.
- One key alone sees nothing (the curve figure).
- Key holders are met in person and handed a security key. They confirm
  once a year that they still have it, and a printed page goes in the
  drawer with the key.
- **A backup key for yourself.** Right after sign-up Seal asks for one. Say
  why now: lose your only key and there is no email reset, by design.
- **Bills and medical.** A second, separate set with a shorter rule for
  the things that cannot wait. Opening it opens none of the letters.
- **Someone who is not on Seal yet.** You can write to a typed name
  tonight; the envelope waits until you meet. You can also register a
  spare security key for someone far away (sponsored key). Mention it in
  one line only; it has not been tested on real hardware yet.
- **Open on a date.** An envelope can be held until a birthday. Say
  exactly what it does: the recipient's app waits until that date. Never
  say it cannot be opened before.
- **If you delete your account**, Seal asks whether to keep the envelopes
  for your family or cancel them. One line, near the end.
- **What it costs, honestly.** The app is one purchase, once, for life.
  Show the real price from `SealPurchase.displayPrice` when it has loaded;
  never type a number into the code. Security keys are bought separately
  (a YubiKey is the example to name). Face ID works for everything, so a
  key is recommended, never required. Nothing is charged until the first
  time they tap Seal, and writing envelopes and adding people are free.
  No countdowns, no "most popular", no discount language.

The couple path adds: each of you writes your own envelopes, each of you
holds a key for the other, and "one more key holder each" is what makes
it safe if something happens to both of you at once.

End every sealer path with a short checklist of tonight's steps for that
path (the current `.steps` figure), then "Get started". The couple
checklist should say what happens on each phone.

## Rules that are not negotiable

- **No em dashes anywhere**: code, comments, copy, docs. Grep for the
  character before you finish.
- The user-facing word is **key holder**, never "custodian". Code names
  stay as they are.
- **Copy must read to a parent over sixty.** Short sentences, plain
  words, one idea per sentence, the plain thing first. Define any
  necessary term in the same sentence. Read every line aloud in your head.
- The house rule in `SealOnboardingView.swift`: never the word "will"
  (no promises about the future in that word). Keep it. Say "opens", not
  "will open".
- **Never promise what PRODUCT.md section 8 says is not promised.** Seal
  cannot know someone died; it knows they went quiet. Say "after a long
  silence", not "after you die". Do not say envelopes open "when you are
  gone" as a fact about death; say it as the purpose and pair it with the
  silence.
- The security promises in PRODUCT.md section 7 win over any nicer line.
- Brass marks a trust moment only. Silver is for things vouched for at a
  distance. The seal mascot never appears on a security surface.
- Every number comes from `OnboardingNumbers`, and every sentence reads
  right at a threshold of 1, 2 and 3 and at 1, 2 and 3 key holders (the
  current code shows how; keep that care).
- Bigger text mode (`parentTypeScale`, `parentTapTarget`) must work on every
  screen. Every screen scrolls. Apply `.containerRelativeFrame(.horizontal)`
  on scroll content (GOTCHAS "Layout").
- Skippable on every screen. The Chapters menu reaches every screen of
  every path.
- The onboarding touches no engine, no clock, no network, no keychain. It
  is a drawing. The one exception is reading `SealPurchase.displayPrice`
  from the environment for the price line, with a sentence that works when
  the price has not loaded ("one purchase, once, shown before you pay").
- Do not change `ReleaseMachine`, `ReleaseFeed`, `EstateLogVerifier`,
  `EstateEngine`, CloudKit record types, or the project file. New Swift
  files under `Seal/` join the target on their own.
- Keep every existing entry point working with the same call signature,
  or update every caller. `EstateHomeView` and `GuardedRoleCard` pass real
  numbers and a starting role; the new roles must still accept that.
- Keep the figures that exist. You may add at most two new figures
  (suggested: two phones side by side for the couple path; a spare key for
  the backup key screen). Draw them in SwiftUI in the style of
  `OnboardingFigures.swift`, animate once, respect Reduce Motion.
- Accessibility: every figure has an accessibility label that says what it
  shows in words.
- Do not run `git commit`. I commit myself.

## Tests

Tests live in `Seal/SelfTest` and run at DEBUG launch; a failed check is a
black screen. Add `OnboardingCopyTests.swift` (pattern
`.init(name:) { try fn($0) }`) and register it in `SelfTestRegistry.swift`:

- No screen, title, body or step on any path, at thresholds 1, 2 and 3 and
  key holder counts 1, 2 and 3, contains an em dash, the word "custodian",
  or the word "will" as a whole word.
- Each path has at least 3 screens and ends on a steps screen (sealer
  paths) or a keep screen (key holder, recipient).
- Screen ids are unique across all paths (the Chapters menu keys on them).
- The price sentence reads correctly with a price and with nil.
- At a threshold of 1 no key holder screen says one key "does nothing".

## When you are done

1. Grep the files you touched for the em dash character and for
   "custodian" in string literals.
2. Re-read every new line of copy once more for plainness.
3. Add a section at the top of `HANDOFF.md`: what changed, which files,
   what is uncompiled, what is most likely to fail to compile, and how to
   test it on a phone.
4. Tell me, in short numbered steps, what to build and what to tap to see
   each path, including Bigger text on, a threshold of 1, and opening it
   from You and from a key holder card.
