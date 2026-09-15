# Seal

**Seal is for the things you can't afford to send to the wrong person.**

A private photo. A bank account number. A crypto wallet address. A password.
Once one of those reaches the wrong person, you cannot take it back.

## How it is different

In every other messaging app, the worst thing that can happen is that you were
never talking to who you thought. A phone number can be faked. A voice can be
cloned from ten seconds of audio. A stranger can set up an account with your
son's name and photo in about a minute.

Seal makes that impossible, and it does it in a way that sounds almost too
simple: **you can only add someone by standing next to them.**

The two of you are together, one phone scans the other, and the other person
proves who they are right there in your hand. It takes about two minutes and it
only ever happens once per person. After that you can message them from
anywhere in the world, and every message really is from them.

Nobody can be tricked into a Seal connection, because there is nothing to
trick. There is no username to search, no number to call, and no request that
can arrive from a stranger.

## What you can do with it

**Send messages and photos.** They are scrambled on your phone before they
leave it and can only be unscrambled on the other person's phone. Not by us,
not by Apple, not by anyone who breaks into a server, because there is no
server holding them. You can set messages to delete themselves on a timer.

**Send something that must be exact.** A wallet address or payment
instructions go as a Sealed Card: locked exactly as written, copied character
for character, and impossible to confuse with ordinary chat. If somebody
changes a single character on the way, it shows.

**Sign for a handover.** You give somebody a car, a deposit, a set of keys.
Both of you sign the same receipt, in person, and either of you can prove
later exactly what was handed over and to whom.

**Keep a record.** Seal keeps a list of what has happened between you and each
person: when you met, when you sent something sealed, when you signed for
something. Each line is signed and cannot be edited afterwards, not even by
you.

## The family rule

If it is about money and it did not arrive in Seal, it is not really them.
That one sentence is easy to remember at eight or eighty, and it stops the
scam phone call, the fake text and the cloned voicemail cold.

## What it does not do

It proves a message came from that person's phone. It does not know whether
what they are asking for is a good idea, and it cannot tell you whether their
phone is in their own hands. If a request feels strange, ring them.

Messages set to disappear are removed from both phones on schedule, and Seal
tells you when somebody takes a screenshot. It cannot stop a second phone
pointed at a screen. Nothing can.

**There is no password reset.** Your identity lives in your phone and in your
key, not on a server, which is why nobody can steal it from us. It is also why
nobody can give it back to you. Add a backup key early. The app asks you to.

## Getting it

iPhone only for now, through Apple TestFlight. Android is on the roadmap.
[sealmessenger.com](https://sealmessenger.com)

---

## For developers

iOS 26.5+, SwiftUI, no backend. Identity is a WebAuthn credential, either a
FIDO2 hardware key (Verified tier) or a platform passkey, which endorses
non-exportable Secure Enclave device keys. Messages are end-to-end encrypted
with per-sender ratcheted chains (HKDF, AES-256-GCM) wrapped to members over
X25519, with the AAD binding group, epoch, sender, index and previous message
hash so a transcript cannot be reordered or truncated undetected. Transport is
the CloudKit public database with deterministic record names. The only external
dependency is a static AASA file on `sealmessenger.com`.

### Where to read what

| Doc | What it is |
|---|---|
| [HANDOFF.md](HANDOFF.md) | **Start here.** Where the project stands today and what is blocking |
| [docs/RECORD.md](docs/RECORD.md) | The current product direction and its spec |
| [docs/GOTCHAS.md](docs/GOTCHAS.md) | Hard-won operational knowledge. Read before debugging anything |
| [docs/SDS.md](docs/SDS.md) | Architecture: key hierarchy, crypto, data model, threat model |
| [docs/SRS.md](docs/SRS.md) | Requirements, numbered FR-n |
| [docs/UI.md](docs/UI.md) | Design language and screen specs |
| [docs/CARDS.md](docs/CARDS.md) | Sealed Cards |
| [docs/INTRODUCTIONS.md](docs/INTRODUCTIONS.md) | Vouched introductions |
| [docs/COLDSTART.md](docs/COLDSTART.md) | First-run design, the shell merge, the site |
| [docs/APP_STORE.md](docs/APP_STORE.md) | Submission status and what is still missing |
| [docs/CLOUDKIT_DEPLOY.md](docs/CLOUDKIT_DEPLOY.md) | How to deploy the schema to Production |
| [docs/archive/](docs/archive/) | Superseded thinking, kept for reference |
