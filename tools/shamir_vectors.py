#!/usr/bin/env python3
"""Independent reference implementation of Shamir secret sharing over GF(256).

Field: GF(2^8) with reducing polynomial 0x11B (the AES field). Share layout:
one byte index (1..255) followed by the evaluated bytes. This file exists to
generate the vectors in Seal/SelfTest/ShamirTests.swift and is imported by
tools/verify_capsule.py, so the Swift and the verifier are checked against
the same second implementation. Standard library only.

Run it to print the vectors as JSON.
"""
import hashlib
import json
import random


def gf_mul(a, b):
    r = 0
    while b:
        if b & 1:
            r ^= a
        a <<= 1
        if a & 0x100:
            a ^= 0x11B
        b >>= 1
    return r


def gf_pow(a, n):
    r = 1
    for _ in range(n):
        r = gf_mul(r, a)
    return r


def gf_inv(a):
    assert a != 0
    return gf_pow(a, 254)


def eval_poly(coeffs, x):
    """coeffs[0] is the constant term."""
    r = 0
    for c in reversed(coeffs):
        r = gf_mul(r, x) ^ c
    return r


def split(secret, m, n, coeff_bytes):
    """coeff_bytes[j] holds the m-1 non-constant coefficients for byte j."""
    shares = []
    for i in range(1, n + 1):
        out = bytearray()
        for j, s in enumerate(secret):
            out.append(eval_poly([s] + list(coeff_bytes[j]), i))
        shares.append((i, bytes(out)))
    return shares


def combine(shares):
    """Lagrange interpolation at x = 0 over exactly the shares given."""
    length = len(shares[0][1])
    out = bytearray()
    for j in range(length):
        acc = 0
        for i, (xi, yi) in enumerate(shares):
            num = 1
            den = 1
            for k, (xk, _) in enumerate(shares):
                if k == i:
                    continue
                num = gf_mul(num, xk)
                den = gf_mul(den, xi ^ xk)
            acc ^= gf_mul(yi[j], gf_mul(num, gf_inv(den)))
        out.append(acc)
    return bytes(out)


def share_commitment(index, body):
    return hashlib.sha256(bytes([index]) + body).hexdigest()


def main():
    secret = bytes(range(32))
    rnd = random.Random(7)
    coeffs = [[rnd.randrange(256) for _ in range(2)] for _ in range(32)]
    sh = split(secret, 3, 5, coeffs)
    assert combine(sh[:3]) == secret
    assert combine([sh[0], sh[2], sh[4]]) == secret
    assert combine(sh[1:3]) != secret
    assert gf_mul(0x53, 0xCA) == 1
    vec = {
        "mul": [[a, b, gf_mul(a, b)] for a, b in
                [(0x53, 0xCA), (0x02, 0x80), (0xFF, 0xFF), (0x01, 0x7B), (0x00, 0x9C), (0x1B, 0x1B)]],
        "inv": [[a, gf_inv(a)] for a in [1, 2, 3, 0x53, 0xFF, 0x80]],
        "secretHex": secret.hex(),
        "threshold": 3,
        "shares": 5,
        "coefficientsHex": ["".join("%02x" % c for c in cs) for cs in coeffs],
        "sharesHex": ["%02x" % x + y.hex() for x, y in sh],
        "shareCommitments": [share_commitment(x, y) for x, y in sh],
        "secretCommitment": hashlib.sha256(secret).hexdigest(),
    }
    secret2 = hashlib.sha256(b"seal").digest()
    coeffs2 = [[rnd.randrange(256)] for _ in range(32)]
    sh2 = split(secret2, 2, 3, coeffs2)
    assert combine(sh2[1:]) == secret2
    vec["v2"] = {
        "secretHex": secret2.hex(), "threshold": 2, "shares": 3,
        "coefficientsHex": ["".join("%02x" % c for c in cs) for cs in coeffs2],
        "sharesHex": ["%02x" % x + y.hex() for x, y in sh2],
    }
    print(json.dumps(vec, indent=1))


if __name__ == "__main__":
    main()
