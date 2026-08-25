#!/usr/bin/env python3
"""
introduction_vectors.py — byte-layout contract + test vectors for
`seal.introduce.v1` (docs/INTRODUCTIONS.md, Seal/Introductions/Introduction.swift).

Same discipline as mint_perks.py: a second, independent implementation of a
signed message format, so the layout is stated somewhere other than the Swift
that produces it and the two can be compared byte for byte.

Contract with Introduction.swift:

  field(x)     = uint32be(len(x)) || x
  commitment   = SHA256( b"seal.introduce.v1"
                         || field(introducerRootHash utf8)
                         || field(partyARootHash utf8)
                         || field(partyAPublicKey)
                         || field(partyBRootHash utf8)
                         || field(partyBPublicKey)
                         || field(decimal(createdAtEpoch) utf8) )
  acceptance   = SHA256( b"seal.introduce.accept.v1"
                         || field(introductionCommitment)
                         || field(accepterRootHash utf8)
                         || field(decimal(acceptedAtEpoch) utf8) )

  Parties are in CANONICAL ORDER: partyARootHash <= partyBRootHash as ASCII.
  The domain prefix is inside the hash and is NOT length-framed (it is a fixed
  constant, exactly like seal.receipt.v1 / seal.endorse.v3).

Run:  python3 tools/introduction_vectors.py
"""

import hashlib
import struct

DOMAIN = b"seal.introduce.v1"
ACCEPT_DOMAIN = b"seal.introduce.accept.v1"


def field(data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + data


def commitment(introducer_hash, a_hash, a_key, b_hash, b_key, created_at_epoch):
    if a_hash > b_hash:                      # canonical order
        a_hash, a_key, b_hash, b_key = b_hash, b_key, a_hash, a_key
    body = (DOMAIN
            + field(introducer_hash.encode())
            + field(a_hash.encode())
            + field(a_key)
            + field(b_hash.encode())
            + field(b_key)
            + field(str(created_at_epoch).encode()))
    return hashlib.sha256(body).digest(), body


def acceptance_commitment(intro_commitment, accepter_hash, accepted_at_epoch):
    body = (ACCEPT_DOMAIN
            + field(intro_commitment)
            + field(accepter_hash.encode())
            + field(str(accepted_at_epoch).encode()))
    return hashlib.sha256(body).digest()


def unframed(introducer_hash, a_hash, a_key, b_hash, b_key, created_at_epoch):
    """What the commitment would be WITHOUT length framing — the seal.endorse.v2
    defect, reproduced here only to show why the framing is load-bearing."""
    return hashlib.sha256(DOMAIN
                          + introducer_hash.encode()
                          + a_hash.encode() + a_key
                          + b_hash.encode() + b_key
                          + str(created_at_epoch).encode()).digest()


# --- deterministic sample identities (NOT real keys) -------------------------

def sample_hash(name):
    return hashlib.sha256(("seal.vector.id." + name).encode()).hexdigest()


def sample_key(name):
    return (hashlib.sha256(("seal.vector.pub.a." + name).encode()).digest()
            + hashlib.sha256(("seal.vector.pub.b." + name).encode()).digest())


MOM = "Mom"
NATHAN = "Nathan"
LINDA = "Linda"
STAMP = 1_756_000_000          # fixed, so the vector is reproducible


def main():
    intro = sample_hash(MOM)
    a, ak = sample_hash(NATHAN), sample_key(NATHAN)
    b, bk = sample_hash(LINDA), sample_key(LINDA)

    digest, body = commitment(intro, a, ak, b, bk, STAMP)
    print("TEST VECTOR — seal.introduce.v1")
    print("  introducer  :", intro)
    print("  party A     :", min(a, b))
    print("  party B     :", max(a, b))
    print("  createdAt   :", STAMP)
    print("  preimage len:", len(body), "bytes")
    print("  preimage    :", body[:40].hex(), "…")
    print("  COMMITMENT  :", digest.hex())
    accept = acceptance_commitment(digest, a, STAMP + 60)
    print("  ACCEPT(A)   :", accept.hex())
    print()

    # 1. Canonical ordering: argument order must not matter.
    swapped, _ = commitment(intro, b, bk, a, ak, STAMP)
    print("[1] party order is canonical            :", "PASS" if swapped == digest else "FAIL")

    # 2. Replay to a different party: change one key, get a different statement.
    other, _ = commitment(intro, a, sample_key("Impostor"), b, bk, STAMP)
    print("[2] a swapped identity key changes it   :", "PASS" if other != digest else "FAIL")

    # 3. Different introducer, same pair → different statement.
    other, _ = commitment(sample_hash("Dad"), a, ak, b, bk, STAMP)
    print("[3] a different introducer changes it   :", "PASS" if other != digest else "FAIL")

    # 4. Timestamp is bound.
    other, _ = commitment(intro, a, ak, b, bk, STAMP + 1)
    print("[4] the timestamp is bound              :", "PASS" if other != digest else "FAIL")

    # 5. THE FRAMING PROPERTY, demonstrated on ADJACENT fields. Take the last
    #    byte of party A's root hash and give it to the front of party A's
    #    public key. The concatenation is unchanged, so an UNFRAMED commitment
    #    is byte-identical — one introducer signature would then speak for a
    #    pairing naming a hash and a key that were never the ones signed.
    #    seal.endorse.v2 shipped exactly this defect (IdentityManager
    #    documents what it cost); with framing the lengths move and the
    #    commitment changes.
    a_sorted, a_key_sorted = (a, ak) if a <= b else (b, bk)
    b_sorted, b_key_sorted = (b, bk) if a <= b else (a, ak)
    shifted_hash = a_sorted[:-1]
    shifted_key = a_sorted[-1:].encode() + a_key_sorted

    plain_original = unframed(intro, a_sorted, a_key_sorted, b_sorted, b_key_sorted, STAMP)
    plain_shifted = unframed(intro, shifted_hash, shifted_key, b_sorted, b_key_sorted, STAMP)
    print("[5] unframed: a moved field boundary COLLIDES :",
          "CONFIRMED (this is the defect framing removes)"
          if plain_shifted == plain_original else "not reproduced")

    framed_original = hashlib.sha256(
        DOMAIN + field(intro.encode()) + field(a_sorted.encode()) + field(a_key_sorted)
        + field(b_sorted.encode()) + field(b_key_sorted) + field(str(STAMP).encode())).digest()
    framed_shifted = hashlib.sha256(
        DOMAIN + field(intro.encode()) + field(shifted_hash.encode()) + field(shifted_key)
        + field(b_sorted.encode()) + field(b_key_sorted) + field(str(STAMP).encode())).digest()
    print("    framed  : the same shift changes it       :",
          "PASS" if framed_shifted != framed_original else "FAIL")
    print("    framed original == test vector            :",
          "PASS" if framed_original == digest else "FAIL")

    # 6. Acceptance is bound to one introduction and one accepter.
    other_intro, _ = commitment(intro, a, ak, b, bk, STAMP + 5)
    print("[6] acceptance is bound to its intro    :",
          "PASS" if acceptance_commitment(other_intro, a, STAMP + 60) != accept else "FAIL")
    print("[7] acceptance is bound to its accepter :",
          "PASS" if acceptance_commitment(digest, b, STAMP + 60) != accept else "FAIL")


if __name__ == "__main__":
    main()
