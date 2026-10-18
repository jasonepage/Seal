# For AI agents and new contributors

The website says as little as it can on purpose. This repository says
everything. Read in this order.

## What Seal is

An iPhone app for sealed envelopes: letters, photos and passwords that open
only after the writer has been silent for a long time and enough of their
key holders agree. Recipients and key holders with a security key can also
use a web page, sealmessenger.com/open.

## Where things are

| Path | What |
|---|---|
| `docs/PRODUCT.md` | What the product promises and why. Section 15 is the web page. |
| `docs/RELEASE.md` | How a release works, step by step. |
| `docs/SDS.md`, `docs/SRS.md` | Design and requirements. |
| `docs/GOTCHAS.md` | Things that broke before. Read before changing CloudKit or keys. |
| `HANDOFF.md` | The running log of what was done and what is next. |
| `CHANGELOG.md` | What changed in each version. |
| `Seal/Estate/` | The heart: keys, the signed record, the release rules. |
| `Seal/Crypto/`, `Seal/Identity/` | Encryption, Shamir, WebAuthn, devices. |
| `Seal/SelfTest/` | Tests. They run on every DEBUG launch; `docs/TESTS.md` lists them. |
| `site/` | The website (static). `site/open/` is the web page for recipients and key holders. |
| `worker/` | The relay key holders on the web write through. |
| `tools/webtests/` | Tests for the web page and the relay: `sh tools/webtests/run.sh`. |
| `tools/vectors/` | Checks the web page's crypto against the app's own Swift output. |
| `tools/verify_capsule.py` | Checks an exported record with no Seal code at all. |

## House rules

- `python3 tools/check_house_rules.py` must pass before every commit.
- No em dashes. Plain, short copy. User facing text says "key holder".
- The web page must decide releases exactly as the phone does. A change to
  `Seal/Estate/ReleaseFeed.swift` or `ReleaseMachine.swift` needs the same
  change in `site/open/js/release.js` and a passing `tools/webtests` run.
- Nothing secret goes in a file. The relay's private key is a Cloudflare
  secret.
