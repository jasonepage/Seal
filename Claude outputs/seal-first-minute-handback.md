# Seal: the first minute. Handback

Uncompiled. Written without Xcode, reviewed by a second pass for compile risk, nothing found. Expect the first build to catch what reading cannot.

## 1. The approach

**Onboarding.** `WelcomeCarousel` keeps its name so `RegistrationView` and `ProfileView` compile untouched, but it is now a wrapper around `SealOnboardingView`. Two shared screens, then a fork by who is holding the phone. Screen one is the one true sentence about probate over the wax mark pressing in. Screen two asks "Which one are you?" with three plain buttons. The sealer path is six more screens, the key holder path four, the recipient path three. Each screen has one figure and teaches one thing the previous did not. A Chapters menu at the top jumps to any screen of any path, so a returning person does not page from one. Skip stays on every screen.

**Three finite figures.** A timeline that counts the ninety days, rings a bell through the twenty one days of warnings, runs the fourteen quiet days, and ends one of three ways: "a key holder may start a claim now", the owner's tap visibly resetting it to zero, or "keys can be tapped now". Three keys where two turn and the envelope opens only on the second. The Shamir picture: one point with a fan of possible lines through it, the second point appears, the fan collapses to one line and the secret lights up in brass on the edge. Every figure animates once on appear and stops. Nothing loops, nothing runs while the screen sits there. Reduce Motion shows the finished drawing with the same caption.

One honesty note on the Shamir figure: with a threshold of two the polynomial is degree one, a straight line, so the figure draws a line and the caption says "line". With a threshold of three it draws a parabola and says "curve". The figure interpolates the real polynomial (Lagrange form) through the points it shows, so the picture is the actual mathematics, not a sketch of it.

**Numbers.** Everything drawn reads from `OnboardingNumbers`, filled from `ReleasePolicy.defaultSilenceDays`, `defaultWarningDays`, `defaultGraceDays` and 2 of 3 on first launch, or from a guarded estate's snapshot policy and epoch when the explainer is opened from a home card. When the numbers are defaults rather than a real estate, the copy says "usually any 2 of 3".

**The mark.** `SealMark`: a wax disc with a deterministic uneven edge, a pressed rim, and a closed envelope glyph stroked into it. Lit from the upper left with a radial gradient so it has weight. Pewter by default. Brass only when `trust` is true, which registration sets at the ceremony's trust phase (the same rule the stock symbol followed) and the home card sets when the envelopes are sealed and closed. On the home card it carries one pulse ring on arrival, because opening the app is the heartbeat and the ring is the honest picture of what just happened. It runs once.

**No starfield, no curve on the home screen.** The mathematics lives in the explainer, one tap away from every role card. The home screen stays a Swiss bank and a family bible: the mark, the sentence, the rows.

**Recipient and key holder.** The old "Keys you hold for others" rows become `GuardedRoleCard`s, one per estate, written in the words of the part this phone plays. When the phone has nothing of its own and guards something for somebody else, those cards move to the top, then the "Do you have people you would do this for?" card, then the owner's sections under a soft "Your own envelopes" heading. No envelope count is printed anywhere, since the phone cannot know one before release. The "See how it opens" button presents the same onboarding, started on that role's path with that estate's real numbers. It touches no engine and no clock.

**The best moment.** On the owner's phone, the "Handover signed" alert becomes `HandoverDoneView`: the brass mark with its pulse (a two sided receipt is a trust moment), "Signed. Sarah holds a key now.", three plain things the key holder needs to know while still holding the key, and then the question, with "Show me how it works" opening the sealer path.

## 2. Files

New, under `Seal/Views/Onboarding/` (joins the target automatically):

| File | What |
|---|---|
| `SealMark.swift` | `WaxEdgeShape`, `EnvelopeGlyphShape`, `SealMark` |
| `OnboardingFigures.swift` | `OnboardingNumbers`, `ReleaseTimelineFigure`, `KeyShape`, `EnvelopeOpenFigure`, `KeysTurningFigure`, `LagrangeCurveShape`, `ShamirCurveFigure`, `KeyKeepFigure`, `SealedEnvelopeFigure` |
| `SealOnboardingView.swift` | `OnboardingRole`, `OnboardingScreen`, `OnboardingScript` (all copy), `SealOnboardingView`, and the `WelcomeCarousel` wrapper |
| `GuardedRoleCard.swift` | `GuardedRoleCard`, `GuardedDetailsLabel`, `PeopleYouWouldDoThisForCard`, `HandoverDoneView` |

Changed, full files written in place:

- `Seal/Views/EstateHomeView.swift`. New `explain` state and `ExplainRequest`; `guardsOnly` decides the section order; `statusCard` gains the mark (pewter before sealing, brass with one pulse when closed); `guardedSection` rebuilt on `GuardedRoleCard`; new `ownHeading`; `stateLine(.active)` reworded; unused `stateTint` removed; two pre-existing lines that used the auxiliary "will" reworded; `.fullScreenCover(item: $explain)` presents the explainer with `parentTypeScale()` like the other sheets.
- `Seal/Views/RegistrationView.swift`. The stock symbol is now `SealMark(size: 92, trust: phaseIsTrust)`; the sealed bump is 1.08 and skipped under Reduce Motion; reads `accessibilityReduceMotion`.
- `Seal/Views/PersonView.swift`. The "Handover signed" alert is now a sheet presenting `HandoverDoneView` with the owner's real policy and custodian count; reads `parentMode` to pass it on. One pre-existing "will" reworded.
- `Seal/Views/ForgeOnboarding.swift`. `WelcomeCarousel` removed with a pointer comment; everything else untouched.

Untouched, on purpose: `ProfileView.swift` (still calls `WelcomeCarousel { showHowTo = false }`), `SealTheme.swift`, `SealMascot.swift`, every crypto, engine, model and clock file, `Seal.xcodeproj`.

## 3. The copy, in full

Read aloud to check. No "will" except the noun in the probate line.

### Shared

**Your will becomes a public document.**
When a will goes through the court, anyone can read it. So a password or a seed phrase can never go in a will. That is what Seal is for. You write sealed envelopes for the people you leave behind. Nobody can open one early. Not Apple, not us.

**Which one are you?**
Seal looks different for each of these. Pick the one that fits and we show you only what you need.
- I am setting this up for myself. *I want to write envelopes and hide passwords.*
- Someone handed me a key. *They asked me to hold a small security key.*
- Someone wrote me an envelope. *I was told an envelope is waiting for me.*

### The sealer (defaults shown; the numbers are read from the rule)

**One envelope for each person.**
An envelope holds a letter, a few photos, a voice message, and the secrets: passwords, where the documents are, the combination. You write one for each person. Only that person can ever read it.

**Opening the app is your check-in.**
Each time you open Seal, your phone quietly notes that you are here. Nobody else sees a thing. If you go quiet for 90 days, one of your key holders can start a claim. Not before.
*Figure ends: "Day 90. A key holder may start a claim now. Not before."*

**21 days of warnings, and one tap stops everything.**
Once a claim starts, Seal warns you every day for 21 days, then waits 14 more quiet days. At any moment, one tap from you stops it cold. You do not need your key for that. A long stay in the hospital looks like silence from the outside, and the warnings are there for exactly that.
*Figure ends: "The owner tapped once. Stopped. Nothing opened."*

**Any 2 of your 3 keys open the envelopes.**
You hand a security key to 3 people you trust, in person. After all the warnings pass, any 2 of them tap their keys. Their phones combine the pieces. Then, and only then, the envelopes open on the phones of the people you wrote them for.
*Figure: "3 keys were handed out." "1 key turned. Still closed." "2 keys turned. Open. The other key was not needed."*

**One key alone sees nothing.**
Each key holds one point on a hidden line. One point alone could sit on any line at all, so one key holder learns nothing, not even a hint. 2 points fix the line, and where it meets the edge is the secret that opens everything. This is not a rule we made up. It is arithmetic, and it holds against us too.
*Figure: "One point. The line could be any of these. Nothing is learned." then "2 points fix the line. Where it meets the edge is the secret." and "The secret. It opens everything."*

**What you do now.**
It takes an evening. After that, opening the app now and then is the whole job.
1. Set up Seal with Face ID or a security key.
2. Meet each person face to face and add them.
3. Write an envelope for each of them.
4. Hand a key to 3 people and set your rule.
5. Tap Seal.
*Button: Get started*

### The key holder

**You cannot open anything. Nobody can.**
Your key holds one piece of a puzzle. One piece alone is no clue at all, not even a hint. That is arithmetic, not a promise. It is why the person who trusted you could hand you the key without a second thought.

**You are one of several.**
(defaults) The person who gave you the key gave keys to a few other people too. It takes more than one key to open anything, usually any 2 of 3. Your key alone does nothing, and that is the point.
(real estate) The person who gave you the key gave keys to 2 other people too. It takes any 2 of the 3 keys, tapped together, to open anything. Your key alone does nothing, and that is the point.

**What happens if they go quiet.**
If they stop opening Seal for 90 days, you may start a claim, and the other key holders are told. They get a warning every day for 21 days, then 14 more quiet days. If they are alive and open the app, it all stops. Only after all of that can keys be tapped.
*Figure ends: "Day 125. Keys can be tapped now."*

**Your job is to still be findable.**
Put the key somewhere you can find in ten years. A drawer you never clean out. A safe. With your passport. Keep Seal on your phone, and if you get a new phone, sign in again. That is the whole job. It may be years before anyone needs you, and that is good news.
*Figure caption: "Ten years, give or take. The key does nothing until then, and that is the job."* *Button: Got it*

### The recipient

**Someone wrote you an envelope.**
It is sealed. Nobody can open it early on your phone. Not Apple, not us, and not anyone holding a key. It opens here, and only after the person who wrote it is gone.

**How it opens.**
The person who wrote it opens Seal now and then. If they go quiet for 90 days, their key holders may start a claim. They are warned for 21 days, then 14 quiet days pass, and if they are alive one tap stops it. After all of that, usually any 2 of 3 key holders tap their keys, and the envelope opens here.

**Your job is simple.**
Keep Seal on your phone. If you get a new phone, sign in on it. You do not need a key, and you do not need to do anything else. When the time comes, the envelope opens on its own, and this app tells you. Until then, nobody, not even the key holders, can see what is inside.
*Button: Got it*

### Home screen, role cards

Headline by role: "Karen sealed envelopes for you." / "You hold a key for Karen." / "Karen sealed envelopes for you, and you hold one of the keys."

Recipient line: You can open them when the time comes. Nobody can open them early. Not Apple, not us, not anyone holding a key.

Key holder line: You cannot open anything with your key, and neither can anyone else with one. You are one of 3 key holders, and it takes any 2 together. (or, before the owner seals: You are one of several key holders, and it takes more than one key.) Your job is to keep this app installed and to still be findable in ten years.

Status, all quiet: "Karen checked in 3 days ago. Nothing for you to do." (key holder) / "Karen checked in 3 days ago. All is well." (recipient). Other states are in `GuardedRoleCard.status`.

Buttons: See how it opens. Details.

### Home screen, the question card

**Do you have people you would do this for?**
Your will becomes a public document. Your passwords cannot go in it. That is what Seal is for. Writing your own envelopes takes an evening, and this app is already on your phone.
*Buttons: Write an envelope. Show me how it works.*

### After the handover, on the owner's phone

**Signed. Sarah holds a key now.**
Both of you signed it. The record shows Sarah took a key from Karen today.

**Sarah, three things to know**
- You cannot open anything with this key. Nobody can with one key. It takes any 2 of Karen's 3.
- Put it somewhere you can still find in ten years. Then keep Seal on your phone.
- If Karen goes quiet for 90 days, this app tells you. Until then there is nothing to do.

**Do you have people you would do this for?**
Seal is already on your phone. When you get home, open it and write your first envelope. It takes an evening.
*Buttons: Show me how it works. Done.*

## 4. Decided not to do, and why

- **Phone number recipients.** Open judgement call in `HANDOFF.md`. Every screen assumes a recipient is a Seal identity met in person.
- **Time Travel as the demo.** It is DEBUG only and moves the real clock through `Clocks.setSimulated`. The explainer is its own drawing.
- **"Not Karen's phone" in the recipient copy.** The strategy draft had it. `PRODUCT.md` section 7 says the owner's devices can reach the content key, so that sentence would contradict shipped code. The card says "Nobody can open them early. Not Apple, not us, not anyone holding a key" instead.
- **Any envelope count.** Not knowable before release. "Envelopes", never "3 envelopes".
- **A new colour.** Pewter for the unsealed mark is `Color(white: 0.62)` with darker and lighter tones of the same grey for the gradient, which is the existing silver family, not a new hue. Orange for the warning segment is already the app's warning colour. Brass appears only on the finished mark, the owner's tap, the keys that open, the secret, and the closed status card.
- **A curve or particle field on the home screen.** The median user is sixty eight. The mark and one pulse are enough; the mathematics is one tap away.
- **Haptics in the figures.** The wax haptic belongs to a real tap, not a cartoon of one.
- **Deep linking "Get started" to the envelope editor.** On first launch the sealer has not registered yet, so the path ends at the registration screen, which is the real first step; the last onboarding screen lists writing the envelope as step three.
- **A Bigger text sweep of other screens.** Everything new uses `fixedSize(horizontal: false, vertical: true)`, stacked buttons, legend rows instead of labels under narrow segments, and `containerRelativeFrame(.horizontal)` on every scroll body. Please test at `.accessibility5` on a real device; the Shamir figure's point labels were left off for exactly this reason.

## 5. Things to check on the first build

- `parentTypeScale()` is applied once on each new sheet and full screen cover, following the pattern in `EstateHomeView`. `GOTCHAS.md` says the sheet inheritance question is unresolved; if type bumps twice inside the explainer, remove the modifier from the `.fullScreenCover` in `EstateHomeView` and `HandoverDoneView`.
- `ReleaseTimelineFigure` at `.silenceOnly` fills less than half the track by design; the next screen continues the same picture.
- The `WelcomeCarousel` from `ProfileView` starts at the front. If you want Help to remember the role, `SealOnboardingView` already stores `seal.onboardingRole` in `AppStorage`; wire `initialRole` from it in the wrapper.
