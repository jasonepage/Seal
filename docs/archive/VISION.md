# Seal — Vision One-Pager

*The group chat where everyone is provably human — and you can prove you've actually met.*

## The problem (2026)

The internet can no longer tell humans from machines. AI agents send messages, deepfakes join video calls, synthetic contacts run romance scams at industrial scale, and every social platform's answer — CAPTCHAs, blue checks, ID upload — verifies *accounts*, not *relationships*. Trust online is collapsing precisely as the cost of faking a person approaches zero.

## The insight

Personhood can't be proven by an account property. It can be proven by **edges**: every friendship in Seal requires two humans physically together — one taps their hardware key (or passkey) on the other's phone, signing a challenge that cryptographically binds both identities. Bots can mint accounts; they cannot stand in rooms. The social graph itself becomes the proof-of-humanity engine, and it gets harder to fake the deeper it grows.

What no competitor can claim: **Signal verifies devices. Worldcoin scans eyeballs into a company database. Seal verifies that you met — peer to peer, with nothing sensitive held by anyone.**

## The product

- **Home base: encrypted group chat** (Snapchat-energy, camera-forward, ephemeral options) for groups where every member is a verified, met-in-person human. This is the retention core — dense small groups, not feeds.
- **The Square: where humans find humans.** A public space (global, later per-city) where *reading is open but posting is earned by graph depth* (e.g., 3+ forged friendships). Sybil armies are useless — each fake voice costs real in-person ceremonies. Every post carries a truthful badge: "7 forged friendships, 2 Verified." The Square is deliberately not E2EE (it's public), so it can be moderated without weakening private-chat guarantees.
- **Paths, not search:** you discover strangers via verifiable chains — "Bob is 2 taps away: you met Alice, Alice met Bob." **Vouched introductions** let a mutual friend co-sign a remote intro (a visibly weaker, dashed-ring edge) that upgrades to a full edge when you meet.
- **The forge log: a social passport.** Every ceremony is a signed, timestamped record that you met a human. Over years it becomes a verifiable diary of your real-world social life — irreplaceable, compounding, and the single strongest switching cost.

## Why now, why us

1. **AI flood:** proof-of-humanity went from paranoia to mainstream need in ~3 years.
2. **Hardware is already deployed:** millions of YubiKeys sit in drawers; passkeys ship on every iPhone. Zero hardware acquisition cost for the beachhead.
3. **Architecture as moat:** identities and attestations are user-held signatures, not platform database rows. We couldn't sell or leak the trust graph's secrets if we wanted to — and we run near-zero infrastructure (CloudKit + one static file).

## Beachhead → expansion

1. **People who already own keys** — security engineers, crypto holders, journalists, IT. They evangelize tools and already understand attestation.
2. **IRL event loops** — "seal the room" at meetups, conferences, parties. Each gathering densifies the graph; the growth loop is literally socializing. Conference partnerships = bulk onboarding.
3. **Everyone else via passkey tier** — Face ID onboarding in 30 seconds; the brass Verified ring becomes aspirational status, not a barrier.

## Retention mechanics

Dense groups (the proven messenger retention engine) + physical streaks ("you and Alice forged in 4 different months" — status accrues to people with rich real lives, the inversion of follower-count media) + the forge log's compounding switching cost + Square reach that grows with your real-world graph.

## Monetization (in order of fit)

1. **Verified tier subscription** (~$3–5/mo or bundled key sale): brass ring, verified-only groups, larger groups, multi-device. The status object is the product.
2. **Hardware margin:** co-branded NFC keys ($25–40, healthy margin) — the "Seal ring" as a physical product line. The key is a gift: "forge with me."
3. **Events B2B:** per-event "seal the room" kits for conferences (attendee verification + instant attendee graph). Event organizers pay today for worse versions of this.
4. **B2B attestation later:** signed, hardware-attributable transcripts (compliance teams, trading desks, boards) — our non-deniable-by-design messages are exactly what regulated comms need. Big lift; only after consumer traction.
5. **Never:** ads, data sales, graph licensing. Architecturally near-impossible and brand-fatal — this is a feature, not a constraint.

## Helpful to humanity, concretely

- **Anti-scam by construction:** romance scams, fake recruiters, and CEO-fraud require reaching people; in Seal, strangers without graph paths simply have no channel to you.
- **Rewards embodied life:** status flows from meeting humans, not farming engagement. The mechanic that grows the network is leaving your house.
- **Privacy without surveillance:** proof-of-personhood with no biometric database, no ID upload, no central authority — the anti-Worldcoin.
- **A trust layer others can build on (long-term):** "verify with Seal" as a primitive for marketplaces, dating apps, and forums that need humans — exportable, user-consented, zero-knowledge-friendly.

## What we are not

Not a Signal replacement (we're attributable by design, not deniable). Not a follower-graph social network. Not an everything-app. The discipline: **every feature must preserve the invariant that reach requires real human edges.**

## Status & next milestones

Working today: hardware-key + passkey registration, CloudKit identity directory, in-person friend ceremony with cryptographic verification. Next: group messaging (sender-key E2EE over CloudKit shared zones) → ephemeral media → vouched intros → the Square.
