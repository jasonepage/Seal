# Seal — App Review submission pack

Everything App Review needs, plus the metadata fields that map to the guidelines
that reject UGC apps (1.2, 5.1.1(v), age rating, privacy labels, encryption).

---

## 1. Paste into App Store Connect → App Review Information → Notes

> Seal is an end-to-end encrypted group chat where every friendship is created
> in person: one person taps their FIDO2 hardware security key (or approves with
> a passkey / Face ID) on the other person's phone, which cryptographically
> proves both people are real humans who physically met. There are no usernames,
> phone numbers, or passwords.
>
> HOW TO REVIEW WITHOUT A HARDWARE KEY OR A SECOND PERSON
> The in-person friend ceremony requires two people and a security key or
> passkey, which cannot be reproduced in a single-reviewer session. To explore
> the full app with no hardware and no account:
>   1. On the first screen, type  SEALDEMO  as your name.
>   2. Tap "Start with Face ID." No authentication is required — you will enter a
>      demo account immediately.
> The demo account is entirely local (no network, no real users) and is
> preloaded with friends and conversations so every feature can be reviewed. A
> "DEMO" badge is displayed while in this mode.
>
> A demo video of the real hardware-key registration and the in-person friend
> ceremony is attached.
>
> CONTENT MODERATION (Guideline 1.2)
> Seal supports user-generated content and provides:
>   • Report — press and hold any message from another person → Report. This
>     flags the message to us and blocks the sender immediately; an in-app
>     confirmation is shown.
>   • Block — press and hold a message → Block, or open the verification panel
>     (shield icon in the chat header) and toggle Block next to a member.
>     Blocking hides the user from your chats and is reversible.
>   • Account deletion — "You" tab → Delete identity (permanent).
>   • Terms of Use & Community Guidelines with a zero-tolerance policy for
>     objectionable content: https://jasonepage.github.io/seal/terms.html
>   • We review reports and remove violating users within 24 hours.
> Because messages are end-to-end encrypted, moderation is report-driven: the
> reported message is included in the report by the reporter's device for human
> review. We have no access to conversations that are not reported.
>
> ENCRYPTION
> Seal uses only Apple's CryptoKit (standard, exempt encryption).
> ITSAppUsesNonExemptEncryption is set to NO. No sign-in is required to review.
>
> CONTACT
> jasonepage@gmail.com

---

## 2. Other ASC fields to set (these reject UGC apps if wrong)

- **Age rating (do NOT use 4+):** complete the rating questionnaire honestly for
  user-generated content / unrestricted in-app communication. Expect **13+**
  minimum. A 4+ rating on a UGC chat app is itself a rejection / removal risk.
- **App Privacy → Data Collected = "Name."** Display names are published to the
  public directory, so "Data Not Collected" is inaccurate. Mark Name as: used
  for **App Functionality**, **Not Linked** to the user, **not** used for
  tracking. Everything else: Not Collected.
- **Privacy Policy URL:** https://jasonepage.github.io/seal/privacy.html
- **License Agreement (EULA):** either keep Apple's standard EULA or reference
  the custom Terms: https://jasonepage.github.io/seal/terms.html
- **Support URL:** https://jasonepage.github.io/seal/support.html
- **Demo video (FR-24):** record per the shot list (registration with key →
  onboarding → friend forge both directions → message both ways → Report/Block →
  Delete identity), then attach it in App Review Notes or host and link it.

## 3. Loose ends to align before you submit

- **Contact email — PARKED (do not ship a personal address).** Decision: keep
  `jasonepage@gmail.com` OUT of the app and off the public site. Before submit,
  stand up a dedicated address — recommended `abuse@sealmessenger.com` (and/or
  `support@`) via Cloudflare Email Routing (free; you already run the domain on
  Cloudflare), forwarding to whatever inbox you actually watch. Then point all
  of these at it: the site pages (terms/support/privacy), `ChatView.reportMailURL`,
  and `FriendsView.reportURL` (both currently `jaysubplays@gmail.com`). A 24h
  moderation promise only works if reports land somewhere you read — but it
  doesn't have to be your personal inbox.
- **Confirm the Terms URL host matches your Privacy URL host in ASC.** Both are
  on `jasonepage.github.io/seal/` here; if your ASC privacy link uses
  `sealmessenger.com`, publish `terms.html` there too and use that URL.
- **Tap-test Block and Report on device** (in the SEALDEMO account: Report a
  seeded friend, confirm the alert shows and their messages disappear). The
  block button only started compiling today.
- **Not legal advice.** The Terms page is a solid 1.2-oriented template, not a
  lawyer-reviewed contract. Have a professional look before relying on it.
