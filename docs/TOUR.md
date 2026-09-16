# The guided tour: requirements and design

**Version:** 0.1 (not built) · **Date:** 2026-09-16 · **Companions:** [PRODUCT.md](PRODUCT.md) · [SRS.md](SRS.md) · [SDS.md](SDS.md) · [GOTCHAS.md](GOTCHAS.md) · `Seal/Views/Onboarding/`

## 0. Read this first

This document is written for a person who has never heard of a security
key, a passkey, or encryption, and does not need to. Everything in Seal
can be understood with things from an ordinary house: a letter, an
envelope, a key, a drawer, a neighbour you trust, and someone who has
gone quiet for a long time. Wherever Seal has to use a word of its own,
this document says the ordinary thing first and the Seal word after.

The **onboarding** that exists today (`SealOnboardingView`) is a picture
book. It runs before you have an account, and it explains what Seal is
with drawings. It does not touch a real screen.

The **guided tour** this document describes is different. It runs on top
of the real app, the first time you arrive on a screen, and points at the
real buttons: a dark sheet over everything except one button, an arrow,
one sentence, and Next. "This is the Write button. Tap it to start a
letter." Then it steps aside and lets you tap.

The two are not rivals. The picture book answers "what is this and why
would I pay for it". The tour answers "which button do I press now".

## 1. The house, in Seal's words

| The ordinary thing | What Seal calls it |
|---|---|
| A letter you write for one person, with photos, a recording of your voice, and the things only you know (where the papers are, the code for the safe). | An **envelope**. |
| Sealing it shut so nobody, not even us, can read it. | **Seal**. The Seal button. |
| A neighbour you trust with a spare key to your house. | A **key holder**. |
| The spare key itself. A small metal thing on a keyring. It plugs into a phone or taps against it. | A **security key**. A YubiKey is one brand. |
| Handing that neighbour the key, in your kitchen, and both of you knowing it happened. | Meeting **in person** and the **handover**. |
| The rule you agree with your neighbours: "if nobody has seen me for three months, and you have knocked every day for three weeks, then two of you together may open the door." | **The rule**: silence days, warning days, quiet days, and how many keys. |
| You walking past the window every so often, so the neighbours know you are fine. | The **check-in**. Opening the app is the check-in. |
| A spare key to your own front door, kept somewhere safe, in case you lose the one on your ring. | A **backup key**. |
| A second, smaller box by the door with the bills and the medical papers, that the family can reach sooner. | **Bills and medical**. |
| The person a letter is for. | A **recipient**. |
| The pile of things this phone is minding for other people. | **For others**. |

Every sentence the tour says must be sayable using the left column only.
If a sentence needs the right column to make sense, it is not ready.

## 2. Purpose

TR-1 Show a person, on the real screen, which button does what, at the
moment they first need it, in one sentence each.

TR-2 Never take a decision for them and never take a tap for them. The
tour points; the person taps.

TR-3 Be over in under a minute per screen, skippable at every step, and
gone for good once seen, with a way to see it again from Help.

## 3. Who it is for

- The **owner**, the first time they see the home screen, the letter
  editor, the Keys tab, and the People screen.
- The **key holder**, the first time they open the For others tab and the
  screen for the person whose key they hold.
- The **recipient**, the same screen, in the words of their part.
- Half of them are over sixty (PRODUCT.md section 9). Bigger text, big
  targets, one idea per sentence.

## 4. What the tour is made of (the pieces)

### 4.1 One coach mark

A **coach mark** is one step of the tour. It is one picture on top of
the live screen, made of five things:

1. **The dimming.** Everything on the screen goes dark, like a stage
   with the lights down, except one spot.
2. **The spotlight.** A rounded hole in the dimming, drawn exactly around
   one real control on the screen, with a little breathing room. The
   control shows through at full brightness.
3. **The arrow.** A short curved arrow from the sentence to the
   spotlight. It points; it does not decorate.
4. **The sentence.** One line, in a small card, above or below the
   spotlight, whichever side has room. Never more than two short
   sentences. Written to be read aloud.
5. **Two buttons.** Next (or Done on the last step) and Skip. Both at
   least 52 points tall. Skip ends the whole tour for this screen.

The person can also tap the spotlighted control itself. Doing so counts
as Next and does what the control does.

### 4.2 One tour

A **tour** is an ordered list of coach marks for one screen. Each mark
names the control it points at by an id (see section 7). A tour runs
once per screen per identity, the first time the screen appears with
that control on it, and never again unless replayed from Help.

### 4.3 The house rules the tour must keep

- **Never over a security surface.** No coach mark ever covers or points
  at: the Seal button while a seal is in progress, "Delete identity",
  "Delete this envelope", "Start the claim", "Object", "Tap my key to
  confirm", the Face ID prompt, the payment sheet, or any secret's
  value. A mis-tap on those costs something. The tour can point at the
  Seal button while the envelopes are unsealed and nothing is running,
  because a tap there opens the payment sheet, which has its own "Not
  now".
- **Brass marks a trust moment only.** The spotlight ring and the arrow
  are white. Never brass.
- **The seal mascot never appears** on a coach mark.
- **No em dashes. Never the word "will". Never "custodian".** Same rules
  as every other string, checked by the same kind of test.
- **Never promises death.** "After a long silence", never "after you
  die".
- **Nothing in the tour reads or writes the engine, the clock, the
  network or the keychain.** The only state is "seen" flags (section 8).

## 5. The tours, step by step

Every sentence below is the exact copy. Numbers come from the real rule
(`OnboardingNumbers`) where a number appears. "Karen" stands for the real
name on that screen.

### 5.1 Home, first arrival (owner, nothing sealed yet)

Runs when: the Envelopes tab shows the setup card for the first time.

| Step | Points at | Says |
|---|---|---|
| 1 | The setup card's first row, "Write your first envelope" | "Start here. An envelope is a letter for one person, with the things only you know." |
| 2 | The Write button (floating, bottom right) | "This is Write. Tap it any time to start a new envelope." |
| 3 | The tab bar, Keys | "Keys is where you choose who can open your envelopes, and set your rule." |
| 4 | The tab bar, People | "People is where you add someone. You do it in person, with both phones out." |
| 5 | The "Watch it happen" button on the setup card | "If you want to see the whole thing as a picture first, tap this." |

Done label: "Got it".

### 5.2 The letter editor, first envelope

Runs when: `EnvelopeEditorView` appears for the first time on this
identity.

| Step | Points at | Says |
|---|---|---|
| 1 | The letter card | "Write here. Say what you would say if they were in the room." |
| 2 | The "what to do first" card | "These are the steps they should take first, in order. Call the bank, find the folder, that sort of thing." |
| 3 | The secrets card | "Passwords and codes go here, not in the letter. They are sealed exactly as you type them." |
| 4 | The photos card and the voice card, together | "A few photos and your voice. Both are optional. Your voice is the one they keep." |
| 5 | The Done or Back control at the top | "Nothing is sealed yet. It stays a draft on this phone until you tap Seal on the Envelopes tab." |

If the envelope is for a typed name (a person not on Seal yet), one
extra step at the start, pointing at the "not in Seal yet" line:
"This one waits. When you meet them and add them under People, it
becomes theirs."

### 5.3 Keys, first arrival (owner)

Runs when: the Keys tab appears for the first time.

| Step | Points at | Says |
|---|---|---|
| 1 | "The rule" button | "Your rule. How long a silence, how many days of warnings, and how many keys it takes. The defaults are sensible." |
| 2 | The key holders list (or its empty line) | "The people you hand a key to. Pick people who are easy to find in ten years." |
| 3 | The "Set up with my partner" card | "Doing this with your husband or wife? This walks you both through it, one step at a time." |
| 4 | The Letters and Bills and medical picker at the top | "Bills and medical is a second, smaller set that can open sooner. Its own key holders, its own rule." |

### 5.4 People, first arrival

Runs when: the People tab appears for the first time.

| Step | Points at | Says |
|---|---|---|
| 1 | "Your seal. Have them scan this." (the square code) | "Adding someone is done in person. They point their phone at this." |
| 2 | "Scan their seal" | "Or you point yours at theirs. Either way, both of you end up in each other's People." |
| 3 | "Register a key for someone who is not here" | "For someone far away or without an iPhone. You set up a spare key in their name and send it to them." |

### 5.5 A person's screen, first time you make someone a key holder

Runs when: `PersonView` appears and the person is not yet a key holder.

| Step | Points at | Says |
|---|---|---|
| 1 | "Make Karen a key holder" | "This gives Karen one of the keys. Do it with Karen next to you." |
| 2 | (after the button, on the next visit) "Karen confirms on this phone" | "Hand Karen this phone. Her tap here is the record that she took the key." |
| 3 | "A page to keep with the key" | "Print this and put it in the drawer with the key. It says whose key it is and what to do." |

Step 2 runs on the next visit to the same screen, because the button
only exists after step 1. The tour remembers which step it reached.

### 5.6 For others, first arrival (key holder or recipient)

Runs when: the For others tab appears for the first time.

| Step | Points at | Says |
|---|---|---|
| 1 | The first row | "This is what you are holding for Karen. Tap it to see where things stand." |
| 2 | "See how it opens" | "Not sure what a key holder does? This shows it as a picture, with Karen's real numbers." |

### 5.7 Karen's screen (`GuardedEstateView`), first arrival

Runs when: the screen appears for the first time for this estate.

For a key holder:

| Step | Points at | Says |
|---|---|---|
| 1 | The status card ("Karen last checked in ...") | "This is the only thing to watch. While Karen keeps checking in, there is nothing for you to do." |
| 2 | "The rule" card | "Karen's rule. Nothing can start until she has been quiet this long." |
| 3 | "Save a copy of this record" (the toolbar item) | "Once a year, save a copy. It is a file that proves everything, even if this app is ever gone." |

Nothing points at "Start the claim" or "Object". Ever.

For a recipient:

| Step | Points at | Says |
|---|---|---|
| 1 | "Written for you" card | "Karen has written you something. It stays sealed until the people holding her keys open it, after a long silence from her." |
| 2 | The status card | "You do not need to do anything. This app tells you when the time comes." |

## 6. Rules for every sentence

- Plain first. The Seal word, if needed at all, second.
- One idea per sentence. Two sentences at most.
- Reads right at a threshold of 1 (never "your key alone does nothing"
  to the one person whose key does everything).
- No number typed into the copy; numbers come from `OnboardingNumbers`.
- Every step has a VoiceOver label that says what is spotlighted and what
  the sentence says, so the tour works with the screen curtain on.

## 7. Design: how a coach mark finds the real button

This is the only hard part, and it is the part that decides whether the
spotlight sits on the button or three fingers to the left of it at
Bigger text.

### 7.1 Targets

Every control the tour can point at is marked in the view that owns it
with one modifier:

```swift
.tourTarget(.writeButton)
```

`TourTarget` is an enum with one case per pointable control (section 5
lists them all; there are about twenty). The modifier does one thing: it
publishes the control's frame, in the coordinate space of the screen,
through a SwiftUI **anchor preference**. An anchor preference is
SwiftUI's own way for a child view to tell a parent "here is where I
am". It updates itself when the layout changes, so Bigger text, rotation
and scrolling all keep the spotlight honest. Nothing is measured by
hand and nothing is guessed from a fixed number of points.

### 7.2 The host

Each screen that has a tour wraps its content once:

```swift
.tourHost(.home, targets: ..., seen: tourStore)
```

The host reads the anchor preferences, keeps the current step, and draws
the overlay above everything on that screen (`.overlay`, not a sheet, so
the real screen stays live and scrollable underneath). It converts the
current step's anchor into a rectangle and draws:

- a full-screen `Color.black.opacity(0.72)` with the spotlight cut out
  using a `.mask` and `blendMode(.destinationOut)` on a rounded
  rectangle inset by 8 points around the target;
- the sentence card, placed below the spotlight when there is at least
  140 points of room below it, otherwise above;
- the arrow as a `Path` from the card's nearest edge to the spotlight's
  nearest edge, a quadratic curve, 2 points, white, with a small
  arrowhead;
- Next/Done and Skip as `SealPrimaryButtonStyle` and
  `SealSecondaryButtonStyle`, with `parentTapTarget()`.

The overlay lets taps through only inside the spotlight (a
`contentShape` on the dimming that excludes the hole). A tap inside the
hole counts as Next and passes through to the control.

### 7.3 When a target is not on screen yet

Three cases, all handled, none of them by waiting on a timer:

1. **The target is below the fold** (a card further down a long
   screen). The host asks the screen's `ScrollViewReader` to scroll the
   target into view first (`proxy.scrollTo(id)`), then shows the mark.
   Every `tourTarget` is also an `.id()` for this reason.
2. **The target does not exist on this visit** (for example "Karen
   confirms on this phone", which exists only after the previous step).
   The tour skips to the next step whose target exists, and remembers
   the one it skipped so it can show it on the next visit (section 8).
3. **The target is a tab bar item.** The tab bar is drawn by the system,
   and a view inside a tab cannot publish the tab button's frame. For
   the two steps that point at tabs (5.1 steps 3 and 4), the spotlight
   is a rounded rectangle over the bottom strip at the tab's horizontal
   position, computed from the tab count and the screen width, and the
   sentence says the tab's name. This is the one place the geometry is
   estimated, and the comment in code says so. If it looks wrong on a
   phone, those two steps become text-only marks with no spotlight,
   which is still correct.

### 7.4 Bigger text and Reduce Motion

- Bigger text: the sentence card grows with Dynamic Type; the
  buttons are stacked, never side by side; the spotlight follows the
  control's real frame because it comes from the anchor.
- Reduce Motion: no fade between steps, no arrow draw-on. The mark
  appears whole.
- VoiceOver: the overlay is one accessibility element per step, label =
  "Step 2 of 5. " plus the sentence plus " Points at the Write button."
  Next and Skip are separate elements. The dimmed content underneath is
  `accessibilityHidden` while a mark is up.

### 7.5 What it never touches

`ReleaseMachine`, `ReleaseFeed`, `EstateLogVerifier`, `EstateEngine`,
CloudKit, the keychain, the project file. The tour reads names and
numbers that the screen already has and nothing else.

## 8. State: remembering what was seen

One small store, `TourStore`, in `UserDefaults`, keyed by identity hash
(the same shape as the couple's remembered partner in
`CoupleSetupView`): a name and a step number, not a secret.

```
seal.tour.<identityHash>.<tourName> = <highest step completed>
```

- A tour is due when its key is missing or its value is below the last
  step.
- Skip writes the last step, so a skipped tour never returns on its own.
- `ContentView.wipeLocalAndEngines` removes every key with the identity's
  prefix, per the house rule in GOTCHAS ("anything new that stores per
  identity must be added to `wipeLocalAndEngines`").
- Help gains "Show me around again", which resets every key for this
  identity, so the next visit to each screen runs its tour.
- Demo mode (`SEALDEMO`) never stores anything and runs every tour every
  time, because that is what the reviewer wants to see.

## 9. Order of building, with a build between each

Each phase is small enough to compile, run and look at before the next.
Nothing in a later phase changes the design of an earlier one.

1. **The piece.** `Seal/Views/Tour/CoachMark.swift`: `TourTarget`, the
   `tourTarget` modifier, the anchor preference key, `TourStore`, and
   `TourHost` with the dimming, spotlight, card, arrow and buttons. One
   `#Preview` with a fake screen and three fake targets. Build. Look at
   it at the largest text size and with Reduce Motion on.
2. **Home.** Mark five targets in `EstateHomeView`, wrap the Envelopes
   tab in the host, write tour 5.1. Build. Sign out and in to see it.
3. **The editor and Keys.** Tours 5.2 and 5.3. Build.
4. **People and the person screen.** Tours 5.4 and 5.5, including the
   "next visit" step. Build.
5. **For others and Karen's screen.** Tours 5.6 and 5.7, both roles.
   Build on Mom's phone too, because the key holder's tour is the one
   the pilot depends on.
6. **Help.** "Show me around again". Build.
7. **Tests.** `Seal/SelfTest/TourCopyTests.swift`, registered: every
   sentence at thresholds 1, 2 and 3 and key holder counts 1, 2 and 3
   has no em dash, no "custodian", no whole word "will"; every step's
   target is a `TourTarget` that the named screen actually marks (a
   static table per screen, checked against the tour); no tour points at
   a forbidden target (section 4.3, as a list in code); every tour has
   at least two steps; the store resets and skips correctly.

## 10. What could go wrong, said now

- **Anchors inside a `LazyVStack`.** A lazy stack does not lay out rows
  that are off screen, so an anchor for a row far down does not exist
  until it scrolls in. Section 7.3 case 1 handles it, but the Envelopes
  tab is a `LazyVStack` and the first build is where this is checked.
- **The tab bar estimate** (7.3 case 3). Honest fallback is text-only.
- **`.overlay` inside a `TabView`** sits inside one tab. The dimming
  therefore does not cover the tab bar itself. For the two tab steps
  the dimming stops at the tab bar and the spotlight is drawn as a ring
  rather than a hole. That is acceptable and simpler than reaching
  above the `TabView`.
- **Two tours wanting the same moment.** The home tour and the editor
  tour cannot both run at once because the editor is a sheet; the home
  tour pauses while a sheet is up and resumes at its step when the sheet
  closes.
- **A person who taps Skip on the first screen and then is lost.** Skip
  ends only that screen's tour. The other screens still get theirs. And
  Help has "Show me around again".

## 11. What is decided here, so it is not reopened

- The picture book stays. The tour does not replace it.
- The tour never automates a tap.
- Copy lives in one table per tour, next to the picture book's script,
  and is tested the same way.
- The spotlight comes from anchors, never from measured points, with the
  one exception in 7.3 case 3, written down.
- Nothing runs on a timer. Steps advance on Next, Skip, or a tap on the
  spotlighted control.
