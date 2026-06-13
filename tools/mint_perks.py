#!/usr/bin/env python3
"""
mint_perks.py — offline minting of Seal founder-perk claim codes (SDS §10).

The founder private key NEVER leaves this machine. The app only ships the
public key (PerkAuthority.founderPublicKeyHex); clients verify every grant
signature before honoring a perk — the server is untrusted, as always.

Byte-compatibility contract with Seal/Identity/PerkAuthority.swift:
  normalize(code)  = uppercase, alphanumerics only
  codeHashHex      = SHA256(normalize(code)) lowercase hex
  grant message    = "seal.perk.grant.v1|<kind>|<number or '-'>|<codeHashHex>|<issuedAtUnix>"
  signature        = ECDSA P-256 / SHA-256, DER encoding
  grant JSON       = Swift Codable: {"kind", "number"?, "codeHashHex",
                     "issuedAtUnix", "signature": <base64>}

Usage:
  1. python3 mint_perks.py keygen
       → founder_private.pem (chmod 600) + the public-key hex to paste into
         PerkAuthority.founderPublicKeyHex. Do this ONCE; back up the PEM.
  2. python3 mint_perks.py mint --kind founder --numbers 1-10
     python3 mint_perks.py mint --kind campus-founder --count 25
       → mint_out/codes.txt            printable claim codes (box inserts)
         mint_out/records/*.json       cktool field files, one per grant
         mint_out/push.sh              cktool commands (dev env by default)
  3. Review push.sh, then run it (needs `xcrun cktool save-token` first).
       Verify the exact cktool subcommand/flags with `xcrun cktool --help`
       (they have shifted across Xcode versions); the CloudKit console's
       record editor is always a manual fallback: record type PerkGrant,
       record name from the filename, field `grant` = Bytes (base64 in file).

Requires: pip install cryptography
"""

import argparse
import base64
import hashlib
import json
import os
import secrets
import stat
import sys
import time

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

TEAM_ID = "8C4BM6A82T"
CONTAINER_ID = "iCloud.io.github.jasonepage.Seal"
FOUNDER_RANGE = range(1, 101)  # hard-capped in the client too (PerkAuthority)
KINDS = ("founder", "campus-founder")

# No 0/O/1/I/L/U — unambiguous when read off a printed card.
CODE_ALPHABET = "23456789ABCDEFGHJKMNPQRSTVWXYZ"


def normalize(code: str) -> str:
    return "".join(c for c in code.upper() if c.isalnum())


def code_hash_hex(code: str) -> str:
    return hashlib.sha256(normalize(code).encode()).hexdigest()


def new_code() -> str:
    groups = ["".join(secrets.choice(CODE_ALPHABET) for _ in range(5)) for _ in range(3)]
    return "SEAL-" + "-".join(groups)


def grant_message(kind: str, number, chash: str, issued: int) -> bytes:
    num = str(number) if number is not None else "-"
    return f"seal.perk.grant.v1|{kind}|{num}|{chash}|{issued}".encode()


def keygen(args):
    path = args.out
    if os.path.exists(path):
        sys.exit(f"refusing to overwrite {path}")
    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    with open(path, "wb") as f:
        f.write(pem)
    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)  # 600
    pub = key.public_key().public_bytes(
        serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint
    )
    print(f"founder private key → {path}  (back this up offline; it IS the perk system)")
    print("\nPaste into PerkAuthority.founderPublicKeyHex:\n")
    print(pub.hex())


def load_key(path: str) -> ec.EllipticCurvePrivateKey:
    with open(path, "rb") as f:
        key = serialization.load_pem_private_key(f.read(), password=None)
    if not isinstance(key, ec.EllipticCurvePrivateKey):
        sys.exit("not an EC private key")
    return key


def mint(args):
    key = load_key(args.key)
    pub = key.public_key()

    if args.kind == "founder":
        if not args.numbers:
            sys.exit("--kind founder requires --numbers (e.g. 1-10 or 3,7,9)")
        numbers = parse_numbers(args.numbers)
        bad = [n for n in numbers if n not in FOUNDER_RANGE]
        if bad:
            sys.exit(f"founder numbers outside 1-100 (client rejects them): {bad}")
        jobs = [("founder", n) for n in numbers]
    else:
        if not args.count:
            sys.exit("--kind campus-founder requires --count")
        jobs = [("campus-founder", None)] * args.count

    outdir = args.out
    recdir = os.path.join(outdir, "records")
    os.makedirs(recdir, exist_ok=True)
    issued = int(time.time())

    codes_lines, push_lines = [], [
        "#!/bin/sh",
        "# Push PerkGrant records. Run `xcrun cktool save-token` once first.",
        "# Verify subcommand/flags with `xcrun cktool --help` for your Xcode;",
        "# manual fallback: CloudKit console → PerkGrant → field grant (Bytes).",
        f"ENV=${{1:-development}}   # ./push.sh production for prod",
        "set -e",
    ]

    for kind, number in jobs:
        code = new_code()
        chash = code_hash_hex(code)
        msg = grant_message(kind, number, chash, issued)
        sig = key.sign(msg, ec.ECDSA(hashes.SHA256()))  # DER
        # Self-check: verify exactly what clients will verify.
        pub.verify(sig, msg, ec.ECDSA(hashes.SHA256()))

        grant = {"kind": kind, "codeHashHex": chash, "issuedAtUnix": issued,
                 "signature": base64.b64encode(sig).decode()}
        if number is not None:
            grant["number"] = number
        grant_b64 = base64.b64encode(
            json.dumps(grant, separators=(",", ":")).encode()).decode()

        record_name = f"perk.{chash}"
        fields_path = os.path.join(recdir, f"{record_name}.json")
        with open(fields_path, "w") as f:
            json.dump({"grant": {"type": "BYTES", "value": grant_b64}}, f, indent=2)

        label = f"Founder № {number}" if number is not None else "Campus founder"
        codes_lines.append(f"{label:<16} {code}")
        push_lines.append(
            "xcrun cktool create-record "
            f"--team-id {TEAM_ID} --container-id {CONTAINER_ID} "
            '--environment "$ENV" --database-type public --zone-name _defaultZone '
            f"--record-type PerkGrant --record-name {record_name} "
            f"--fields-file records/{record_name}.json"
        )

    codes_path = os.path.join(outdir, "codes.txt")
    with open(codes_path, "w") as f:
        f.write("\n".join(codes_lines) + "\n")
    os.chmod(codes_path, stat.S_IRUSR | stat.S_IWUSR)  # codes are bearer secrets
    push_path = os.path.join(outdir, "push.sh")
    with open(push_path, "w") as f:
        f.write("\n".join(push_lines) + "\n")
    os.chmod(push_path, 0o755)

    print(f"{len(jobs)} grant(s) minted → {outdir}/")
    print("codes.txt is the ONLY copy of the codes (records hold hashes only) — print, then store safely.")


def parse_numbers(spec: str):
    out = []
    for part in spec.split(","):
        if "-" in part:
            a, b = part.split("-")
            out.extend(range(int(a), int(b) + 1))
        else:
            out.append(int(part))
    return sorted(set(out))


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    k = sub.add_parser("keygen", help="generate the founder key (once)")
    k.add_argument("--out", default="founder_private.pem")
    k.set_defaults(fn=keygen)

    m = sub.add_parser("mint", help="mint claim codes + grant records")
    m.add_argument("--key", default="founder_private.pem")
    m.add_argument("--kind", choices=KINDS, required=True)
    m.add_argument("--numbers", help="founder numbers, e.g. 1-10 or 3,7,9")
    m.add_argument("--count", type=int, help="how many campus-founder codes")
    m.add_argument("--out", default="mint_out")
    m.set_defaults(fn=mint)

    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
