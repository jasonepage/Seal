# Where Seal stands

**Updated:** 2026-08-28 · **Owner:** Nathan (Jason Page) · natepage67@gmail.com
**Repo:** `~/Documents/GitHub/Seal` · iOS 26.5+, SwiftUI, no backend

New Swift files under `Seal/` join the target automatically (file-system-synced
groups), so no project edits are needed to add one.

## What Seal is

**A signed record of what happened between two people who met in person.** The
record is of events, not content: it can show that a sealed card carrying a
payment address was sent at a given moment, and prove those exact bytes have not
changed, without ever being able to read the address.

Chat is the surface. The record is the product. Full direction and spec:
[docs/RECORD.md](docs/RECORD.md).

## Identifiers

- Team `8C4BM6A82T` · Bundle `io.github.jasonepage.Seal`
- CloudKit container `iCloud.io.github.jasonepage.Seal`
- WebAuthn relying party `sealmessenger.com` (Porkbun domain, Cloudflare zone,
  Worker `plain-darkness-c20d` serves the site and the AASA file). Deploy the
  site with `npx wrangler deploy` from the repo root.
- App Store Connect: SKU `seal001`, internal TestFlight live, external group
  "parents" created.

## What works today

Two people on two phones exchange end-to-end encrypted text and photos, verified
on real hardware. Registration by hardware key or passkey, the in-person
ceremony, groups, disappearing messages, screenshot notices, replies, reactions,
push with the app closed, sealed cards, custody receipts, vouched
introductions, backup keys, block and report.

## What is blocking

1. **The CloudKit schema is not deployed to Production.** Until it is, backup
   keys, the directory scan, `excludedCredentials` and security-key sign-in are
   all broken in TestFlight, and they break quietly. Steps:
   [docs/CLOUDKIT_DEPLOY.md](docs/CLOUDKIT_DEPLOY.md). **Only Nathan can do
   this.**
2. **Nothing since 2026-08-28 has been compiled.** A large amount of code and
   copy changed in one session. Build before anything else.
3. **A demo video** is the one real App Store submission blocker.
   [docs/APP_STORE.md](docs/APP_STORE.md) has the rest of the list, including an
   age rating item with a September 2026 deadline.

## What is next

Phase 3 of the record: the export. A JSON document carrying every event with its
signatures and timestamp tokens, a readable rendering of it, and
`tools/verify_record.py`, a standalone verifier. Without that verifier, "anyone
can check this" is marketing. [docs/RECORD.md](docs/RECORD.md) §6.

Then ten pairs of real people on TestFlight for three weeks. Not ten people,
pairs, because one person alone gets nothing. The question is not whether they
chat. It is whether anyone creates a record and whether anyone ever pulls one
back out.

## Recent work, newest first

- **Record phase 2**: RFC 3161 trusted timestamps, off by default, with the DER
  encoder and status parser tested against OpenSSL. RECORD.md §13.
- **Record phase 1**: the event projection and the timeline screen, plus
  tombstones so a record line survives its content burning. RECORD.md §11, §12.
- **The site and the listing**: sealmessenger.com rewritten for the new
  positioning and deployed, App Store copy drafted. COLDSTART.md part 3,
  docs/STORE_COPY.md.
- **The shell merge**: one shell, no tab bar, Simplified mode became "Bigger
  text", evidence moved behind Advanced. COLDSTART.md part 2.
- **Cold start**: the invite path, which did not exist at all, plus a rewritten
  first run. COLDSTART.md part 1.

## Before you debug anything

[docs/GOTCHAS.md](docs/GOTCHAS.md). Most of what is in there cost a day to find
and looks like a different problem from the outside.

## Working style

Numbered steps for ops tasks. Concise replies. No em dashes anywhere, including
in app copy. Commit after each working milestone, and check `git status` first
because the working tree is often ahead of the last commit. Mom is a tester.
