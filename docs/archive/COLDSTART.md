# Cold Start

**Version:** 0.1 · **Date:** 2026-08-28 · **Companions:** [UI.md](UI.md) · [VISION.md](archive/VISION.md) · `Seal/Views/ForgeOnboarding.swift` · `Seal/Views/RegistrationView.swift` · `Seal/Views/ChatsView.swift` · `Seal/Views/FriendsView.swift`

The positioning this document assumes: **Seal is for the things you cannot
afford to send to the wrong person.** A photo, a wallet address, an account
number, a password, a passport scan. The shared property is that the damage is
permanent and you cannot take it back. That widens the current site line ("if
it's about money and it isn't sealed, it isn't me") without discarding it.

The shell this document assumes: **one shell.** Simplified is the baseline for
everyone, and the deep surfaces (verification drawer, history, receipts, backup
keys, device list) move behind an Advanced section rather than being deleted.

## 1. What a new person hits today

1. Installs Seal. Sees a three panel welcome carousel.
2. Registers. The prominent button is "I have a security key". They do not have
   one. The second button is Face ID.
3. Lands on the chat list. It is empty and says "No colonies yet. Forge a friend
   in Circle, then haul out here together."
4. If Simplified mode is on, it says "Whoever set up this phone adds people for
   you", and the Circle tab is not there at all.
5. To add anyone, the other person must already have Seal installed, and both
   people must be in the same room.

There is no step in the app that helps with step 5. That is the cold start
problem in one sentence.

## 2. The five holes, worst first

### 2.1 There is no way to bring the other person in

Nothing in the app invites anyone. No share sheet, no link, no message. Searched
the whole target: the only `ShareLink` instances are in the history view and the
receipts view, and they share evidence of past events, not an invitation.

So Seal only grows when the person you want already installed it for some other
reason. For a family anti-scam pitch that was survivable, because you set up
your parent's phone yourself. For a self serve app it is fatal.

### 2.2 The app tells you to run the ceremony twice, and that stopped being true

`ForgeHowToCard` step 4 says: *"Then swap and do it once more on their phone, so
you can both message."* The doc comment on `FriendsView` says the same thing.

`ForgeHandshake.swift` removed that. The second run is now automatic: the phone
that ran the ceremony publishes a device signed handshake, the other phone picks
it up on its next refresh and completes the friendship with zero user actions.
The file's own header calls the doubling "the single largest source of friction
in onboarding."

So the app is still charging the friction it already paid to remove.

### 2.3 First run leads with cost instead of reason

The welcome carousel is: your key is your identity, friends are made in person,
nothing is recoverable. Two of those three are warnings. A person who installed
this to send one private photo hears a rule, a restriction and a threat before
they hear a single reason.

### 2.4 "Nothing is recoverable" is now false

The registration footer says "Nothing is recoverable — by design" and carousel
panel three says "not even we can bring it back."

Backup keys shipped. `BackupKeyCopy.notMessages` states the real position: a
backup key brings back who you are, the same name and the same seal, but it does
not bring back chats or the friend list. The onboarding is scarier than the
product, which is the wrong direction for a scary claim to be wrong in.

### 2.5 The empty state is a dead end in the mode that is becoming the default

Simplified mode's empty state tells the user to wait for someone else. Once
Simplified is the only shell, that is the first thing every new user reads, and
it is now wrong for most of them.

## 3. The fixes

### 3.1 Add someone, including people who do not have Seal yet

The chat list gets a real primary action, not a menu item: **Add someone**. It
opens a sheet with two paths.

**Path A, they have Seal.** Goes straight to the existing scanner. No change to
the ceremony.

**Path B, they do not have Seal yet.** A share sheet. Proposed message:

> I'm moving the private stuff off text messages. Seal only works between people
> who set it up face to face, so grab it and we'll take two minutes next time
> we're together. sealmessenger.com

Link target is `sealmessenger.com`, never a TestFlight or App Store link
directly. The site already exists, it is already the WebAuthn relying party
domain, and routing through it means the invitation never breaks when the
distribution channel changes.

Sheet copy above the two buttons:

> Seal takes two people and one phone, once. After that you can message from
> anywhere.

### 3.2 Rewrite the welcome carousel

Three panels. Reason first, rule second, expectation third.

**Panel 1** · symbol `lock.shield.fill` · brass

> **For the things you can't send twice**
>
> A photo. A wallet address. An account number. Once it reaches the wrong
> person, you can't take it back. Seal is built for exactly those messages.

**Panel 2** · symbol `hand.tap.fill`

> **Nobody can pretend to be your person**
>
> There's no username to spoof and no phone number to fake. You add someone by
> standing next to them, once. After that, every message from them is provably
> from them.

**Panel 3** · symbol `person.2.fill`

> **Two people, together, once**
>
> That's the whole setup. A couple of minutes side by side, and then it works
> from anywhere. If the person you want isn't with you yet, invite them and do
> it when you meet.

Panel 3 replaces the "nothing is recoverable" panel. The recovery honesty is not
lost: it moves to the registration footer (3.3) and it already has a blocking
full screen prompt of its own in `BackupKeyPrompt`, which is a better place for
it because the person is holding their key at that moment.

### 3.3 Registration screen

Swap the button order. Face ID becomes the prominent action, the security key
becomes the second one.

- Primary: **Set up with Face ID**
- Secondary: **I have a security key**

The hardware key is an upgrade, not a gate. Making it the first thing on screen
tells most people they are in the wrong app.

Footer replacement, replacing "Nothing is recoverable — by design":

> Your key is your identity. People are added in person. A backup key can bring
> your identity back. Your messages can't come back.

Status line for the idle phase, replacing "Group chat for people you've actually
met":

> For the messages you can't afford to send to the wrong person.

### 3.4 Empty state

One version, no Simplified branch:

> **No chats yet.**
> Seal only works with people you've set up in person.

Below it, a real button: **Add someone**, which opens the 3.1 sheet.

Delete "No colonies yet. Forge a friend in Circle, then haul out here together."
Delete the Simplified variant "Whoever set up this phone adds people for you."

### 3.5 Fix the how-to card

Title: **Adding someone takes two people and one phone**

1. Stand together. Open Seal on both phones.
2. They show their seal. You scan it on this phone.
3. They prove their key right here, with a tap or with Face ID on their own
   phone.
4. That's it. You're both connected. Their phone catches up on its own.

Step 4 replaces the instruction to swap phones and run it again.

## 4. Words to retire

Change the strings a person can read. Leave every code identifier alone.

| In the interface today | Becomes |
|---|---|
| Forge (verb) | Add, or set up |
| Forge log | History |
| Circle (tab) | People |
| Colony, colonies | Group, groups |
| Haul out | (delete) |
| Brass, silver (as tier words) | Verified, standard |
| Endorsement | Approved by your key |
| Seal (the QR code) | keep, it is the brand |

## 5. Files this touches

| File | Change |
|---|---|
| `Views/ForgeOnboarding.swift` | New carousel copy (3.2), how-to card fix (3.5) |
| `Views/RegistrationView.swift` | Button order, footer, status line (3.3) |
| `Views/ChatsView.swift` | Empty state plus the Add someone button (3.4) |
| New: `Views/AddSomeoneSheet.swift` | The two path sheet (3.1) |
| `Views/HomeView.swift` | One shell, Advanced section routing |
| `Views/FriendsView.swift` | Stale doc comment, tab title, vocabulary |

## 6. Deliberately not changing

- The ceremony itself. It works and it is the moat.
- The requirement to meet in person. That is the product, not the friction.
- The deep surfaces. They move behind Advanced, they do not get deleted.
- Any wire format, signature, record type or schema. This is all presentation.

---

# Part 2: The shell merge

Decided 2026-08-28. One shell, no tab bar, evidence behind Advanced.

## 7. What happened to the four tabs

| Was | Is |
|---|---|
| Chats tab | The app. There is no tab bar. |
| Camera tab | The composer inside a chat, which is where a photo was always going. |
| Circle tab | A people button in the chat list toolbar, plus "Add someone" in the compose menu. Renamed People. |
| You tab | The identity ring in the leading toolbar slot, opening Profile as a sheet. |

`HomeView.fullShell` is deleted. `parentShell` became `shell`.

## 8. What the old Simplified mode flag means now

It means **bigger text and bigger tap targets**, and nothing else. The switch is
labelled "Bigger text". The type `ParentMode` and the keychain key
`seal.parentmode.<hash>` are unchanged so nobody's setting is lost on upgrade.

The rule that follows, written into ParentMode.swift: **copy must never branch
on this flag.** If a sentence is clearer in plain words it is clearer for
everybody, and the technical version belongs in a Details disclosure, not
behind a type-size switch.

Every copy branch that existed has been resolved to the plain version. In each
case the technical material was already reachable and stays reachable:

| Was | Now | Where the technical version lives |
|---|---|---|
| `CardBubble`: parent explainer and scam pause on inbound money cards | Everyone | n/a, it was never hidden from anyone by choice |
| `CardBubble`: `parentDetailsBlock` or `keyBlock` | Always `parentDetailsBlock` | It is a collapsed Details disclosure that CONTAINS keyBlock plus the fingerprint phrase |
| `CardBubble`: fingerprint phrase inline under the sender | Removed from the bubble | Inside that same Details disclosure |
| `ChatView`: encryption sentence | Plain version | The drawer's own Details disclosure, verbatim |
| `ChatView`: fingerprint phrase fallback row | Removed | `parentDetails`, which lists every member's phrase |
| `ChatView`: "keys rotated N times" | Removed from the top level | `parentDetails` |
| `ChatView` and `FriendsView`: Introduce hidden in Parent Mode | Shown to everyone | n/a |
| `IntroductionCard`: linked title and vouch line | Plain version | n/a, the plain version says the same thing |
| `BackupKeysView`: "the family helper's key" | "Add a backup key" | n/a. The flag no longer knows whether anyone else is involved |

## 9. Advanced

`ProfileView.advancedScreen`, one tap below Profile. Holds the identity card
(Seal, Directory, This device), the device list, the backup keys panel, the
ceremony History and the Handovers receipts. The last two used to hang off the
Circle toolbar as two unlabelled brass glyphs and now get a name and a sentence
each.

**The backup-key warning did not move.** Having no backup key is the state that
costs someone their identity, so Profile keeps a standing orange row in plain
sight when there is none, and that row taps through to Advanced. Burying the
warning with the panel would have missed the point the old code made correctly.

## 10. Navigation titles

Large titles are off. `Chats`, `People`, `You` and `Advanced` all use
`.navigationBarTitleDisplayMode(.inline)`, so the title sits in the bar beside
the buttons instead of eating a third of the screen above the content.

## 11. Still to do

- The words in section 4 are only half retired. Done: the empty state, the
  welcome carousel, the how-to card, the registration screen, the People title,
  "How adding someone works". Not done: "forge" inside the ceremony stages and
  the history screen, "colony", the brass and silver tier words.
- `docs/UI.md` still describes the four-tab shell and a Parent Mode section.
- Nothing here is built or tested beyond compiling. See HANDOFF.

---

# Part 3: The site and the listing

Done 2026-08-28. The invite sheet built in Part 1 points at `sealmessenger.com`,
so the landing page stopped being marketing and became part of the product: it
is the first thing a person sees after a friend invites them.

## 12. What was wrong

The page was written for the family anti-scam pitch. Someone who received
"I'm moving the private stuff off text messages" and tapped the link landed on
a page about elderly relatives, cloned voices and wire fraud. Two different
products, and the site is the half a stranger sees first.

## 13. What the page says now

- **An invited-you strip above the hero**, because that is the main traffic
  source now: install it, then set it up together the next time you are
  actually with the person who invited you, about two minutes, once.
- **Headline:** "Some messages you can't unsend. Those are the ones that need a
  Seal." The lead paragraph names the photo, the wallet address and the account
  number, then the claim only Seal can make: there is no wrong person on the
  other end.
- **The money rule survives** in its box, reframed as one example of the idea
  rather than the whole pitch. It is the best line on the page and it did not
  need replacing, only widening.
- **A new "What Seal does not do" section.** It says the app cannot judge
  whether a request is wise, cannot know whose hands the phone is in, and cannot
  stop a second camera pointed at a screen. Somebody arriving for the private
  photo case will assume screenshots are impossible unless told otherwise, and
  letting them assume it would be the dishonest kind of quiet.

`site/support.html` gained "Somebody invited me to Seal, what do I do?", "What
is Seal for?" and "Do disappearing messages really disappear?", and its Android
answer no longer assumes the reader has a family in mind. `site/privacy.html`
needed nothing: it was written about mechanics, not about the pitch.

## 14. Deploying

`npx wrangler deploy` from the repo root. The site is live with the OLD copy
right now, which means every invite sent before that deploy lands on the wrong
page.

## 15. The listing

`docs/STORE_COPY.md` holds paste-ready App Store Connect copy: name, subtitle,
promotional text, keywords and description, with character counts. The current
listing is still "Seal: Provably Human Chat", which is the anti-bot pitch from
VISION.md and matches neither the app nor the site.

Three rules that copy follows and any future copy must too: intimate photos are
never named (Guideline 1.1.4 and 1.2), the post-quantum claim stays out until
`HybridKEM.swift` earns it, and the honest-limits paragraph is not optional.

---

# Part 4: The polish pass

Done 2026-08-28, after the first device walkthrough.

## 16. One door, not three

Adding a person could be started from the people button in the chat list
toolbar, from "Add someone" in the compose menu, and from the chat list's empty
state, and two of those opened `AddSomeoneSheet`, which then opened
`FriendsView`. Three doors, two rooms, one of them a corridor.

Now: the **people button** is the only entry. `AddSomeoneSheet` is deleted and
the invite path it carried moved into `FriendsView`, which is where everything
about people already lived. The compose menu is composing only, and the empty
state's button opens the same people sheet.

`FriendsView` header, rebuilt for one loud button:

1. Your seal in a card of its own, 158pt, with "Your seal. Have them scan this."
2. **Scan their seal**, brass, the only prominent control on the screen.
3. **Invite someone who doesn't have Seal**, bordered. Not brass: sending an
   invitation proves nothing and taps nobody's key.
4. **Introduce two people**, silver, only once there are two people to introduce.
5. "How adding someone works" as a footnote.

## 17. The tutorial is reachable again

`WelcomeCarousel` ran once, behind `@AppStorage("seal.welcomeSeen")`, which
meant the explanation of what Seal even is became unreachable the moment
somebody tapped through it on first launch. Profile now has a **How Seal works**
row above Advanced that replays it.

## 18. Open question: two identical introduction cards

A device walkthrough showed the same "Annie is in your chats now" card twice in
one chat. This is **not** the receive-path dedupe failing. That check compares
`statement.commitmentHex` and is correct, and its comment deliberately allows a
re-send to reappear after the first card burns on a TTL.

Two identical-looking cards means two genuinely different statements for the
same pair, which the dedupe does not cover because it was never asked to. The
fix is a decision about the feature, not a rendering tweak:

- **Option A.** Suppress a new offer when a live card for the same pair, same
  introducer, is already in the chat. Simple, and it makes a deliberate second
  introduction silently vanish.
- **Option B.** Collapse cards for the same pair at render time and show the
  most recent. Keeps every statement in the transcript, costs a grouping pass.
- **Option C.** Refuse to create a second introduction for a pair that is
  already linked, at the send end, where the person can be told why.

Undecided. C is the most honest and the furthest from the rendering layer.

## 19. The screen you could drag sideways

Profile panned horizontally: the whole scroll content was wider than the
viewport, so the cards ran off the right edge and the toggles were unreachable.
It showed up with Bigger text on, which is the clue: a vertical `ScrollView`
does not constrain its content's width, so any child that demands more room
than the screen quietly widens the content and the screen becomes draggable.

Fix, in `ProfileView`:

1. `.containerRelativeFrame(.horizontal)` on the scroll content, on the main
   screen and on Advanced. That pins the content to exactly the scroll view's
   width, so there is nothing left to pan.
2. The display name is `lineLimit(1)` with a `minimumScaleFactor`, so a long
   name shrinks instead of pushing the layout wider.
3. The fingerprint phrase wraps and is centered with horizontal padding. It is
   meant to be read aloud, so running off the edge was the worst outcome.

**The same risk lives in 13 other vertical scroll views**, listed by a grep for
`ScrollView` across `Seal/Views`. The likeliest to exhibit it are the ones that
render monospaced key material at a size the user can enlarge: `BackupKeysView`
(three of them), `ReceiptsView`, the card detail sheet in `CardBubble`, and the
verification drawer in `ChatView`. Not swept yet, deliberately: it is a
one-line change per screen but each one is a layout that wants looking at on a
device before and after.
