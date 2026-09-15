# App Store listing copy

**Date:** 2026-08-28 · **Companions:** [COLDSTART.md](COLDSTART.md) · `site/index.html`

Paste-ready copy for App Store Connect, matching the positioning the site now
carries: **Seal is for the things you cannot afford to send to the wrong
person.** The current listing says "Seal: Provably Human Chat" with the
subtitle "Provably human group chat", which is the anti-bot pitch from
VISION.md and no longer matches either the app or the site.

Character limits are Apple's. Counts are in brackets.

## Name (30 max)

```
Seal: Private Messenger
```
[23] Plain and searchable. The differentiation lives in the subtitle, because
the name field is where people search and "Provably Human" is not a phrase
anybody types into the App Store.

## Subtitle (30 max)

```
For what you can't unsend
```
[25]

## Promotional text (170 max, editable without a new build)

```
A private photo. A wallet address. An account number. Send one to the wrong person and you can't take it back. In Seal there is no wrong person on the other end.
```
[159]

## Keywords (100 max, comma separated, no spaces after commas)

```
encrypted,private,messenger,secure,e2ee,photos,crypto,wallet,passkey,disappearing,inperson,seal
```
[94] Do not repeat words already in the name or subtitle. Apple indexes those
separately.

## Description

```
Some messages you can't unsend. Those are the ones that need a Seal.

A private photo. A wallet address. An account number. A password. If it reaches
the wrong person, you cannot take it back. Seal is built for exactly those
messages, and for nothing else.

HOW IT WORKS

Set up in person. You and the other person stand together and tap once. That
moment is the whole security model, and it is the one thing a stranger on the
internet can never copy. No usernames, no phone numbers, no password resets,
nothing that can be stolen remotely.

Send it privately. Everything is encrypted on your phone before it leaves, and
signed by the phone that sent it. Set messages to disappear on a timer. Seal
tells you when somebody takes a screenshot.

Seal what can't be wrong. Wallet addresses, account numbers and payment
instructions travel as Sealed Cards: locked exactly as written, copied
character for character, and impossible to mistake for ordinary chat.

WHY NOT JUST SEND IT NORMALLY

Phone numbers get spoofed. SIM cards get swapped. A voice can be cloned from ten
seconds of audio. A photo in an ordinary chat quietly ends up in a cloud backup
neither of you controls. Every channel you already use trusts a number or a
voice, which are the two things a stranger fakes best. Seal trusts neither.

WHAT SEAL DOES NOT DO

Seal proves a message came from that person's phone. It does not know whether
what they are asking for is wise, and it cannot tell you their phone is still in
their hands. If a request feels off, call them.

Disappearing messages are removed from both phones on schedule. Seal tells you
when somebody screenshots a chat, but it cannot stop a second camera pointed at
a screen. No app can.

BUILT DIFFERENT, ON PURPOSE

There is no server holding your messages, so there is nothing to breach. There
are no passwords and no account resets, so there is nothing to phish. We cannot
read anything you send, which also means we could not sell it if we wanted to.

Seal requires you to meet the people you message. That is not a limitation we
are apologising for. It is the product.
```

## Rules this copy follows

1. **Never names intimate photos.** "A private photo" and nothing more. App
   Store Review Guideline 1.1.4 bans overtly sexual material and 1.2 says apps
   used primarily for pornographic content may be removed without notice. The
   capability is fine and every major messenger has it. Saying it in the listing
   is what gets an app rejected or pushed to 18+.
2. **No post-quantum claim.** README.md and SDS.md still say ML-KEM-768.
   `HybridKEM.swift` says X25519, HKDF and AES-256-GCM with ML-KEM as a TODO.
   That sentence must not reach this listing while it is untrue.
3. **The honest-limits paragraph stays in.** Someone arriving for the private
   photo case will assume screenshots are impossible unless told otherwise.

## Still to change in App Store Connect

- App name and subtitle (above).
- Age rating: answer the updated questionnaire, including the social media
  questions that become required for submission in September 2026. 4+ is wrong.
- App Privacy: "Data Not Collected" is inaccurate. Display names live in the
  public directory, so it is Name, app functionality, not linked to identity.
