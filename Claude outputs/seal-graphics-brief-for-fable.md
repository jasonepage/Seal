# Brief for Fable: the first minute of Seal

You are working on a shipped iOS app called Seal. Two jobs, both visual, both
about the first minute somebody spends with it. Read all of this before you
write a line of Swift.

## What Seal is

One person writes sealed envelopes for the people they will leave behind. A
letter to each of them, and the practical things nobody else knows: the
passwords, where the safe deposit key is, the combination to the gun safe, the
seed phrase. They hand a physical security key to two or three people they
trust. They set a rule. Then they open the app now and then, which is how the
app knows they are alive.

If they go quiet for ninety days, a key holder can start a claim. The owner
then gets warned every day for three weeks, then two more weeks of silence,
and at any moment one tap from the owner stops everything and needs no key at
all. Only after all of that can two of the three key holders tap their
physical keys and open the envelopes on the recipients' phones.

Nobody can open one early. Not Apple, not the people who made it. The
mathematics is real: each envelope is encrypted, the key that opens everything
is split by Shamir's scheme over the finite field GF(256) into shares, and no
two shares together reveal a single bit until the threshold is met.

## Who is holding the phone, which is the heart of job 2

Three completely different people install this app, and today all three see
the same three screens written for the first one.

1. **The sealer.** Usually the oldest person in the family. They bought this.
   They want to write letters and hide passwords and be sure it works after
   they are dead. They are frightened of doing it wrong.
2. **The key holder, called a custodian in the code.** Their father handed
   them a small metal key at Thanksgiving and said "put this somewhere safe."
   They install the app because he asked. They will then do nothing at all for
   possibly fifteen years. The single most important thing they need to
   understand is that they cannot open anything, that they are one of several,
   and that their job is to still be findable later.
3. **The recipient.** Someone wrote them an envelope. They may not know it
   exists. One day it opens on their phone, on the worst week of their life.

Nothing in the product currently speaks to the second or third person. The
existing onboarding is written entirely in the sealer's voice: "For the things
you never told anybody." A daughter who installs Seal because her dad asked
her to hold a key reads that and has no idea what she is looking at.

## Job 1: the onboarding

Currently `WelcomeCarousel` in `Seal/Views/ForgeOnboarding.swift`. Three
static panels: an SF Symbol, a headline, a paragraph, Next, Next, Get started.
It is shown once on first launch and again from You then Help then How Seal
works.

It is not good enough. It states three facts and teaches nothing. Somebody who
taps through it cannot tell you what they are supposed to do next, cannot
explain the app to their spouse, and if they are a key holder they do not
learn that their job is to do nothing for years.

What it needs to do:

- **Show the mechanism, not slogans.** The ninety days, the three weeks of
  warnings, the two of three keys. These are the product. A person should
  come out able to draw the timeline on a napkin. Motion is the right tool
  here: a countdown that actually runs, an owner tap that visibly stops it,
  two of three keys turning and the envelope opening only on the second one.
- **Branch by role, early.** One question near the front, in plain words,
  something like "Are you setting this up for yourself, or did someone hand
  you a key?" Then the path differs. The key holder's path is shorter and
  ends with "put the key somewhere you will still find it in ten years, and
  keep this app installed." The sealer's path ends at writing their first
  envelope.
- **Be re-openable and skippable.** It is already both. Keep that. Somebody
  who skips must be able to get back to it, and somebody who comes back must
  be able to jump to the part they want rather than paging through from one.
- **Earn its length.** More than three screens is fine. Ten screens of the
  same thing is not. Every screen must teach one thing the previous screen
  did not.

## Job 2: the home screen and the mark

`Seal/Views/EstateHomeView.swift` and `Seal/Views/RegistrationView.swift`.

The mark today is `Image(systemName: "seal.fill")`, a stock Apple symbol in
flat grey. For an app named Seal, whose entire proposition is that something
is closed and cannot be opened early, a stock symbol is a wasted opportunity.
It does not look like a seal pressed into wax, it does not look like anything
anybody chose, and on the registration screen it is the first thing a person
sees.

There is already a hand-drawn seal, the animal, in `Seal/Views/SealMascot.swift`,
a real bezier silhouette. House rules say the animal appears on social
surfaces only and never on a security surface, so it is not the answer for the
registration screen or the home header. It is there for reference on drawing
quality and as a thing not to duplicate.

What the owner of this app asked for, in his words: an animated home screen
with "crypto stars and math."

Take the instinct and reject the cliché. A generic particle starfield would
make a will look like a token launch, and the median user is sixty-eight years
old and already nervous. But the underlying instinct is right and there is
something real to draw, because the mathematics in this app is genuinely
beautiful and genuinely load-bearing:

- **Shamir's scheme is a picture.** A secret is the point where a curve meets
  the vertical axis. Each key holder holds one other point on that curve. Any
  two points and the curve is determined and the secret falls out. One point
  and it could be any curve at all, which is not a metaphor for security, it
  IS the security. This can be drawn, and it can move, and a person who
  watches it for four seconds understands threshold cryptography.
- **The seal closing.** Wax, a press, a mark that is now a mark. Brass on
  near black. It should feel like weight, not sparkle.
- **The heartbeat.** The whole product runs on the owner opening the app. A
  quiet pulse that resets when they arrive is honest and calm.

Pick what serves. It should look like a Swiss bank and a family bible, not
like a trading app. If a sixty-eight year old woman would not describe it as
"dignified," it is wrong.

## Hard constraints, all of them

- **SwiftUI only. No new dependencies of any kind.** No Lottie, no Rive, no
  packages. Shapes, paths, canvas, TimelineView, shaders and native animation.
- **Do not hand edit `Seal.xcodeproj`.** New Swift files under `Seal/` join
  the target automatically. No new asset catalogs, no imported image files:
  anything you draw, draw in code.
- **iOS 26 SDK, Swift 5 language mode.**
- **No em dashes anywhere.** Not in copy, not in comments, not in this
  document's descendants. This is a standing house rule and it is absolute.
- **Plain words.** Half the users are over sixty. The developer's own mother
  is a tester. Every sentence should survive being read aloud to her. Do not
  write "cryptographic threshold," write "any two of the three."
- **Colors.** `Seal/Theme/SealTheme.swift`. Ink `#0C0E12` is the background.
  Brass `#D9A441` marks a trust moment ONLY and is never decoration. Silver is
  for anything vouched for at a distance. If you want more colors, say why.
- **Respect Reduce Motion.** Every animation needs a still, legible fallback
  through `@Environment(\.accessibilityReduceMotion)`. A person who turned
  that on must lose nothing but the movement.
- **Respect Bigger text.** The app has its own type bump on top of Dynamic
  Type, see `Seal/Theme/ParentMode.swift`. Nothing may clip or overlap at
  accessibility sizes. Test your layouts at `.accessibility5`.
- **Battery and heat.** This runs on an iPhone in an old woman's handbag. A
  full-screen sixty frames per second particle system on the home screen is
  not acceptable. Animate on entry, settle, and stop. Nothing should run
  forever while the screen is just sitting there.
- **No new cryptographic primitives and no changes to any crypto file.** This
  job is pixels. If a drawing needs a value, read it from the model, do not
  invent one.
- **There is no compiler in your environment.** Write carefully, write
  complete files, and expect a human to build it in Xcode and send back
  errors and screenshots.

## What to hand back

1. A short note on the approach before the code, so it can be argued with.
2. Complete Swift files, not fragments. Say exactly which existing files
   change and give the full replacement for any function you touch.
3. The onboarding copy in full, so it can be read aloud and checked.
4. Anything you decided not to do, and why.

## Where to look first

- `docs/PRODUCT.md` sections 1 through 9. Section 2 is the story to build
  against and section 9 is the rule about plainness.
- `docs/RELEASE.md` for the exact timeline you are drawing.
- `docs/GOTCHAS.md`, the house rules at the bottom, especially the brass and
  silver rule and the note about copy that contradicts shipped code.
- `Seal/Views/ForgeOnboarding.swift`, `Seal/Views/EstateHomeView.swift`,
  `Seal/Views/RegistrationView.swift`, `Seal/Views/SealMascot.swift`,
  `Seal/Theme/SealTheme.swift`.
