#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Standalone verifier for a Seal capsule (docs/CAPSULE.md, format version 1).

    python3 verify_capsule.py seal-capsule-XXXX.json [--strict]

Checks, and prints one line per check:

  1. every device endorsement in the capsule verifies under its identity's
     root public key (WebAuthn assertion over the seal.endorse.v3 commitment,
     or the canonical-length v2 commitment; relying party hash, user
     presence and clientData.type are enforced);
  2. every event's digest recomputes from its fields, its ECDSA P-256
     signature verifies under the device key it names, that device is an
     endorsed device of the actor it names, and the actor's role permits the
     event kind;
  3. every event's previousDigest names an event in the capsule (or is empty);
  4. every epoch event's commitments match the epoch material blob, and the
     blob's digest matches what the owner signed;
  5. every authorization's key tap verifies under the custodian's root key
     over the release challenge for that claim and record head;
  6. a released event's Estate Key matches the epoch's commitment;
  7. every RFC 3161 token: PKIStatus granted, carries the event digest, and
     its genTime is printed. If `openssl` is on the PATH the token's CMS
     signature is verified against the certificate embedded in the token;
     whether to trust that certificate's issuer is the reader's decision and
     the script says so.

Exit status 0 when every check passed, 1 otherwise. `--strict` also fails
on a token whose signature could not be checked.

Dependencies: the Python standard library and the `cryptography` package
(pip install cryptography). Nothing else. `tools/shamir_vectors.py` from the
same directory is imported for the field arithmetic used by --combine.

Optional: `--combine share1.hex share2.hex ...` combines raw Shamir shares
(index byte followed by the share bytes, hex) against the newest epoch's
commitments and prints the Estate Key if it matches. This is for a family
whose phones are gone and whose custodians can read their shares out of
their own capsules by other means; the app never needs it.
"""
import argparse
import base64
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

try:
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.exceptions import InvalidSignature
except ImportError:
    print("This verifier needs the 'cryptography' package: pip install cryptography")
    sys.exit(2)

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import shamir_vectors as shamir
except ImportError:
    shamir = None

OWNER_KINDS = {"estateCreated", "epochPublished", "policyChanged", "vaultUpdated", "heartbeat", "cancellation",
               # The owner deleted their account and said what to do (2026-09-16).
               "ownerDeparted"}
CUSTODIAN_KINDS = {"silenceObserved", "releaseClaimed", "objection", "objectionWithdrawn", "authorization", "released",
                   # "I still have my key" (2026-09-16). A receipt; never counted toward a release.
                   "custodyConfirmed"}

failures = 0


def ok(line):
    print("  ok   " + line)


def bad(line):
    global failures
    failures += 1
    print("  FAIL " + line)


def note(line):
    print("  note " + line)


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def framed(domain, fields):
    out = bytearray(domain.encode())
    for f in fields:
        out += len(f).to_bytes(4, "big")
        out += f
    return bytes(out)


def sha256(data):
    return hashlib.sha256(data).digest()


def p256_from_raw(raw64):
    return ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), b"\x04" + raw64)


def p256_from_x963(x963):
    return ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), x963)


def ecdsa_ok(pub, sig_der, message):
    try:
        pub.verify(sig_der, message, ec.ECDSA(hashes.SHA256()))
        return True
    except InvalidSignature:
        return False
    except Exception:
        return False


def webauthn_ok(assertion, pub, expected_challenge, rp_id):
    """The same checks WebAuthnAssertion.verify makes, with context enforced."""
    auth = bytes.fromhex(assertion["authenticatorDataHex"])
    client = base64.b64decode(assertion["clientDataJSONBase64"])
    sig = bytes.fromhex(assertion["signatureHex"])
    if len(auth) < 37:
        return False, "authenticatorData too short"
    if auth[:32] != sha256(rp_id.encode()):
        return False, "rpIdHash is not SHA256 of " + rp_id
    if auth[32] & 0x01 == 0:
        return False, "user presence flag unset"
    try:
        cd = json.loads(client)
    except Exception:
        return False, "clientDataJSON is not JSON"
    if cd.get("type") != "webauthn.get":
        return False, "clientData.type is %r" % cd.get("type")
    if cd.get("challenge") != b64url(expected_challenge):
        return False, "challenge does not match the commitment"
    if not ecdsa_ok(pub, sig, auth + sha256(client)):
        return False, "signature does not verify"
    return True, ""


def endorsement_commitment_v3(device_pub, kem):
    return sha256(framed("seal.endorse.v3", [device_pub, kem]))


def endorsement_commitment_v2(device_pub, kem):
    return sha256(b"seal.endorse.v2" + device_pub + kem)


def event_digest(e):
    return sha256(framed("seal.estate.event.v1", [
        e["id"].encode(), e["estateID"].encode(), e["kind"].encode(), e["actorHash"].encode(),
        bytes.fromhex(e["actorDevicePublicKeyHex"]), str(e["occurredAtEpoch"]).encode(),
        bytes.fromhex(e["previousDigestHex"]), base64.b64decode(e["payloadBase64"]),
    ]))


def release_challenge(estate_id, epoch, claim_id, head):
    return sha256(framed("seal.release.authorize.v1", [
        estate_id.encode(), str(epoch).encode(), claim_id.encode(), head]))


# ---- DER helpers for the timestamp token (shallow, reject-only) ----

def der_tlv(buf, i):
    """Returns (tag, value_start, value_end) for the TLV at i, or None."""
    if i >= len(buf):
        return None
    tag = buf[i]
    i += 1
    if i >= len(buf):
        return None
    first = buf[i]
    i += 1
    if first < 0x80:
        length = first
    else:
        n = first & 0x7F
        if n == 0 or n > 4 or i + n > len(buf):
            return None
        length = int.from_bytes(buf[i:i + n], "big")
        i += n
    if i + length > len(buf):
        return None
    return tag, i, i + length


def token_status(token):
    t = der_tlv(token, 0)
    if not t or t[0] != 0x30:
        return None
    t2 = der_tlv(token, t[1])
    if not t2 or t2[0] != 0x30:
        return None
    t3 = der_tlv(token, t2[1])
    if not t3 or t3[0] != 0x02:
        return None
    return int.from_bytes(token[t3[1]:t3[2]], "big")


def token_gentime(token, digest):
    at = token.find(digest)
    if at < 0:
        return None
    i = at + len(digest)
    serial = der_tlv(token, i)
    if not serial or serial[0] != 0x02:
        return None
    gt = der_tlv(token, serial[2])
    if not gt or gt[0] != 0x18:
        return None
    text = token[gt[1]:gt[2]].decode("ascii", "replace")
    if len(text) < 15 or not text.endswith("Z"):
        return None
    try:
        return datetime.strptime(text[:14], "%Y%m%d%H%M%S").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def openssl_verify_token(token, digest):
    """Verify the CMS signature against the certificate embedded in the
    token. Returns (result, detail) where result is True, False or None
    (could not check)."""
    if not shutil.which("openssl"):
        return None, "openssl not found on PATH"
    with tempfile.TemporaryDirectory() as d:
        resp = os.path.join(d, "resp.tsr")
        with open(resp, "wb") as f:
            f.write(token)
        # The response is TimeStampResp; the token inside is a CMS. Pull the
        # token out and its certificates.
        tok = os.path.join(d, "token.der")
        r = subprocess.run(["openssl", "ts", "-reply", "-in", resp, "-token_out", "-out", tok],
                           capture_output=True)
        if r.returncode != 0:
            return None, "openssl could not read the response: " + r.stderr.decode(errors="replace").strip()
        certs = os.path.join(d, "certs.pem")
        r = subprocess.run(["openssl", "pkcs7", "-inform", "DER", "-in", tok, "-print_certs", "-out", certs],
                           capture_output=True)
        if r.returncode != 0 or os.path.getsize(certs) == 0:
            return None, "the token carries no certificate to check against"
        r = subprocess.run(["openssl", "ts", "-verify", "-digest", digest.hex(), "-in", resp,
                            "-CAfile", certs, "-untrusted", certs],
                           capture_output=True)
        out = (r.stdout + r.stderr).decode(errors="replace")
        subj = subprocess.run(["openssl", "x509", "-in", certs, "-noout", "-subject"], capture_output=True)
        who = subj.stdout.decode(errors="replace").strip()
        if "Verification: OK" in out:
            return True, "signed by the certificate embedded in the token (%s). Whether to trust that issuer is your decision." % who
        return False, out.strip().splitlines()[-1] if out.strip() else "verification failed"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capsule")
    ap.add_argument("--strict", action="store_true", help="fail when a token signature could not be checked")
    ap.add_argument("--combine", nargs="*", metavar="SHAREHEX", help="combine raw Shamir shares against the newest epoch")
    args = ap.parse_args()

    with open(args.capsule, "rb") as f:
        cap = json.load(f)

    print("Seal capsule %s v%s, estate %s, exported %s by %s, state at export: %s" % (
        cap.get("format"), cap.get("version"), cap["estateID"][:8],
        datetime.fromtimestamp(cap["exportedAtEpoch"], timezone.utc).isoformat(),
        cap["exportedBy"][:8], cap.get("stateAtExport")))
    if cap.get("format") != "seal.capsule" or cap.get("version") != 1:
        bad("unknown format or version; this verifier reads seal.capsule v1")
        return finish()
    rp = cap["relyingPartyID"]
    owner = cap["ownerHash"]

    # 1. Identities and endorsements.
    print("Identities")
    roots = {}
    devices = {}   # hash -> set of x963 device keys that verify
    for h, ident in cap["identities"].items():
        try:
            root = p256_from_raw(bytes.fromhex(ident["publicKeyHex"]))
        except Exception as ex:
            bad("%s: root key does not parse: %s" % (h[:8], ex))
            continue
        if sha256(bytes.fromhex(ident["publicKeyHex"])) is None:
            pass
        roots[h] = root
        devices[h] = set()
        for e in ident["deviceEndorsements"]:
            dev = bytes.fromhex(e["devicePublicKeyHex"])
            kem = bytes.fromhex(e["kemBundleHex"])
            v3 = endorsement_commitment_v3(dev, kem)
            good, why = webauthn_ok(e["assertion"], root, v3, rp)
            version = "v3"
            if not good and len(dev) == 65 and len(kem) == 32:
                good, why = webauthn_ok(e["assertion"], root, endorsement_commitment_v2(dev, kem), rp)
                version = "v2 (canonical lengths)"
            if good:
                devices[h].add(dev)
                ok("%s (%s): device %s endorsed by root, %s" % (h[:8], ident["displayName"], dev[1:5].hex(), version))
            else:
                bad("%s: device %s endorsement rejected: %s" % (h[:8], dev[1:5].hex(), why))
    if owner not in roots:
        bad("the owner %s is not among the identities" % owner[:8])

    # 2 and 3. Events.
    print("Events")
    events = cap["events"]
    digests = {}
    for e in events:
        digests[event_digest(e)] = e
    custodians = set()
    epochs = {}
    admitted = []
    for e in sorted(events, key=lambda x: (x["occurredAtEpoch"], x["id"])):
        d = event_digest(e)
        label = "%s %s by %s at %s" % (e["kind"], e["id"][:8], e["actorHash"][:8],
                                       datetime.fromtimestamp(e["occurredAtEpoch"], timezone.utc).isoformat())
        if d.hex() != e.get("digestHex"):
            bad(label + ": stored digest does not match the recomputed one")
        dev = bytes.fromhex(e["actorDevicePublicKeyHex"])
        try:
            pub = p256_from_x963(dev)
        except Exception:
            bad(label + ": device key does not parse")
            continue
        if not ecdsa_ok(pub, bytes.fromhex(e["signatureHex"]), d):
            bad(label + ": signature does not verify")
            continue
        if dev not in devices.get(e["actorHash"], set()):
            bad(label + ": signing device is not an endorsed device of the actor")
            continue
        actor_is_owner = e["actorHash"] == owner
        if actor_is_owner and e["kind"] not in OWNER_KINDS:
            bad(label + ": the owner may not write this kind")
            continue
        if not actor_is_owner:
            if e["kind"] not in CUSTODIAN_KINDS:
                bad(label + ": a custodian may not write this kind")
                continue
            if e["actorHash"] not in custodians:
                bad(label + ": actor is not a custodian named by any earlier epoch statement")
                continue
        prev = bytes.fromhex(e["previousDigestHex"])
        if prev and prev not in digests:
            bad(label + ": previousDigest names an event that is not in the capsule")
        else:
            ok(label)
        admitted.append(e)
        if e["kind"] == "epochPublished":
            body = json.loads(base64.b64decode(e["payloadBase64"]))
            custodians = set(body["custodianHashes"])
            epochs[body["epoch"]] = (e, body)

    # 4. Epoch material.
    print("Epoch material")
    for n, (e, body) in sorted(epochs.items()):
        raw = cap["epochBlobsBase64"].get(str(n))
        if raw is None:
            bad("epoch %d: material blob missing from the capsule" % n)
            continue
        blob = base64.b64decode(raw)
        if sha256(blob) != base64.b64decode(body["materialDigest"]):
            bad("epoch %d: material blob digest does not match what the owner signed" % n)
            continue
        material = json.loads(blob)
        commitments = [base64.b64decode(c) for c in body["shareCommitments"]]
        blob_commitments = [base64.b64decode(s["commitment"]) for s in material["custodianShares"]]
        if commitments != blob_commitments:
            bad("epoch %d: share commitments in the blob differ from the signed statement" % n)
        elif base64.b64decode(material["estateKeyCommitment"]) != base64.b64decode(body["estateKeyCommitment"]):
            bad("epoch %d: estate key commitment differs from the signed statement" % n)
        elif [s["custodianHash"] for s in material["custodianShares"]] != body["custodianHashes"]:
            bad("epoch %d: custodian order differs from the signed statement" % n)
        else:
            suites = sorted({env["suite"] for s in material["custodianShares"] for env in s["envelopes"]})
            ok("epoch %d: %d shares, threshold %d, commitments match the owner's signed statement, wraps: %s" % (
                n, len(material["custodianShares"]), material["threshold"], ", ".join(suites)))
        for h, k in zip(body["custodianHashes"], body["custodianPublicKeys"]):
            if h in cap["identities"] and base64.b64decode(k).hex() != cap["identities"][h]["publicKeyHex"]:
                bad("epoch %d: the owner's signed key for custodian %s differs from the directory copy" % (n, h[:8]))

    # 5 and 6. Taps and the release.
    print("Release")
    for e in admitted:
        if e["kind"] == "authorization":
            body = json.loads(base64.b64decode(e["payloadBase64"]))
            root = roots.get(e["actorHash"])
            challenge = release_challenge(cap["estateID"], body["epoch"], body["claimID"],
                                          base64.b64decode(body["recordHeadDigest"]))
            a = body["assertion"]
            assertion = {"authenticatorDataHex": base64.b64decode(a["authenticatorData"]).hex(),
                         "clientDataJSONBase64": a["clientDataJSON"],
                         "signatureHex": base64.b64decode(a["signature"]).hex()}
            good, why = webauthn_ok(assertion, root, challenge, rp)
            if good:
                ok("tap by %s on claim %s verifies under their root key (a physical key was touched)" % (
                    e["actorHash"][:8], body["claimID"][:8]))
            else:
                bad("tap by %s on claim %s rejected: %s" % (e["actorHash"][:8], body["claimID"][:8], why))
        if e["kind"] == "released":
            body = json.loads(base64.b64decode(e["payloadBase64"]))
            key = base64.b64decode(body["estateKey"])
            ep = epochs.get(body["epoch"])
            if ep and sha256(key) == base64.b64decode(ep[1]["estateKeyCommitment"]):
                ok("released: the published Estate Key matches epoch %d's commitment" % body["epoch"])
            else:
                bad("released: the published Estate Key does not match the epoch commitment")

    # 7. Timestamps.
    print("Timestamps")
    stamped = 0
    for e in admitted:
        tok = e.get("timestampTokenBase64")
        if not tok:
            continue
        token = base64.b64decode(tok)
        d = event_digest(e)
        label = "%s %s" % (e["kind"], e["id"][:8])
        status = token_status(token)
        if status not in (0, 1):
            bad(label + ": token status is not granted (%r)" % status)
            continue
        if d not in token:
            bad(label + ": token does not carry this event's digest")
            continue
        gt = token_gentime(token, d)
        if gt is None:
            bad(label + ": could not read genTime from the token")
            continue
        stamped += 1
        result, detail = openssl_verify_token(token, d)
        if result is True:
            ok(label + ": authority time %s, %s" % (gt.isoformat(), detail))
        elif result is False:
            bad(label + ": authority time %s but the token signature FAILED: %s" % (gt.isoformat(), detail))
        else:
            (bad if args.strict else note)(label + ": authority time %s; signature not checked (%s)" % (gt.isoformat(), detail))
    if stamped == 0:
        note("no event carries a timestamp token; every time above is the actor's own clock")

    # Optional: combine shares.
    if args.combine:
        print("Combine")
        if shamir is None:
            bad("shamir_vectors.py not found beside this script")
        elif not epochs:
            bad("no epoch to combine against")
        else:
            n = max(epochs)
            body = epochs[n][1]
            commitments = [base64.b64decode(c) for c in body["shareCommitments"]]
            shares = []
            for hx in args.combine:
                raw = bytes.fromhex(hx)
                if len(raw) < 2 or raw[0] == 0:
                    bad("share %s: malformed" % hx[:8])
                    continue
                idx, body_bytes = raw[0], raw[1:]
                if idx - 1 >= len(commitments) or sha256(raw) != commitments[idx - 1]:
                    bad("share index %d: does not match the commitment the owner signed (custodian %s)" % (
                        idx, body["custodianHashes"][idx - 1][:8] if idx - 1 < len(commitments) else "?"))
                    continue
                ok("share index %d matches its commitment" % idx)
                shares.append((idx, body_bytes))
            threshold = epochs[n][1]["threshold"]
            if len(shares) >= threshold:
                key = shamir.combine(shares[:threshold])
                if sha256(key) == base64.b64decode(body["estateKeyCommitment"]):
                    ok("recovered Estate Key matches the commitment: " + key.hex())
                else:
                    bad("combined key does not match the commitment")
            else:
                bad("need %d shares, have %d good ones" % (threshold, len(shares)))

    return finish()


def finish():
    if failures:
        print("\n%d check(s) FAILED." % failures)
        return 1
    print("\nAll checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
