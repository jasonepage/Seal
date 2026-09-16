# Seal: the product

**Version:** 1.0 · **Date:** 2026-09-15 · **Companions:** [RELEASE.md](RELEASE.md) · [CAPSULE.md](CAPSULE.md) · [SDS.md](SDS.md)

## 1. One paragraph

A person writes a small number of sealed envelopes, hands physical security
keys to people they trust, and sets the rule for how those envelopes open
after they are gone. An envelope holds a letter, a few photos, a voice
message, and the secrets: passwords, where the safe deposit key is, the
combination, the seed phrase, the thing they never told anybody. Nobody,
including Apple and including us, can open an envelope early. It takes a
threshold of custodians physically tapping their keys, after a long silence
from the owner, after weeks of loud warnings the owner can stop with one tap.

## 2. The story to build against

A 58 year old man writes four envelopes on a Sunday night. One to his wife
with every password and where the documents are. One each to his two kids,
letters. One to his business partner with the domain registrar login. He hands
a key to his wife, one to his brother, one to his attorney. The rule is any two
of those three, after 90 days of silence and three weeks of warnings. He spends
two hours. If he opens the app once during those three weeks, it all stops
cold.

He does this once. The custodians do nothing for years. That is why this is a
product one person can adopt, where the messenger it replaced needed pairs.

## 3. Words

| Word | Meaning |
|---|---|
| Owner | The person who writes the envelopes. One estate per identity. |
| Envelope | One letter, photos, voice message and secrets, for one recipient. |
| Recipient | Who an envelope is for. Must be a Seal identity the owner met in person. |
| Custodian | Someone the owner handed a security key to. Holds one Shamir share. |
| The rule | Silence days, warning days, grace days, M of N, pause or veto. |
| Heartbeat | One signed line the owner's phone writes on every launch: "I am here." |
| Claim | A custodian saying "I believe the owner is gone." Starts the warnings. |
| Release | M custodians have tapped; the claimant combines the shares. |
| Capsule | The archive of record: one file per custodian, outlives the company. |

## 4. What the owner does

1. Registers with a security key or a passkey, exactly as before.
2. Meets each custodian and each recipient in person and runs the two minute
   ceremony, exactly as before. That ceremony is what pins their key.
3. Writes envelopes. Each is for one person. Secrets are sealed exactly as
   written, never corrected, and shown again only after Face ID.
4. Makes people custodians, hands each a key, and records the handover with
   the existing two-sided custody receipt (their tap on the owner's phone).
5. Sets the rule. Defaults: 90 days, 21 days, 14 days, and pause.
6. Taps Seal. Everything is encrypted on the phone and published. Custodians
   and recipients are told they have a part.
7. Opens the app now and then. That is the whole ongoing obligation.

## 5. What a custodian does

Nothing, for years. Their phone quietly checks the owner's record. When the
owner has been silent past the limit it says so, signed, once a day. A
custodian may start a claim, object to one, withdraw an objection, and, once
the claim is open, tap their key. Whoever started the claim combines the
shares once enough keys are tapped. See [RELEASE.md](RELEASE.md).

## 6. What a recipient does

Nothing until the release. Then their phone finds their key table by trying
to open each one with their own key, opens their envelopes in the order the
owner chose, and shows the letter, the photos, the voice message and the
secrets, with a byte-exact copy button.

## 7. What is promised, precisely

- **Nobody can open an envelope early.** An envelope's content key sits in a
  key table under a random key that is reachable only two ways: the owner's
  devices, or the recipient's devices plus the Estate Key. The Estate Key
  is reachable only by the owner's devices or by combining M of N Shamir
  shares, each wrapped to one custodian's devices with X25519 plus ML-KEM-768.
- **Stopping is easy, starting is hard.** A heartbeat from the owner's phone
  (Face ID at most, never the hardware key) beats everything. Starting needs
  the silence, the warnings, the grace and M physical taps.
- **A custodian learns nothing about the envelopes.** Not the titles, not the
  recipients, not which exist. After release the claimant holds the Estate
  Key, which opens nothing on its own.
- **The record outlives us.** Each custodian can export a capsule; a script
  with no Seal in it checks every signature and every token.

## 8. What is not promised, precisely

- **That the owner is dead.** Silence is silence. The warnings exist because
  a long hospital stay looks the same as death from the outside.
- **That recipients are who the owner thinks.** Seal proves credential A did
  something with credential B. Binding a credential to a passport is what
  notaries do.
- **Hiding everything.** The record shows how many recipients there are (one
  key table each), how many blobs, and that a given hash has some part in
  some estate (the invite record is addressed by hash). Titles, letters,
  secrets and who-is-who are hidden.
- **A recipient who is not a Seal identity.** Envelopes are wrapped to a
  recipient's devices, so the recipient must have registered and met the
  owner in person. Letters to a child who has no phone yet are a known gap;
  the honest options (a printed share, a "whoever opens it" envelope that
  the claimant can read) each weaken the isolation promise and were not
  built without a decision.
- **A second owner device.** The owner's working copy lives on one phone's
  keychain. A second phone signed into the same identity can read the
  published record and, holding the same identity's KEM keys, open the
  owner wraps, but it does not carry the working copy of drafts or media.
- **Undoing a release.** Once the Estate Key is published the seal is broken.
  A heartbeat after that changes nothing.

## 9. Age and plainness

Half the users are over sixty. Bigger text mode bumps every screen. Every
sentence in the app was written to be read aloud to a parent. Where the
product has to say something technical it says the plain thing first:
"Your envelopes are closed." "A custodian has started a claim. If that is not
what you want, tap the button. It stops everything."

## 10. What stays from the messenger

The identity and ceremony layer, the hybrid wrapping, the signed record with
its timestamps, custody receipts, sealed cards (now the secret fields), the
theme and Bigger text mode. Everything else was retired in commit
"Phase 7: the messenger is retired". `git log` keeps it.

## 11. The blank page, and the interview that is meant to fix it

**Not built. Specified here so it is not reinvented from scratch, and so the
promise below is decided before anybody writes code.**

### The failure this exists for

The way this product fails is not cryptographic. It is a woman of sixty-eight
who buys it, names three custodians, hands out three keys, sets the rule, taps
Seal, and dies with an empty vault. Every ceremony worked. The release machine
ran exactly as designed. The envelopes opened, and there was nothing in them.

Writing to the people you are going to leave is the hardest writing there is,
and the app currently hands you an empty text field and a cursor. Section 4
lists what the owner does; step one of it is the step most people will never
take.

### What it is

An interview, on the phone, that asks questions and turns the answers into a
draft envelope the owner then edits. It is not a ghostwriter and it never
signs, seals or sends anything. It produces a draft in the editor, and the
owner changes every word of it if they want to.

A real run of it: she opens Seal on a Sunday. It asks who is hardest for her
to write to. She says her daughter. It asks what she has never said to her.
She talks for two minutes. It asks whether the daughter should read this
before or after her brother's. Half an hour later there are three envelopes
in the vault that would otherwise not exist.

### The promise, which is the part to decide first

**Nothing the owner writes or says leaves the phone. Not to a server, not to
Anthropic, not to Apple's private cloud.** On-device inference only. If the
model cannot run on this phone there is no model on this phone, and the
fallback below runs instead. This is not a performance choice. The whole
product is one promise about secrets, and shipping a feature that reads every
envelope and sends it anywhere would end that promise whatever the fine print
said.

### How it would be built

Apple's Foundation Models framework, which is a system framework on iOS 26
and therefore not a new dependency, runs on the phone, costs nothing, and
returns structured values rather than loose text, so an answer can come back
as a draft with a title, a recipient and a body. It touches no cryptography
and no wire format: it writes into the same editor a thumb does.

### The fallback is most of the feature

Apple Intelligence only runs on recent hardware, so a good number of the
phones this is built for cannot run any model at all. The fallback is the
same question set as plain text with no follow-ups, and it is worth saying
plainly that this gets most of the way. The questions are what unsticks
somebody. The model earns its place on the follow-up question it asks next
and on turning two minutes of rambling into a letter, not on the list.

Build the fallback first. If the question list alone does not get people
writing, a model on top of it will not either.

### What it must not do

**It does not help set the rule or pick the custodians.** The policy is four
numbers and three of them have four allowed values each. A conversation that
fills in a form is worse than a form. And the hard part of choosing custodians
was never the numbers, it is which people, which is a judgement about a family
that a small model running on a phone has no business having an opinion about.
The app already says the only true thing there: pick people who will still be
reachable in ten years.

## 12. Attach a file, and what the phone can read from it

**Not built. Written down 2026-09-16 so it is not reinvented, and so the
promise below is decided before anybody writes code. Queued behind
section 11; both ride on the same on-device model.**

### The case

Karen has a PDF of her life insurance policy, the deed to the house, and
the folder of statements the bank emails her. Today she can type a
password into a secret and a sentence into a letter. She cannot put the
policy itself in Mike's envelope, and she cannot get from a forty page
PDF to "call this number, quote this policy, the beneficiary is you"
without reading it herself on a Sunday night. Most people do not.

### What it is

A seventh card in the editor, "Files", beside photos, voice and video.
A file is sealed exactly like a photo: encrypted on the phone under the
envelope's content key, one blob, listed in the recipient's key table,
opened on their phone after the release. PDFs, images of documents, and
plain exports (a folder of text, a zip) are all just bytes to the
envelope. Nothing about the key hierarchy, the machine or the capsule
changes; `MediaItem.Kind` gains a case, and every phone must run a
current build, as with video.

On top of that, and only when the phone can run Apple's on-device model
(the same test as section 11): "Read it for me." The phone pulls the
words out of the file (PDFKit for a PDF, the text files in an export),
keeps a small index of them on the phone, and offers "what to do first"
steps drawn from the file, each pointing at the page it came from. The
owner ticks the ones that are right and edits the words. The steps go
into the envelope's existing list. The file itself is not summarised
into the letter; the letter stays hers.

A real run of it: Karen attaches the policy PDF to Mike's envelope and
taps "Read it for me." Ten seconds later: "Call MetLife on 1-800-... and
quote policy 4471 (page 2). The beneficiary is Michael Page (page 3).
Premiums are paid to March (page 7)." She keeps the first two, deletes
the third, and seals. Mike gets the steps, the PDF, and the letter, in
that order.

### The promise, decided first

**Nothing in a file leaves the phone. Not to a server, not to us, not to
Apple's private cloud.** The reading and the index happen on the phone
or they do not happen; with no model on this phone, the card still
attaches the file and offers no reading. This is section 11's promise
applied to documents, and it is the only reason a product about secrets
can offer this at all. In the first cut no index is kept at all: the
reading is done on demand, and its only output is the steps the owner
ticks, which are sealed with the envelope like every other step.

### What it is not

- **Not a digital footprint dashboard.** "Upload your TikTok export and
  see what they kept about you" is a different product for a different
  customer, and it would pull Seal back toward being two ideas in one
  app, which is the mistake the messenger was. An export can be attached
  to an envelope like any file, and read for steps like any file, and
  that is where it stops.
- **Not a search across envelopes.** The index is per file, per envelope,
  for one purpose: steps. No "ask my vault" box.
- **Not an OCR service.** A photographed document is attached as an
  image; the phone's own text recognition (Vision) may feed the reading
  when it runs on the phone, and nothing else does.

### Build order

Built the same evening it was written (2026-09-16, uncompiled): the
Files card and sealing (`MediaItem.Kind.file`, `Envelope.files`, the
system file picker, the reveal's viewer and share), and "Read it for me"
on top (`Seal/Estate/FileReading.swift`: PDFKit and plain text in,
pieces of about 3,000 characters to the on-device model, up to eight
proposed steps out, each ticked by the owner). A zip or an export folder
attaches and seals but is not read yet. Jason's call to build it now
rather than after section 11; the ordering argument above still stands
for what to show real people first.
