# Prompt for Fable: Sealed Card compose flow

Copy everything below the line into the Fable session (repo `~/Documents/GitHub/Seal`).

---

You are working on **Seal**, an iOS 26+ SwiftUI E2EE messenger with no backend (CloudKit public DB as transport). The Sealed Cards feature already ships and works. Your job is a **UI restructure of one screen**, not a feature.

## Read before writing any code

- `docs/CARDS.md` — what a Sealed Card is, what it proves, and (critically) what it deliberately does **not** prove
- `docs/UI.md` §1 — the "Vault Warmth" design language
- `Seal/Views/CardComposeSheet.swift` — the file you are rewriting
- `Seal/Cards/SealedCard.swift` — the model and its validation
- `Seal/Views/CardBubble.swift` — how the card renders once sent, so your preview matches it
- `HANDOFF.md` — the 8/25 sealed-cards entry

Build and run it in the simulator with the launch argument `-SealDemoMode` before you change anything. That seeds a demo identity and chats (see `DemoFixtures.swift`), including one Sealed Card in the "Sam" conversation. Open a chat and tap the brass seal button at the head of the composer to see the sheet as it stands.

## The problem

The compose sheet works and reads cleanly, but it's built as a **form**, and a form asks you to fill fields in order. What this flow actually is: *transcribe one string correctly, then commit to it irreversibly.* Those are two different mental modes and the sheet currently does both at once. Concretely:

1. **The warning fires when there is nothing to check.** "This will be sealed exactly as written. Check every character." is the most prominent element on screen, sits above an empty form, and has scrolled off the top by the time the user has actually pasted an address. It is doing no work at the moment it matters.
2. **The value field is the fifth element down**, roughly two-thirds through the scroll — below `Title`, which is only metadata for a chat-list row.
3. **"Seal and send" is bright brass and live on an empty form** — the most dominant element on a screen where it cannot succeed.
4. **The honesty paragraph is entirely below the fold.**
5. **The navigation title truncates to "Seal a…"** — two toolbar buttons plus a title is one element too many for that bar.

## What to build

Split the sheet into **two steps inside the same sheet** — not a four-step wizard (three fields don't need one), and not a modal on top of a modal. The split that earns its extra tap is *compose* vs. *commit*.

**Step 1 · Compose.** Type picker, then straight into the value field: large, monospaced, paste-first. `Title`, `Asset`, and `Note` are secondary — collapse them behind an "Add a label" disclosure, or fade them in once the value is non-empty, whichever you judge better after seeing it running. **No warning banner on this step.** Primary button: **Review**.

**Step 2 · Review and seal.** The chunked value at full size at the top, rendered exactly as `CardBubble` will render it. **The warning belongs here, immediately above the characters it is telling you to check.** Below it: the destination chat, the disappearing-messages warning when the chat has a TTL, and the honesty paragraph. Primary button: **Seal and send**. Going back to step 1 must preserve everything typed.

Fix the truncated navigation title while you're in there.

## Hard constraints — read these twice

**The copy in this sheet is specification, not filler.** Seal's whole product claim is a narrow, carefully hedged one, and several of these strings exist because a looser phrasing would be a lie with money attached. You may reword for the new layout **only** where the replacement is exactly as true and exactly as specific. Never drop one, never soften one, never make a card sound stronger than it is.

- **Never** describe a card or its value as "verified", "attested", "notarized", "confirmed", or "safe". A card is "sealed". `docs/CARDS.md` §5 and §6 explain why — a Custody Receipt is a strictly stronger claim and the two must stay visibly different.
- The honesty paragraph — *"A sealed card proves these exact bytes came from your identity. It doesn't prove the address is correct…"* — must survive, and must be **on screen at the commit moment**, not below a fold.
- `Title`'s helper text says it is **not part of what's sealed for verification**. That distinction stays.
- `Note`'s framing as **not part of the sealed value** stays.
- The value field's *"This is the only field a recipient can copy"* stays.
- The TTL warning stays and must never imply cards are exempt from disappearing messages. They are not — they inherit the chat's TTL and burn like every other message, deliberately.

**Behaviour that must not regress:**

- Autocorrect and autocapitalisation stay **off** on the value field, for every card type. An autocorrected wallet address is a silent, total loss.
- Keep the system `PasteButton` — an explicit tap grants pasteboard access without the "Allow Paste?" prompt a programmatic read would trigger.
- The value field stays monospaced.
- The live preview must show exactly what the recipient will see, chunking included, with the note that the spaces are for readability and are not part of the address and are not copied.
- Validation errors are shown inline. The primary button is **never inert** — tapping it with an empty or malformed value must *say what is wrong* rather than sit disabled and leave the sender guessing. This is deliberate; there's a comment saying so.
- Keep the byte counter.

## Do not touch

- `Seal/Cards/SealedCard.swift` — the model, `MessageProof`, and `SealedCard.validated(...)`. In particular: validation trims **surrounding** whitespace only and never rewrites interior bytes, and there is **no per-chain checksum validation, ever**. Both are load-bearing decisions, not omissions.
- `Seal/Chat/ChatEngine.swift` — the wire format, `sendCard`, `fallbackText` handling, `MessageProof`, `verifyCard`.
- `Seal/Views/CardBubble.swift` — the bubble and detail sheet are out of scope.
- Anything under `Seal/Receipts/`, `Seal/Views/ReceiptsView.swift`, `Seal.xcodeproj/`, or the other files already modified in the working tree. **The tree is dirty with unrelated in-progress work — leave all of it alone and do not stage it.**
- No new dependencies, no new CloudKit record types, no schema changes.

## Notes on the codebase

- New files under `Seal/` auto-join the target (file-system-synced groups), so adding one needs no `.xcodeproj` edit.
- SwiftUI's `ViewBuilder` tops out at **10 direct children**; the current `VStack` is already grouped in threes because of it.
- Security surfaces use SF Pro, social surfaces use SF Rounded. Brass (`SealTheme.brass`) is reserved for trust moments only. Orange is for cautionary copy, matching the TTL and screenshot notices elsewhere. **No seal mascot on this screen** — `UI.md` §1.1 keeps it off security surfaces.
- Dynamic Type through XL and VoiceOver both matter here (`UI.md` §5). The value field already sets an accessibility label to the raw string and spells out characters for addresses — keep that.

## Definition of done

- Builds clean, and you have **run it in the simulator** and stepped through sending all three card types.
- Screenshots of both steps, at default and at an accessibility text size.
- Going back from step 2 to step 1 preserves every field.
- The sender can still get a malformed value rejected with a readable reason.
- `git diff` shows only `Seal/Views/CardComposeSheet.swift` (plus any new view file you add) and docs.
- Update the `docs/CARDS.md` compose section and the 8/25 `HANDOFF.md` entry if the flow description no longer matches.
- Commit only your own files, message style consistent with `git log`.

## Before you start

Read the files, run it, and tell me what you think. If after reading `docs/CARDS.md` you think the two-step split is the wrong call, say so with your reasoning **before** writing any code — I'd rather hear it now.

One open question I have not decided: whether step 2's confirm should be **press-and-hold** ("Hold to seal"). `UI.md` §1 says security actions deserve mass, and holding makes irreversibility felt rather than merely stated — but it risks reading as a gimmick. **Do not build it in this pass.** Give me your opinion in your report and I'll decide.
