#!/usr/bin/env python3
"""Builds a synthetic but cryptographically real Seal capsule, for testing
tools/verify_capsule.py without a phone.

Every signature in the output is a genuine P-256 signature over the exact
bytes the Swift code signs (docs/CAPSULE.md), made with throwaway keys. The
WebAuthn assertions are shaped like a security key's output. Nothing here
is a real identity. Run:

    python3 tools/make_test_capsule.py > /tmp/test-capsule.json
    python3 tools/verify_capsule.py /tmp/test-capsule.json

Pass --tamper to flip one byte in a heartbeat signature and watch the
verifier catch it.
"""
import base64
import hashlib
import json
import os
import sys
import uuid

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import serialization

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import shamir_vectors as shamir

RP = "sealmessenger.com"


def sha256(b):
    return hashlib.sha256(b).digest()


def b64(b):
    return base64.b64encode(b).decode()


def b64url(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def framed(domain, fields):
    out = bytearray(domain.encode())
    for f in fields:
        out += len(f).to_bytes(4, "big") + f
    return bytes(out)


def raw64(pub):
    x = pub.public_numbers().x.to_bytes(32, "big")
    y = pub.public_numbers().y.to_bytes(32, "big")
    return x + y


def sign(priv, msg):
    return priv.sign(msg, ec.ECDSA(hashes.SHA256()))


class Person:
    def __init__(self, name):
        self.name = name
        self.root = ec.generate_private_key(ec.SECP256R1())
        self.device = ec.generate_private_key(ec.SECP256R1())
        self.cred_id = os.urandom(16)
        self.hash = sha256(self.cred_id).hex()
        self.kem = os.urandom(32)   # stands in for an X25519 public key
        self.device_x963 = b"\x04" + raw64(self.device.public_key())

    def assertion(self, challenge):
        auth = sha256(RP.encode()) + bytes([0x01]) + b"\x00\x00\x00\x01"
        client = json.dumps({"type": "webauthn.get", "challenge": b64url(challenge),
                             "origin": "https://" + RP}, sort_keys=True).encode()
        sig = sign(self.root, auth + sha256(client))
        return {"credentialID": b64(self.cred_id), "clientDataJSON": b64(client),
                "authenticatorData": b64(auth), "signature": b64(sig)}

    def capsule_identity(self):
        commitment = sha256(framed("seal.endorse.v3", [self.device_x963, self.kem]))
        a = self.assertion(commitment)
        return {
            "rootHash": self.hash,
            "publicKeyHex": raw64(self.root.public_key()).hex(),
            "displayName": self.name,
            "tier": "verified",
            "deviceEndorsements": [{
                "devicePublicKeyHex": self.device_x963.hex(),
                "kemBundleHex": self.kem.hex(),
                "createdAtEpoch": 1_800_000_000,
                "assertion": {
                    "credentialIDHex": self.cred_id.hex(),
                    "clientDataJSONBase64": a["clientDataJSON"],
                    "authenticatorDataHex": base64.b64decode(a["authenticatorData"]).hex(),
                    "signatureHex": base64.b64decode(a["signature"]).hex(),
                },
            }],
        }

    def event(self, estate, kind, prev, payload, at):
        eid = str(uuid.uuid4()).upper()
        digest = sha256(framed("seal.estate.event.v1", [
            eid.encode(), estate.encode(), kind.encode(), self.hash.encode(),
            self.device_x963, str(at).encode(), prev, payload]))
        return {
            "id": eid, "estateID": estate, "kind": kind, "actorHash": self.hash,
            "actorDevicePublicKeyHex": self.device_x963.hex(), "occurredAtEpoch": at,
            "previousDigestHex": prev.hex(), "payloadBase64": b64(payload),
            "signatureHex": sign(self.device, digest).hex(), "timestampTokenBase64": None,
            "digestHex": digest.hex(),
        }, digest


def body(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()


def main():
    tamper = "--tamper" in sys.argv
    owner = Person("Nathan")
    karen, dave, ruth = Person("Karen"), Person("Dave"), Person("Ruth Ellison")
    custodians = [karen, dave, ruth]
    estate = str(uuid.uuid4()).upper()
    day = 86400
    t0 = 1_800_000_000

    estate_key = os.urandom(32)
    import random
    rnd = random.Random(1)
    coeffs = [[rnd.randrange(256)] for _ in range(32)]
    shares = shamir.split(estate_key, 2, 3, coeffs)
    material = {
        "estateID": estate, "epoch": 1, "threshold": 2,
        "ownerWraps": [{"suite": "x25519+mlkem768", "ephemeralPublicKey": b64(os.urandom(32)),
                        "mlkemCiphertext": b64(os.urandom(1088)), "ciphertext": b64(os.urandom(60))}],
        "custodianShares": [{
            "custodianHash": c.hash, "shareIndex": i,
            "envelopes": [{"suite": "x25519+mlkem768", "ephemeralPublicKey": b64(os.urandom(32)),
                           "mlkemCiphertext": b64(os.urandom(1088)), "ciphertext": b64(os.urandom(61))}],
            "commitment": b64(sha256(bytes([i]) + s)),
        } for c, (i, s) in zip(custodians, shares)],
        "estateKeyCommitment": b64(sha256(estate_key)),
    }
    material_blob = body(material)

    events = []
    prev = b""
    policy = {"silenceDays": 90, "warningDays": 21, "graceDays": 14, "threshold": 2, "objectionBehavior": "pause"}
    e, prev = owner.event(estate, "estateCreated", prev, body({"policy": policy, "createdAtEpoch": t0}), t0); events.append(e)
    e, prev = owner.event(estate, "epochPublished", prev, body({
        "epoch": 1, "threshold": 2,
        "custodianHashes": [c.hash for c in custodians],
        "custodianPublicKeys": [b64(raw64(c.root.public_key())) for c in custodians],
        "shareCommitments": [s["commitment"] for s in material["custodianShares"]],
        "estateKeyCommitment": material["estateKeyCommitment"],
        "materialDigest": b64(sha256(material_blob)),
    }), t0 + 60); events.append(e)
    e, prev = owner.event(estate, "vaultUpdated", prev, body({"blobCommitment": b64(sha256(b"blobs")), "tableIDs": ["T1", "T2"]}), t0 + 120); events.append(e)
    for w in range(1, 4):
        e, prev = owner.event(estate, "heartbeat", prev, b"", t0 + w * 7 * day); events.append(e)
    claim_at = t0 + 21 * day + 100 * day
    claim_id = str(uuid.uuid4()).upper()
    e, prev = dave.event(estate, "silenceObserved", prev, body({"lastHeartbeatDigest": b64(prev), "lastHeartbeatAtEpoch": t0 + 21 * day}), claim_at - day); events.append(e)
    e, prev = dave.event(estate, "releaseClaimed", prev, body({"claimID": claim_id, "epoch": 1, "lastHeartbeatAtEpoch": t0 + 21 * day, "reason": "no word since spring"}), claim_at); events.append(e)
    open_at = claim_at + 35 * day
    for c, at in [(karen, open_at + 60), (ruth, open_at + day)]:
        head = prev
        challenge = sha256(framed("seal.release.authorize.v1", [estate.encode(), b"1", claim_id.encode(), head]))
        e, prev = c.event(estate, "authorization", prev, body({
            "claimID": claim_id, "epoch": 1, "recordHeadDigest": b64(head),
            "assertion": c.assertion(challenge),
            "shareForClaimant": [{"suite": "x25519+mlkem768", "ephemeralPublicKey": b64(os.urandom(32)),
                                  "mlkemCiphertext": b64(os.urandom(1088)), "ciphertext": b64(os.urandom(61))}],
        }), at); events.append(e)
    e, prev = dave.event(estate, "released", prev, body({"claimID": claim_id, "epoch": 1, "shareIndexes": [1, 2, 3], "estateKey": b64(estate_key)}), open_at + 2 * day); events.append(e)

    if tamper:
        sig = bytearray.fromhex(events[3]["signatureHex"])
        sig[-1] ^= 0x01
        events[3]["signatureHex"] = sig.hex()

    cap = {
        "format": "seal.capsule", "version": 1, "relyingPartyID": RP,
        "exportedAtEpoch": open_at + 3 * day, "exportedBy": dave.hash,
        "estateID": estate, "ownerHash": owner.hash,
        "identities": {p.hash: p.capsule_identity() for p in [owner] + custodians},
        "events": events,
        "epochBlobsBase64": {"1": b64(material_blob)},
        "tableBlobsBase64": {"T1": b64(b"{}"), "T2": b64(b"{}")},
        "contentBlobsBase64": {},
        "stateAtExport": "released",
    }
    print(json.dumps(cap, indent=1, sort_keys=True))
    # Shares, for exercising --combine.
    print("\n".join("SHARE %02x%s" % (i, s.hex()) for i, s in shares), file=sys.stderr)


if __name__ == "__main__":
    main()
