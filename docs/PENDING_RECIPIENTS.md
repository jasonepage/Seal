# Envelopes for people who are not on Seal yet

**Date:** 2026-09-16 · **Status:** design only, decision needed · **Companions:** [PRODUCT.md](PRODUCT.md) section 8 · [SDS.md](SDS.md) section 2 · [RELEASE.md](RELEASE.md)

## 1. The problem

Today every recipient must have an iPhone, have Seal, and have met the
owner in person. That is the isolation promise doing its job: an
envelope is wrapped to the recipient's own phone, so nobody else,
including the key holder who combines the keys, can read it.

It also stops many people from finishing. A dad wants to write to his
daughter. She uses Android and lives in another state. He can write the
envelope tonight (the app allows a draft to a typed name) but it can
never seal, and he knows it.

This note lays out three honest options. For each: what it weakens, who
could read the envelope early, and what the app would have to say to the
owner. It ends with a recommendation. Nothing here is built. The human
decides.

## 2. Why the naive version fails

"Register a second key as Emma on Dad's phone and hand her the key." It
sounds right and it is wrong twice. Envelopes are wrapped to the phone
that registered the key, not to the key, so Emma's envelope would be
wrapped to Dad's phone and nothing else; when her brother plugs the key
into his iPhone years later that phone has brand new keys and can open
nothing. And Dad's phone stays an endorsed device of "Emma" forever, so
whoever holds his unlocked phone after the release can read her
envelope. Both halves of that are the isolation promise breaking.

## 3. Option A: a sponsored key (the key carries a secret)

**What it is.** The owner registers a spare hardware key as the
recipient's identity, on the owner's phone, with the WebAuthn PRF
extension turned on. PRF (a pseudo random function) lets the key compute
a secret from a challenge, the same secret every time, for whoever holds
the key and its PIN. Seal makes a fresh decryption key pair for the
recipient, locks the private half under that PRF secret, and publishes
the locked copy in the directory beside the public half, as a "virtual
device" endorsed by the recipient's root credential. Envelopes are
wrapped to that public half exactly as they are wrapped to a phone
today. The owner hands over the key like a house key.

When the time comes, the recipient plugs the key into any iPhone,
signs in, the PRF secret unlocks the private half, and the envelope
opens. Her brother's iPhone works. A borrowed iPhone works. Her own
iPhone, if she ever gets one, works.

**What it weakens.** Nothing in the record and nothing for the key
holders. What changes is who "Emma" is: whoever holds the key and its
PIN. Today "Emma" is a person who stood next to Dad. Under this option
"Emma" is a small object Dad handed to someone.

**Who could read the envelope early.** Nobody, still. The private half
is unlocked only by the PRF secret, which needs the physical key and
its PIN. The owner's phone never holds the private half in the clear
after registration; it is made, locked, published and forgotten in one
step. If the key is stolen with its PIN, the thief is Emma, but still
cannot open anything until the release, because the table is also
under the Estate Key.

**What the app would have to say to the owner.** "This key is Emma. Set
a PIN on it. Give it to her the way you would give her a house key.
Anyone holding it with the PIN can read her envelope after the release.
If she loses it, the envelope is lost with it; you can hand her a new
key and seal again while you are alive."

**Cost.** PRF for hardware security keys is in Apple's framework from
iOS 26.4 (`ASAuthorizationSecurityKeyPublicKeyCredentialRegistrationRequest.prf`,
`ASAuthorizationPublicKeyCredentialPRFRegistrationInput`, and the
assertion side). The app already requires 26.5. Passkeys cannot be used
for this, because a passkey lives in Dad's iCloud Keychain, not on an
object he can hand over. Which physical keys support PRF (the CTAP
`hmac-secret` extension) varies: current YubiKey 5 series does; older
and cheaper keys may not. The registration screen must test for it and
refuse plainly. Estimated build: a proxy registration ceremony, a
"virtual device" endorsement type with the locked private half, the
sign-in path that unlocks it, and directory changes. About the size of
Phase 3. Uncompiled, it is the riskiest code in the app.

## 4. Option B: a key holder vouches after release, and the envelope is re-wrapped then

**What it is.** The envelope is sealed today to nobody: its content key
sits in a table wrapped to the owner's devices and, in a second copy,
to a named key holder ("Karen will hand this to Emma"). After the
release, Karen meets Emma in person, Emma installs Seal, they run the
ceremony, and Karen's phone re-wraps the envelope to Emma's new phone.

**What it weakens.** The isolation promise, exactly where it matters.
Karen can read the envelope. She is not supposed to be able to read
anything, and PRODUCT.md section 7 says so. A key holder who can read
one envelope is a different kind of person than a key holder who can
read none, and the owner would have to choose which key holder gets to
be that person.

**Who could read the envelope early.** Karen, the moment the release
happens, whether or not Emma ever turns up. Not before the release.

**What the app would have to say.** "Karen will be able to read this
envelope. Choose Karen because you would be all right with that."

**Cost.** Small. It is a second release wrap on one table and a
re-wrap ceremony. It also needs Emma to get an iPhone eventually, which
is the problem we started with.

## 5. Option C: a printed share

**What it is.** The envelope's content key is split, and one piece is
printed on paper (a QR code) and handed to Emma now. After the release,
the other piece is published with the Estate Key. Emma types or scans
the paper into any device that can run the verifier, and reads the
envelope with no Seal, no iPhone and no account.

**What it weakens.** The "nobody can open it early" promise becomes
"nobody can open it early unless the paper and the record are both in
hand and the release has happened," which is fine, and "a key holder
learns nothing" stays true. What it actually loses is the app: the
recipient's experience is a script on a laptop, not a letter on a
phone. The photos, the voice and the video would need a reader that
does not exist yet.

**Who could read the envelope early.** Nobody. After the release,
anyone holding the paper.

**What the app would have to say.** "Print this and give it to Emma.
Whoever holds the paper after the release can read the envelope. It
cannot be read before. Keep a copy somewhere the family will find it."

**Cost.** Medium. Key splitting is already in the app (Shamir). The
printed QR and the owner side are a day. The reader is the real cost:
`tools/verify_capsule.py` would grow an `--open` mode that takes the
paper and the capsule and writes out the letter and the media. Plain
Python, documented in CAPSULE.md, no phone needed.

## 6. Recommendation

Build A. It is the only option that keeps every promise in PRODUCT.md
section 7 intact and still gives the recipient a phone experience, and
it is the one Jason described unprompted, which usually means it is the
one people will understand. Its one real cost is that a key is now a
person, and the app has to say that in plain words at the moment of
handing it over. Do C second, later, as the paper fallback for a
family with no iPhones at all, since most of it is a script. Do not
build B; it asks the owner to pick which key holder gets to read a
letter, and the honest version of that sentence will stop people from
finishing more surely than the Android problem does.

**Not built.** The human decides. If A, the next batch is: the proxy
registration ceremony, the virtual device endorsement, the PRF unlock
on sign in, a hardware test matrix in
`docs/SECURITY_KEY_TEST_MATRIX.md`, and a self test that a virtual
device with a wrong PRF secret opens nothing.
