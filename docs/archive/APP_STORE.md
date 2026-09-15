# App Store status

Companions: [APP_REVIEW_NOTES.md](APP_REVIEW_NOTES.md) is the text for the
reviewer. [STORE_COPY.md](STORE_COPY.md) is the listing copy.

## The one real submission blocker

**A demo video.** A reviewer cannot perform a two-person in-person ceremony
alone. `SEALDEMO` shows seeded chats but not real cross-device messaging, so the
video is what proves the app does what it says.

## Still to do before submitting

1. **Age rating.** 4+ is wrong for an app with user-generated content. Answer
   the updated questionnaire honestly and expect 13+ at minimum. Apple's tiers
   are now 4+ / 9+ / 13+ / 16+ / 18+. Separately, responses to the social media
   questions became required for submission in September 2026.
2. **App Privacy.** Currently "Data Not Collected", which is inaccurate: display
   names sit in the public directory. It should be Name, app functionality, not
   linked to identity.
3. **Moderation.** Guideline 1.2 needs a filter, a report path with timely
   response, blocking, and published contact information. Block and report both
   exist. Missing: an actual moderation ACTION on a valid report (tombstone the
   reported identity via `deleteIdentity`), a written 24-hour response policy,
   and an end user licence agreement.
4. **`ITSAppUsesNonExemptEncryption`** is absent from `Info.plist`, so every
   upload asks the export compliance question. Note that the value is a
   declaration to the US government, not a convenience setting, and Seal wraps
   message keys with X25519, HKDF and AES-256-GCM over user content. The current
   App Store Connect answer is "None of the algorithms".
5. **Name and subtitle.** Still "Seal: Provably Human Chat", which matches
   neither the app nor the site. Replacement copy is in
   [STORE_COPY.md](STORE_COPY.md).
6. **Retest PIN'd security keys** over NFC and USB-C. See
   [GOTCHAS.md](GOTCHAS.md).

## What is already done

- Moderation mechanics: block is a local per-identity set
  (`ChatEngine.blockedHashes`, keychain `seal.blocks.<hash>`) that hides blocked
  senders and skips them on receive, reversibly. Report opens a pre-filled email
  to jaysubplays@gmail.com including the flagged message and both root hashes,
  and auto-blocks the sender. There is no backend and no Report record: reports
  land in a personal inbox. A mail client must exist on the device for the draft
  to open.
- App Store Connect metadata: promo text, description, keywords, support,
  marketing and privacy URLs, category Social Networking, content rights, DSA
  non-trader.
- The external TestFlight group "parents" exists. A build is added through the
  group, needs complete Test Information, and triggers Beta App Review.
- Sign-in is not required for review. `SEALDEMO` covers it.
- Release is set to automatic. Switch it to manual if approval should not mean
  instant launch.

## Reviewer access

Tell the reviewer to **enter `SEALDEMO` as their name and tap "Set up with Face
ID"**. No hardware key, no network, no real sign-in. That button label is named
in the notes, so renaming it means updating them.
