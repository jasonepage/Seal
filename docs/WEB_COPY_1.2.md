# Copy changes for Seal in a browser (1.2)

Drafted 2026-10-16 from PRODUCT.md section 15. **Stage A went live with
1.2a on 2026-10-17. Stage B was applied with 1.2b (built 2026-10-17), with one
addition: the relay can also delete what it delivered, since CloudKit lets a
record's creator write it.** Kept for the record.
Apply each stage in the same commit that ships it, and not before, or the
site will describe a page that does not exist yet.

- **Stage A** ships with 1.2a: the recipient page, sponsored keys only, no
  relay.
- **Stage B** ships with 1.2b and the 1.2 app: browser devices for
  everyone, the key holder page, the relay.

The one line, used everywhere the old "there is no Seal server" was:

> Nothing we run can read, open or change your envelopes.

It never appears without the two sentences that keep it honest: the page
is code we serve, and (from stage B) the relay can fail to deliver.

---

## site/how-it-works.html, line 54 (the Storage row)

**Now:** Apple CloudKit public database, holding ciphertext and public
keys. There is no Seal server.

**Stage A:** Apple CloudKit public database, holding ciphertext and public
keys. Nothing we run can read, open or change your envelopes. The
recipient page on this site is code we serve, and it runs in your
browser.

**Stage B, add:** Key holders on the web send records they have already
signed through a small relay on our Cloudflare Worker. It cannot read or
forge them. It can only fail to deliver one, so the page checks Apple’s
copy before it says anything was saved.

## site/objections.html, line 38 (“A dead man’s switch is not new.”)

**Now:** no server of ours to subpoena, hack or switch off

**Stage A:** no server of ours holding anything to subpoena, hack or
switch off

## site/objections.html, line 41 (“One developer. What happens when you quit, or die?”)

**Now:** There is no Seal server to switch off.

**Stage A:** No server of ours holds your envelopes, so there is nothing
to switch off. If this website went away, the recipient page would go
with it; the iPhone app would not notice.

**Stage B:** No server of ours holds your envelopes, so there is nothing
to switch off. If this website went away, the web pages and the relay
behind them would go with it; on an iPhone, nothing would change.

## site/objections.html, line 49 (“Open source means nothing…”), new paragraph after it

**Stage A:** The web page is weaker on this point, and we would rather
say so than have you find out. A page is fetched fresh on every visit and
skips Apple’s review, so whoever controlled this website could change it,
even for one visitor. The page loads no code from anywhere else, its
source is in the public repository, and the hashes of the files it serves
are published there to compare. If that is not enough, open your
envelopes in the iPhone app, which never depends on this site.

## site/objections.html, line 62 (“iPhone only. Useless.”)

This answer currently says there is no web version and why. Replace it.

**Stage A:** The person writing needs an iPhone or iPad, and that will
stay true. The reason is the Secure Enclave, the part of an iPhone or iPad
that makes a key and never hands it back out, not to Seal and not to
Apple. The people you write to are different. If you register a security
key for someone, they can open their envelopes at sealmessenger.com from
any current browser, Android included. The page never puts a key in
browser storage: their private key stays locked under a secret only that
physical key can compute, is unlocked in memory while the page is open,
and is gone when the tab closes. A bad browser extension in that same tab
could still see it while it is open, which is why the iPhone app remains
the stronger choice. An Android app is still the most requested thing.

**Stage B, change the middle to:** The people you write to and the people
holding your keys are different. With a security key, they can open
envelopes, confirm they still have their key, start or object to a claim,
and tap, at sealmessenger.com from any current browser, Android included.

## site/objections.html, line 65 (“Why does it cost money?”)

**Now:** there is no server to keep paying for

**Stage A:** nothing we run stores your envelopes, so there is nothing to
keep paying for

(Check this is still true once the relay runs. If the Worker ever costs
money, say so here.)

## site/objections.html, line 70 (the “Checked against the source” note)

**Stage A:** Checked against the source on [ship date]. This pass: the
web recipient page, and what it changes about trusting this site.

## site/privacy.html, line 31 (“What we can never see”)

**Now:** Seal has no server of its own and no way to decrypt anything.

**Stage A:** Nothing we run can read, open or change your envelopes, and
we have no way to decrypt anything.

**Stage A, new section after “What is stored, and where”:**

> **If you use the web page**
>
> sealmessenger.com is hosted by Cloudflare. Like any website, Cloudflare
> sees your IP address and which pages you load. The page talks to Apple’s
> CloudKit straight from your browser; nothing you open passes through us.
> The page stores nothing in your browser.

**Stage B, add to that section:**

> When a key holder confirms, claims, objects or taps on the web, the
> signed record goes through our relay on Cloudflare on its way to Apple.
> The relay sees that record, which is the same thing anyone can read in
> the public database once it is saved, and your IP address. It keeps no
> copy.

**Stage B, the security key paragraph (line 33):** after “This is the one
place any private key material leaves a phone”, change to: “This, and the
device key the web page makes for you if you use it, which is stored and
locked the same way, are the only places any private key material leaves
a phone.”

## README.md

**Line 14, the badge.** Now: `backend-none`. Stage A:

    <img alt="Nothing we run can read your envelopes" src="https://img.shields.io/badge/server-holds_nothing-8C6A2B">

**Line 41.** Now: “There is no Seal server: the encrypted envelopes sit
in…”. Stage A: “Nothing we run can read, open or change your envelopes:
the encrypted envelopes sit in…”

**Line 67, Platform.** Stage A: “Owners: iPhone and iPad, iOS 18 and
later. Recipients with a security key registered for them: any current
browser at sealmessenger.com. No Android app.” Stage B: “Recipients and
key holders with a security key: any current browser…”

**Line 68, Dependencies.** Stage A: “The app: none. No third party code,
no analytics, no crash reporter. The web page: one small audited library
for ML-KEM-768, which browsers do not have built in, vendored and pinned.”
Stage B, if signing needs it: “two small audited libraries, for
ML-KEM-768 and P-256”.

**Line 232, Storage.** Stage A: replace “No Seal server.” with “Nothing we
run stores anything.” Stage B, add: “Key holders on the web write through
a stateless relay on our Cloudflare Worker, which only passes on records
they already signed.”

## Lines that stay as they are

- site/support.html line 60 (the interview runs on the phone) and line 72
  (iCloud is the only place an envelope can go): both still true, since
  the relay stores nothing.
- site/verify.html line 54 and README line 156 (“no server to order
  them”): still true, the relay orders nothing.
- site/limits.html line 68 (“no server and no clock everyone can trust”):
  still true.

## In the app, with the 1.2 release (optional)

Seal/Views/Onboarding/SealOnboardingView.swift line 205 says “No server.
Everything is encrypted on your phone, and nothing leaves it.” It is
about the owner, who never touches the relay, so it is not wrong. For one
voice everywhere it could become “Nothing we run can read your
envelopes. Everything is encrypted on your phone before it leaves.”
OnboardingCopyTests does not check this string.
