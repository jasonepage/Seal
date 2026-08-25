# Opus prompts — family-shield pivot

Two independent prompts. Run them in separate sessions, Prompt 1 first. Repo: `~/Documents/GitHub/Seal`.
(Already done, not in these prompts: report email → jasonepage@gmail.com; app icon; website.)

---

## Prompt 1 — Parent Mode

You are working on **Seal**, an iOS 26+ SwiftUI E2EE messenger with no backend (CloudKit public DB transport). Read `HANDOFF.md`, `docs/UI.md`, `docs/CARDS.md`, and skim `Seal/Views/` before writing code. Follow existing architecture; no new dependencies, no CloudKit schema changes, nothing touched under `Seal/Crypto/`, `Seal/Sync/`, or `Seal/Cards/SealedCard.swift`.

Seal is pivoting to a family anti-scam product: adult children set it up for aging parents. Build **Parent Mode** — a per-device presentation mode, not a different account.

### What it is
A toggle in ProfileView ("Simplified mode" — never call it "elderly mode" anywhere user-visible). Stored per identity in the keychain like other flags (`seal.parentmode.<hash>` pattern — see AppLock.swift for the per-identity flag pattern). Purely local presentation: wire format, identity, and friends are identical in both modes, and a chat between a Parent Mode phone and a normal phone must work unchanged.

### What it changes when ON
1. **Chats-only.** The TabView collapses to the Chats tab (no Camera tab, no Circle tab). Profile is reachable via an avatar button in the chat list's toolbar. Camera stays available INSIDE a chat if it already is; don't build new photo UI.
2. **Bigger everything.** Respect the user's Dynamic Type as a floor, not a ceiling: chat list rows and message text render one size class larger; minimum tap targets 52pt. Test at accessibility XL — nothing may truncate the value on a Sealed Card (wrap, never ellipsize).
3. **Plain words.** In Parent Mode, replace jargon in visible strings: "Sealed Card" header stays, but verification drawer strings prefer "This is really <name>" phrasing over key/epoch vocabulary. Keys, epochs, fingerprints move behind a "Details" disclosure rather than disappearing (they must remain reachable). NEVER weaken specification copy from docs/CARDS.md — a card is "sealed", never "verified"/"safe"; the honesty line stays wherever it appears today.
4. **Sealed Card prominence.** Inbound cards in Parent Mode render with a larger title and a one-line explainer under the verification line: "Sealed means this really came from <name>'s phone." Copy button unchanged (byte-for-byte + read-back check — do not touch `CardCopyButton`).
5. **Scam-pause on money requests.** When an inbound `paymentInstructions` or `cryptoAddress` card arrives in Parent Mode, the detail sheet shows one extra calm notice: "Take your time. If anything feels off, call <name> before acting." Orange, matching TTL-notice styling. No blocking, no extra taps to read the card.
6. **Compose stays.** Parents can still send everything; nothing is read-only.

### Constraints
- All strings through the existing style: SF Pro on security surfaces, mascot only on social surfaces (UI.md §1.1), brass = trust only.
- The toggle itself must be reachable and operable at accessibility sizes.
- Demo mode: add `-SealParentDemo` handling so DemoFixtures can showcase Parent Mode for screenshots.
- Definition of done: builds clean; run simulator in both modes with `-SealDemoMode`; screenshots of chat list, a chat, an inbound money-request card at default and accessibility XL; `git diff` limited to Views/Theme/DemoFixtures + docs; update HANDOFF.md (dated entry, existing style) and add a §Parent Mode note to docs/UI.md. Commit only your files.

---

## Prompt 2 — Backup keys (FR-3)

You are working on **Seal** (same repo intro as above — read `HANDOFF.md`, `docs/SDS.md` §identity, `Seal/Identity/`, `Seal/Ceremony/CeremonyManager.swift`). This is a security-critical identity feature: work in small steps and explain the design in comments as thoroughly as the existing code does.

Today, losing the only registered credential loses the identity forever. Build **backup credentials**: a second hardware key or passkey endorsed by the root identity so a family can survive a lost phone. docs/UI.md §3.1 already specifies the onboarding prompt ("Lose every key, lose this identity…").

### Design constraints (from the existing architecture — verify each against SDS.md before coding)
- A backup credential is an ADDITIONAL WebAuthn credential recorded in the Identity record, added via an assertion ceremony signed by the CURRENT root credential (same pattern as `seal.endorse.v2` device endorsement and `seal.revoke.v1` — a root-signed statement whose challenge commits to the new credential's ID and public key; version it `seal.backup.v1`).
- Sign-in must accept any non-revoked credential on the identity (extend the allow-list the directory lookup builds — see the security-key sign-in notes in HANDOFF re: credentialIDs as allow-list).
- A backup credential can be revoked by the root exactly like a device (reuse the revocation pattern).
- 1-key-1-identity `excludedCredentials` must include backup credential IDs, and tombstone/deletion paths must cover them.
- **No schema change if possible** — prefer appending to the existing Identity record's endorsements/revocations fields; if a new FIELD is unavoidable, follow the dev-env-then-deploy rule in HANDOFF and say so loudly in your report. No new record TYPES.
- What a backup key can NOT do: it does not recover message history (per-message keys are gone — say so in the UI, honestly), it recovers the IDENTITY and friendships.

### UI
"Backup keys" section in the Circle/Profile keys panel (KeyCard pattern): add ("Add a backup key" → ceremony sheet, hardware key or passkey), list, revoke. Post-registration blocking prompt per UI.md §3.1 with the exact honest copy direction there ("Nobody can reset it — not us, not Apple"), with "I accept the risk" fallback. In Parent Mode (if merged), the prompt is aimed at the helper: "Add the family helper's key as backup."

### Definition of done
Builds clean; simulator walkthrough of add/list/revoke with passkeys; sign-in with the backup credential exercised in dev CloudKit; excluded-credentials and tombstone paths covered; HANDOFF.md entry + SDS.md addendum describing `seal.backup.v1` exactly; commit only your files. Flag anything that requires a CloudKit console step as a numbered ops checklist for Nathan.
