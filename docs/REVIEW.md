# Review before the demo (2026-09-16)

**Status:** findings 1 and 2 built the same night (uncompiled). Finding 1
is `Seal/Estate/FirstSeen.swift` plus the engine's `noteSeen` and the
`timeOf` it hands the feed; `FirstSeenTests` shows the backdated claim
in `.warning` with the table and `.claimOpen` without it. Finding 2 is
the guard at the top of `sealAndPublish` and `startNewSet`, with the
button on the released card. Finding 3 is now in GOTCHAS.

**Not an audit.** One read, by the same assistant that wrote much of the
code, of the places where a mistake would be embarrassing on camera:
Shamir, the key hierarchy, the release machine and its feed, the signed
delete marker, and the new file reading path. Ranked by how bad it would
be, worst first, each with a fix. Nothing here was run; the shell on the
Mac was down.

## 1. A key holder can backdate a claim and skip the warnings (fix before the demo)

`ReleaseFeed.effectiveTime` uses the RFC 3161 token's time when the event
has one, and otherwise the actor's own `occurredAt`. `EstateLogVerifier`
admits a `releaseClaimed` with no token. So a key holder whose phone says
the claim was opened 40 days ago, on a claim written today, produces a
snapshot where the warning and grace periods have already passed: the
owner's phone jumps straight to "keys can be tapped", no daily warnings
were ever sent, and the other key holders' phones agree because they
compute from the same event. This needs the owner to be already past the
silence limit (a hospital stay) and a key holder willing to put a
backdated signature in a record that everyone keeps, so it is not an
outsider's attack. It is still the one thing that turns "weeks of
warnings you can stop with one tap" into "no warnings".

Timestamps can also be switched off by the owner (You, Timestamps), which
puts every phone in the no-token case.

**Fix (small, local, no format change):** every phone remembers when it
first saw each event id (`EstateLogStore` already merges by id; add a
`firstSeen: [String: Date]` beside the log, keychain, per estate). The
engine passes `timeOf` into `ReleaseFeed.snapshot` as `max(effectiveTime,
firstSeenHere)` for `releaseClaimed` and `authorization` only. Then no
phone can be told a claim is older than the day that phone learned of it,
so the owner's phone always runs the full warning period from the day it
saw the claim, and a key holder's phone refuses to count taps before its
own view of the claim has aged. Heartbeats keep the token-or-claimed rule
(the owner backdating their own life is not a threat). Add a machine test:
a claim with `occurredAt` 40 days back and `firstSeen` today is in
`.warning`, not `.claimOpen`. `ReleaseMachine` itself does not change.

## 2. After a release, sealing again leaks new envelopes to that recipient (fix before strangers use it)

`sealAndPublish` has no guard for an estate whose Estate Key has been
published. A rotation makes a new Estate Key and calls `rewrap`, which
keeps each recipient's `tableKey` and `ciphertext` and only rewraps the
key under the new epoch. But a recipient who already opened their table
in the released epoch holds that `tableKey`. Every later envelope for
them goes into the same table under the same key, so that recipient can
read new envelopes as soon as they are uploaded, before any new release.
Only the intended reader is affected, and PRODUCT.md section 8 already
says a release cannot be undone, but "nobody can open an envelope early"
stops being true for that one person and the app does not say so.

**Fix:** when the owner's own snapshot has `releasedAt`, `sealAndPublish`
throws `EngineError.notAllowed("These envelopes have been released. Start
a new set.")`, and the status card's "Start a new set of envelopes" button
creates a fresh `Estate` (new id, new table keys, same rule and key
holders carried across). One test: seal on a released estate throws.

## 3. `markerCounts` trusts an unsigned delete marker when it knows no key (accepted, say it)

`TombstoneProof.markerCounts` returns true when `knownKey` is nil. On a
phone that never pinned the identity and cannot fetch its live record,
anyone can write `tomb.<hash>` and that phone treats the identity as
deleted. The comment says this is on purpose ("no identity to protect")
and it only affects a phone with no relationship to that identity, so it
is a footnote, not a hole. Say it in GOTCHAS with the other marker rules.

## 4. Things read and found sound

- **Shamir** (`Shamir.swift`): GF(256) with the AES polynomial, random
  coefficients from `UInt8.random` (the system generator, which is the
  secure one on Apple platforms), Lagrange at zero, duplicate and zero
  index refused, share length checked. The per-share commitment is
  SHA-256 over index and 32 random-looking bytes, so it reveals nothing.
  Correct.
- **Key hierarchy** (`EstateKeys.swift`): AES-GCM everywhere with an AAD
  that names the estate, the epoch and the purpose, and every wrap has
  its own purpose string, so a ciphertext cannot be moved from one slot
  to another. The recovered Estate Key is checked against a commitment
  the owner signed. A wrong share names its key holder. Correct.
- **Release machine** (`ReleaseMachine.swift`): a pure function, every
  transition in RELEASE.md section 3 present, a heartbeat at or after
  the claim voids it, taps before the claim opened or during a pause do
  not count, a second tap by the same key holder does not count. Correct
  given honest times, which is finding 1.
- **Delete marker** (`TombstoneProof.swift`): the tap is over a challenge
  in its own domain string, bound to the credential id whose hash is the
  identity, so a marker signed for one identity cannot be replayed for
  another, and a release tap cannot be reused as a delete. Correct.
- **File reading** (`FileReading.swift`): the file is read only after the
  owner taps "Read it for me", by PDFKit and the on-device model, and
  the result goes nowhere but the steps list the owner ticks. A crafted
  PDF is handled by Apple's parser, not ours. The 50 MB ceiling is
  enforced before anything is written.

## 5. Not read this pass

WebAuthn parsing (`WebAuthnParsing.swift`), `SyncEngine` and the CloudKit
record rules, the capsule verifier script, the sponsored key's PRF path,
and `EstateLogVerifier` beyond the token question. Those are the next
pass, and the verifier script is the one to have a stranger read before
it is the thing you point at in the Hacker News post.

## 6. What to say in the post

"Not yet audited. One design review found two things worth fixing before
strangers use it (a key holder backdating a claim to skip the warnings,
and re-sealing after a release exposing new envelopes to that recipient);
both are fixed in this build. The threat model and its honest limits are
in PRODUCT.md section 8. Break it and tell me."

Only say "both are fixed" once they are.
