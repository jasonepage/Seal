# Opus prompt — Introductions (remote friending via a mutual in-person friend)

Copy everything below the line into the coding session. Repo: `~/Documents/GitHub/Seal`.

---

You are working on **Seal**, an iOS 26+ SwiftUI E2EE messenger with no backend (CloudKit public DB transport). This is a security-critical trust feature. Read before writing any code: `HANDOFF.md` (especially the backup-keys entries and the pre-existing-issues list), `docs/SDS.md` (identity, endorsement, friend ceremony), `docs/TRUST.md`, `Seal/Ceremony/CeremonyManager.swift`, `Seal/Chat/ChatEngine.swift` (payload kinds), and the friend-storage model. Follow existing patterns; no new dependencies; no new CloudKit record TYPES (new fields on existing types only if unavoidable, flagged with an ops checklist).

## The feature

Today friendship requires an in-person ceremony. Families are geographically scattered, so add **Introductions**: a mutual, physically-verified friend can vouch two of their friends into a friendship — remotely, without weakening the in-person tier's meaning.

Example: Nathan ⟷ Mom are brass (met in person). Mom ⟷ Aunt Linda are brass. Mom introduces Nathan and Linda: her device signs a statement binding both verified identities, delivered to each over the existing E2EE channels. Nathan and Linda become friends at a NEW, visibly distinct trust tier.

## Trust rules — non-negotiable

1. **Brass means physically met. No exceptions, ever.** An introduced friendship renders as a distinct tier (call it "linked" internally; UI: silver-link styling, `link` glyph). The verification drawer shows provenance: "Introduced by Mom · <date>", where "Mom" is the introducer's verified identity.
2. An introducer must hold **in-person (brass) friendships with BOTH parties** at introduction time. An introduced (linked) friend cannot introduce anyone — introduction does not chain. Enforce cryptographically where possible, not just in UI: the introduction statement embeds the introducer's identity, and each recipient verifies it against a friend record that its OWN device marked as in-person.
3. Both introduced parties must **accept** — an introduction is an offer, not an automatic friendship. Either side declining discards it silently (the introducer sees "not accepted yet", never "declined" — no family drama by protocol).
4. The honest copy states the claim exactly: a linked friendship is as trustworthy as the introducer's judgment. Suggested drawer copy: "You haven't met <name> in person through Seal. Mom has, and vouched for this connection." Never render "Verified" for a linked friend.

## The statement

`seal.introduce.v1` — signed by the introducer's device key (root-endorsed, same verification chain as messages):

commitment = SHA256("seal.introduce.v1" ‖ introducerRootHash ‖ partyARootHash ‖ partyAPublicKey ‖ partyBRootHash ‖ partyBPublicKey ‖ timestamp)

- **Length-frame every variable-length field** (prefix each with its byte count) — HANDOFF's pre-existing-issues list flags `seal.endorse.v2`'s missing framing as a defect; do not repeat it.
- The domain prefix string is inside the hash, per the `signReceipt` lesson.
- Each recipient verifies: (a) signature chain: introducer's device key → endorsement → introducer's root, using the same directory verification as inbound messages; (b) the introducer is a local IN-PERSON friend; (c) its own root hash + public key appear in the commitment exactly (prevents replaying an introduction to a different party); (d) the counterpart's public key in the statement matches the directory's published identity for that root hash — on mismatch, refuse with a plain-language error, don't guess.
- Fingerprint phrase confirmation: after accepting, show the standard emoji-word phrase for the new friend with the existing "say it out loud" coaching — recommend a phone/video call. This is UI encouragement, not a protocol step.

## Transport

No new record types: deliver the introduction through the existing E2EE message pipeline as a non-bubble payload kind (`kind:"introduce"`), the way reactions/read/typing work — sent by the introducer to each party in their existing 1:1 chat. The acceptance travels back the same way (`kind:"introduce.accept"`). Once BOTH acceptances exist, the introducer's device sends each party the other's acceptance as confirmation, and each side creates the friend record locally at the linked tier. Think through and document the partial states (one accepted, one silent; introducer offline; either party re-installs mid-flow) — the flow must be resumable and idempotent, keyed by the commitment hash. If you conclude a GroupInvite-style record fits better than piggybacking chat messages, argue it in your report BEFORE building — but no new record types either way.

## UI

- Entry point: the introducer, viewing a friend's profile (or the verification drawer), gets "Introduce to…" listing their OTHER in-person friends; pick one → confirmation sheet stating exactly what will be shared (each party's name + keys go to the other).
- Recipients: an inbound introduction renders as a distinct card in the chat with the introducer ("Mom wants to introduce you to Aunt Linda"), Accept / Not now. Accepting shows the fingerprint phrase step.
- Friend list + chat headers: linked friends get the silver-link ring treatment, never brass. Verification drawer shows provenance line. Parent Mode: introductions can be ACCEPTED in simplified mode (big, plain-language card — this is the main way parents will add family), but initiating one requires the full app.
- Vault Warmth rules apply (UI.md §1): SF Pro on these surfaces, no mascot, brass reserved — linked tier gets silver.

## Do not touch

`Seal/Crypto/` message pipeline internals, `SealedCard`/`MessageProof`, backup-keys code, the pre-existing issues list (separate work). The working tree may carry unrelated uncommitted work — leave it alone, commit only your files.

## Definition of done

- Builds clean; simulator walkthrough of the full three-party flow (three demo identities — extend DemoFixtures so the flow is demoable with `-SealDemoMode`).
- Replay/mismatch cases exercised: introduction replayed to a wrong party is refused; directory-key mismatch is refused with plain language; a linked friend attempting to introduce is prevented.
- Partial-state matrix documented in a new `docs/INTRODUCTIONS.md` (statement format, flow diagram, threat notes: what a malicious introducer CAN do — introduce an impostor they control — and why the tier + provenance line is the mitigation).
- HANDOFF.md dated entry, existing style. Ops checklist for anything needing CloudKit console work.
- Commit only your files, message style per `git log`.

## Report back

Your report must state: the exact commitment byte layout, the partial-state handling you chose, anything you deviated on and why, and the single two-phone (or three-phone) test Nathan should run first.
