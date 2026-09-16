# App Store listing copy

**Date:** 2026-09-16 · **Companions:** [PRODUCT.md](PRODUCT.md) · [HANDOFF.md](../HANDOFF.md)
**Supersedes:** [archive/STORE_COPY.md](archive/STORE_COPY.md) (the messenger)

The live listing is two pivots behind the app. It says **"Seal: Provably Human
Chat"**, subtitle **"Provably human group chat"**, category **Social
Networking**, which is the anti-bot messenger from VISION.md. The messenger
was retired in the phase 7 commit on 2026-09-15.

Nothing has shipped yet (1.0 Prepare for Submission), so every field here is
free to change with no version bump and no migration.

Character limits are Apple's. Counts are in brackets. Keywords take no space
after the comma, because a space costs a character.

## What Apple actually indexes

The **name**, the **subtitle**, the **keywords field**, and the developer
name. **Not the description.** So the description is for the person deciding,
and those three fields are for being found. Do not repeat a word across them:
Apple combines them, and a repeat spends a slot for nothing.

## Name (30 max)

```
Seal: Digital Legacy Vault
```
[26] "Digital legacy" is the phrase this category is named by, and "vault"
carries the intent. "Seal" alone is unsearchable, it is a common noun and an
animal.

Alternatives, if the pitch should lead with feeling rather than the category:

- `Seal: What You Leave Behind` [27]
- `Seal: Password Inheritance` [26] (fights password managers, and loses)
- `Seal: Sealed Envelopes` [22] (says nothing anybody searches for)

## Subtitle (30 max)

```
The passwords you leave behind
```
[30, exactly at the limit] Carries "passwords", which the name does not, and
says the whole product in five words.

Alternatives: `Passwords and letters, sealed` [29] · `Sealed until you are
gone` [25]

## Keywords (100 max, comma separated, no spaces)

```
will,estate,inheritance,executor,heir,trust,death,dead,man,switch,secret,note,letter,seed,phrase
```
[96] No word here appears in the name or the subtitle.

"will" is the noun, and it earns its place: it is the highest volume search
term this product is adjacent to, and the pitch is precisely that a password
cannot go in one. The house rule bans the auxiliary verb in app copy, not the
noun that sells the thing.

"dead,man,switch" as three words rather than one phrase, because Apple
combines keywords into phrases on its own.

## Promotional text (170 max, editable with no new build)

```
Your passwords cannot go in your will, because a will filed for probate becomes a public court record. Write a sealed envelope instead. It opens only after you are gone.
```
[169]

## Category

**Primary: Productivity. Secondary: Lifestyle.**

Changing off Social Networking is not cosmetic and is the most important line
in this document.

A listing in Social Networking tells App Review to expect user generated
content, and UGC brings its own obligations: moderation, a way to block, a way
to report, a EULA, and a 24 hour response commitment. The app has no messaging
any more. Staying in that category invites a whole conversation about a
feature that does not exist, and the block and report code still sitting in
FriendsView from the messenger makes it look like it does.

Productivity is the honest neighbour: password managers, document vaults,
getting your affairs in order. It is a brutal category to rank in, which is
why the name and keyword fields above are doing the real work rather than
browse placement.

Lifestyle as secondary, because the buyer is a person planning for their
family, not a person shopping for a tool.

## Description

```
Some things cannot go in a will.

A will filed for probate becomes a public court record. Anyone can read it. So
the password to your bank, the phrase that opens your crypto wallet, where the
safe deposit key is, the combination, the thing you never told anybody: none of
it can go in one.

Seal is where those things go instead.

WHAT IT IS

You write a small number of sealed envelopes, one for each person. An envelope
holds a letter, a few photos, a voice message, and the secrets. You choose a
few people you trust. You set the rule for how the envelopes open after you
are gone. Then you open the app now and then, and that is the whole ongoing
job.

NOBODY CAN OPEN ONE EARLY

Not Apple. Not us. An envelope is encrypted on your phone before it leaves it,
and the key is split into pieces so that no single person holds it. It takes
several of the people you chose, acting together, after a long silence from
you, after weeks of daily warnings that one tap from you stops cold.

A long stay in hospital looks the same as death from the outside. The warnings
exist for exactly that.

WRITING IS THE HARD PART, SO SEAL HELPS

The way this goes wrong is not the cryptography. It is an empty vault that
opens perfectly. So Seal asks you questions, one at a time, and turns your
answers into a draft you then edit. You can talk instead of typing.

Nothing you write or say in that part leaves your phone. There is no account
and no server in it. Your voice becomes words on the phone itself, or not at
all.

BUILT TO OUTLIVE US

The record of who did what, and when, is signed and checkable. Anyone holding
a piece of your key can export an archive of it, and a short script with no
Seal in it can verify every signature. If this company disappears, the
envelopes still open.

WHAT SEAL DOES NOT PROMISE

That silence means death. Silence is silence, which is why the warnings run
for weeks.

That we can vouch for who anybody is. Seal proves that the same person you
stood next to is the one acting later. Binding a face to a passport is what
notaries are for.
```

## The rest of the listing, which was also filled in for a messenger

1. **App Privacy.** Answered for a chat app. Seal now collects no analytics,
   has no accounts and no ad identifiers. The public directory holds a hash, a
   display name and public keys. Redo the questionnaire from scratch.
2. **Age rating.** Answered for a chat app, so the user generated content
   questions were answered yes. With the messenger gone they are all no.
3. **App Review notes.** `archive/APP_REVIEW_NOTES.md` names the demo button
   by its exact label. Check that label still exists before submitting
   (GOTCHAS, demo mode).
4. **Content rights** already reads correctly.

## Not an ASO question, but the clock is running

The WebAuthn relying party ID is the string `sealmessenger.com`, and
HANDOFF.md says to decide before the first TestFlight build goes out. A build
is now on TestFlight. That ID is invisible in this listing, but iOS prints it
on the system sheet during the key ceremony, so somebody setting up their
estate reads the word "messenger" at the moment they most need to understand
what they are agreeing to. It cannot be renamed without every identity
registering again.
