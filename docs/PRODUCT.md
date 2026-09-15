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
