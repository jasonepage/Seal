# The release: how sealed envelopes open

**Version:** 1.0 · **Date:** 2026-09-15 · **Code:** `Seal/Estate/ReleaseMachine.swift` · **Tests:** `Seal/SelfTest/ReleaseMachineTests.swift`

## 1. The machine

Nine states. A pure function of the record and the clock.

```
active ──(silence exceeded)──► overdue ──(claim)──► warning ──(warningDays)──► grace
                                                                                  │
                          ┌──────────────────────────────────────(graceDays)──────┘
                          ▼
                       claimOpen ──(M distinct taps)──► authorized ──(shares combined)──► released
                          │
   any live state ──(owner heartbeat or cancellation)──► cancelled ──(silence again)──► overdue
   any live state ──(custodian objection)──► objected ──(pause: withdrawn / veto: new claim)
```

"Live" means warning, grace, claimOpen, authorized or objected: a claim
exists and has not been stopped.

## 2. The rule, and the defaults

| Parameter | Choices | Default |
|---|---|---|
| `silenceDays` | 30, 90, 180, 365 | 90 |
| `warningDays` | 1 or more | 21 |
| `graceDays` | 0 or more | 14 |
| `threshold` | 1 to N | 2 (with 3 custodians) |
| `objectionBehavior` | pause, veto | pause |

## 3. Transitions, exactly

- **active to overdue.** `now - lastHeartbeat > silenceDays`, strictly. With
  no heartbeat ever, the estate's creation is the anchor. A custodian phone
  that observes this posts a signed `silenceObserved` once a day. That is
  evidence; it changes nothing.
- **overdue to warning.** A custodian posts a signed `releaseClaimed`. A
  claim posted before the silence period has fully elapsed is **ignored**,
  not honoured with a shorter countdown. Every other custodian is notified
  by the estate subscription the same day. The owner is warned daily.
- **warning to grace.** `warningDays` (plus any paused time) elapse.
- **grace to claimOpen.** `graceDays` more elapse.
- **claimOpen to authorized.** M distinct custodians each post an
  `authorization` carrying a WebAuthn assertion by their root credential over
  `SHA256(framed("seal.release.authorize.v1", [estateID, epoch, claimID,
  recordHeadDigest]))`, plus their Shamir share re-wrapped to the claimant's
  devices. A tap made before the claim opened, or during a pause, does not
  count. A second tap by the same custodian does not count.
- **authorized to released.** The claimant opens the shares on their phone,
  checks each against the commitment the owner signed (a bad share names its
  custodian), combines, checks the result against the Estate Key commitment,
  and posts `released` with the Estate Key in the clear.
- **any live state to cancelled.** The owner posts a `cancellation`, or simply
  a `heartbeat` dated at or after the claim. The app posts both. Cancelled is
  shown until the owner has been silent for a full period again, at which
  point the estate is overdue and a new claim may open.
- **any live state to objected.** A custodian posts an `objection` naming the
  claim. With `pause`, every later deadline slides by the time the objection
  stays open, and withdrawing it resumes the countdown. With `veto`, the claim
  is dead; withdrawing changes nothing; a new claim starts from the beginning.

## 4. The asymmetry

Cancelling requires the owner's phone and, if the app lock is on, Face ID.
Nothing else. It must never require the hardware key, because a living person
who lost their key would otherwise be declared dead. Releasing requires M
physical keys, each tapped over a challenge naming this exact claim and this
exact record head, so a tap cannot be replayed into another claim or another
history.

## 5. Time

There is no server running this clock. The owner's phone writes a signed
heartbeat on every launch and foreground. The custodians' phones read the
record and drive the machine. Each heartbeat, claim, tap, cancellation and
release is sent to an RFC 3161 timestamp authority (only its digest leaves the
phone) and the token comes back into the record. The feed prefers the token's
`genTime` over the actor's clock, so "the last heartbeat really was 100 days
ago" is a statement about an authority's clock, not a phone's.

Custodian phones are woken by a CloudKit subscription on the estate's events
and by background refresh. Punctuality is not required. Correctness is: every
decision is recomputed from the whole record every time.

The clock is injected everywhere (`Seal/Time/Clock.swift`). Nothing calls
`Date()`. The debug Time Travel screen swaps in a simulated clock and advances
it by days, so the entire machine runs end to end in ninety seconds. The
self-test `release.ninetySecondRun` does exactly that.

## 6. What a custodian's phone checks before believing an event

1. The event's device signature verifies.
2. That device is endorsed by the root the event names, verified through the
   pinned root key (the owner's, from the ceremony; a fellow custodian's,
   from the owner's signed epoch statement).
3. The actor may write that kind: owner kinds for the owner, custodian kinds
   for hashes named in the owner's newest epoch statement, nobody else.

Anything that fails is dropped before the feed ever sees it.

## 7. Rotation

Removing a custodian, adding one, or changing the threshold means a new
epoch the next time the owner seals: fresh Estate Key, fresh shares, fresh
owner wraps, and each table's small inner ciphertext re-encrypted under the
new key. Tables and blobs are never touched. A claim names its epoch; a claim
against an old epoch is still valid against that epoch's material, so
rotating during a claim does not make the claim disappear. The owner's
heartbeat does that.

## 8. Custody confirmations are not taps

Since 2026-09-16 a custodian's phone asks them, once per
`custodyConfirmMonths` (default 12, set by the owner in the rule), to tap
their key and say they still have it. That writes a `custodyConfirmed`
event: an assertion over `seal.custody.confirm.v1` naming the estate, the
epoch and the record head, and nothing else. It is a receipt. The feed
ignores it, the machine never sees it, the challenge domain is different
from `seal.release.authorize.v1`, and it carries no share. Three custody
confirmations during an open claim leave the state exactly where it was
(`custody.neverCountsTowardRelease`). The owner's home screen reads them to
say when each key holder last confirmed, and to name the one to ask.

## 9. Known judgement calls, for review

- After a **veto**, a new claim may open immediately if the owner is still
  overdue; the objecting custodian must veto again. An alternative (the
  objector must withdraw before any new claim) would let one custodian block
  forever. Not decided in the brief; this was the smaller assumption.
- Taps are counted against the pause **as it stood at the moment of the
  tap**. A pause that starts after a valid tap does not invalidate it.
- A **released** event wins over a later heartbeat. The key is out.
- Authorization assertions require user presence but **not user
  verification** by default, because the UV policy is `.preferred` and a
  PIN-less key cannot produce UV. `WebAuthnAssertion.verify(with:requireUserVerification:)`
  exists for a policy that wants it.
