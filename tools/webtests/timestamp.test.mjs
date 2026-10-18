// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  timestamp.test.mjs
//
//  Tests for site/open/js/timestamp.js, the port of TimestampVerifier.
//  Run from the repo root: node tools/webtests/timestamp.test.mjs
//
//  Part 1 ports every case in Seal/SelfTest/TimestampVerifierTests.swift
//  and FreeTSATests.swift, with the same tokens and the same expected
//  answers. Part 2 adds tokens OpenSSL 3.0 made for curves and shapes the
//  Swift tests do not cover. Part 3 flips a byte in each region of a real
//  token. Part 4 builds tokens field by field and signs them here, to pin
//  down each structural rule; their expected answers come from reading the
//  Swift line by line (named in each case), since there is no Swift
//  compiler here to run them against.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { utf8, toHex, fromHex, fromB64, concat, same, sha256, sha384, subtle } from "../../site/open/js/bytes.js";
import {
  verifiedGenTime, verifiedGenTimeWithPins, generalizedTime,
  pinnedCertificates, maxTokenBytes, DERReader, OID,
} from "../../site/open/js/timestamp.js";
import { effectiveTime } from "../../site/open/js/release.js";

let checks = 0;
let failures = 0;
function check(ok, label, detail = "") {
  checks++;
  if (!ok) {
    failures++;
    console.log(`FAIL ${label}${detail ? ` (${detail})` : ""}`);
  }
}
const equal = (got, want, label) => check(got === want, label, `got ${got}, want ${want}`);

const b64 = (s) => fromB64(s.replace(/\s+/g, ""));
const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

// ================================================================ fixtures from the Swift tests

const digest = await sha256(utf8("seal-test-event"));

/** TimestampVerifierTests.testPin: SHA-256 of CN=Seal Test TSA. */
const testPin = [Uint8Array.of(
  0xa1, 0x2c, 0xc1, 0xec, 0xfb, 0x98, 0x05, 0xd4, 0xfd, 0xd9, 0xd0, 0x1e, 0x04, 0xdf, 0x66, 0x28,
  0xd7, 0xbc, 0xf9, 0xab, 0xad, 0x1a, 0x3e, 0x53, 0x56, 0x1e, 0xb4, 0xd3, 0x1c, 0xac, 0xf3, 0x65)];

/** genTime of both good tokens: 2026-10-02 21:49:52 UTC. */
const stampedAt = 1_790_977_792;

/** Signed with ecdsa-with-SHA384, signer digest SHA-384. */
const p384SHA384 = b64(`
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`);

/** Same authority, ecdsa-with-SHA256, signer digest SHA-256. */
const p384SHA256 = b64(`
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
xytEUHLLelrIh1m67KGMjQKUrPA=`);

/** A forgery: the pinned certificate rides along, but CN=Not The TSA signed it. */
const otherSigner = b64(`
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`);

/** FreeTSATests: the token freetsa.org/tsr returned on 2026-10-03. */
const freeTSADigest = await sha256(utf8("seal-freetsa-check"));
const freeTSAStampedAt = 1_790_995_879;   // 2026-10-03 02:51:19 UTC
const freeTSA = b64(`
MIISFTADAgEAMIISDAYJKoZIhvcNAQcCoIIR/TCCEfkCAQMxDzANBglghkgBZQMEAgMFADCCAYYGCyqGSIb3DQEJEAEEoIIBdQSC
AXEwggFtAgEBBgQqAwQBMDEwDQYJYIZIAWUDBAIBBQAEIBLatFGOE2EQ8nGuVAl+0qpvQxSaRQbvhS3NSmmS+esCAgQI0IYoGA8y
MDI2MTAwMzAyNTExOVoBAf+gggETpIIBDzCCAQsxETAPBgNVBAoMCEZyZWUgVFNBMQwwCgYDVQQLDANUU0ExdjB0BgNVBA0MbVRo
aXMgY2VydGlmaWNhdGUgZGlnaXRhbGx5IHNpZ25zIGRvY3VtZW50cyBhbmQgdGltZSBzdGFtcCByZXF1ZXN0cyBtYWRlIHVzaW5n
IHRoZSBmcmVldHNhLm9yZyBvbmxpbmUgc2VydmljZXMxGDAWBgNVBAMMD3d3dy5mcmVldHNhLm9yZzEkMCIGCSqGSIb3DQEJARYV
YnVzaWxlemFzQG1haWxib3gub3JnMRIwEAYDVQQHDAlXdWVyemJ1cmcxCzAJBgNVBAYTAkRFMQ8wDQYDVQQIDAZCYXllcm6ggg5n
MIIGYDCCBEigAwIBAgIJAMLphhYNqOnNMA0GCSqGSIb3DQEBDQUAMIGVMREwDwYDVQQKEwhGcmVlIFRTQTEQMA4GA1UECxMHUm9v
dCBDQTEYMBYGA1UEAxMPd3d3LmZyZWV0c2Eub3JnMSIwIAYJKoZIhvcNAQkBFhNidXNpbGV6YXNAZ21haWwuY29tMRIwEAYDVQQH
EwlXdWVyemJ1cmcxDzANBgNVBAgTBkJheWVybjELMAkGA1UEBhMCREUwHhcNMjYwMjE1MTk0NDIyWhcNNDAwMjAyMTk0NDIyWjCC
AQsxETAPBgNVBAoMCEZyZWUgVFNBMQwwCgYDVQQLDANUU0ExdjB0BgNVBA0MbVRoaXMgY2VydGlmaWNhdGUgZGlnaXRhbGx5IHNp
Z25zIGRvY3VtZW50cyBhbmQgdGltZSBzdGFtcCByZXF1ZXN0cyBtYWRlIHVzaW5nIHRoZSBmcmVldHNhLm9yZyBvbmxpbmUgc2Vy
dmljZXMxGDAWBgNVBAMMD3d3dy5mcmVldHNhLm9yZzEkMCIGCSqGSIb3DQEJARYVYnVzaWxlemFzQG1haWxib3gub3JnMRIwEAYD
VQQHDAlXdWVyemJ1cmcxCzAJBgNVBAYTAkRFMQ8wDQYDVQQIDAZCYXllcm4wdjAQBgcqhkjOPQIBBgUrgQQAIgNiAASiFeGhstbL
hxix0o4UAumNSwHUUlOe3DBvs8fYs580wADW59oqGSCx15bp61TSmXkwLm1JW48XnbLLizP6ZtjcvshV3H9uz2bS53sgDXhg1wLb
IhAtraC+fHCytHeuVaujggHmMIIB4jAJBgNVHRMEAjAAMB0GA1UdDgQWBBQVwL0m69RdgtFdkyYxL+9wsotGXjAfBgNVHSMEGDAW
gBT6VQ2MNGZRQ0z357OnbJWveuaklzALBgNVHQ8EBAMCBsAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwbAYIKwYBBQUHAQEEYDBe
MDMGCCsGAQUFBzAChidodHRwOi8vd3d3LmZyZWV0c2Eub3JnL2ZpbGVzL2NhY2VydC5wZW0wJwYIKwYBBQUHMAGGG2h0dHA6Ly93
d3cuZnJlZXRzYS5vcmc6MjU2MDA3BgNVHR8EMDAuMCygKqAohiZodHRwOi8vd3d3LmZyZWV0c2Eub3JnL2NybC9yb290X2NhLmNy
bDCByAYDVR0gBIHAMIG9MIG6BgMrBQgwgbIwMwYIKwYBBQUHAgEWJ2h0dHA6Ly93d3cuZnJlZXRzYS5vcmcvZnJlZXRzYV9jcHMu
aHRtbDAyBggrBgEFBQcCARYmaHR0cDovL3d3dy5mcmVldHNhLm9yZy9mcmVldHNhX2Nwcy5wZGYwRwYIKwYBBQUHAgIwOxo5RnJl
ZVRTQSB0cnVzdGVkIHRpbWVzdGFtcGluZyBTb2Z0d2FyZSBhcyBhIFNlcnZpY2UgKFNhYVMpMA0GCSqGSIb3DQEBDQUAA4ICAQBr
MVS/YfnfMr0ziZnesBUOrDNRrNNgt3IgMNDwNhwl6oKWHVIhlYnM/5boljfbpZTAbqvxHI3ztT0/swxQOqTat5qBJRAY/VH1n/T4
M9uDjSuu3qfh0ZH5PL9ENqoVW44i5NT/znQev2MGXOAHwz9kZwwzz9MFX6hbGhBqWa+nlAqb7Y72KFzj33m1OVHxV2Wl4YD9f91b
ZTFpUEGW4Ktbkmxpf/iGIPaf4WHpoBW/O6EzofMKYlz4yXyEBh0wRRVyXltLrj+MFHqhe+PsMBllq/dCaO4W/F+AuHElu7aUYWMA
SelphWAJiUsNMr5HAoeCSSgilqf1CSoWC+k6e4334Fym+Iy4csMex+PG4rSdqXJVQ+AWEdRajSPKh7yDfpNkdnO6yqQJ/tSd11XQ
5cL0M9jWuCD1zHlgA+u+R2cry3yo23jD7qTGLhZqUvXCyWigH30/Q/RXjjDwrc4DJiQ+gRY0FhdTYqlvgMBPr4LcJKnNksivdj+k
bz7bVSbrBAzRiazK9l841/5XMtP9BvD0hKCpQFvP9PSgCC8EQnKqgSe26FSJBaAQcA5TnK8NF4jkbElBxf/zyh7P3IjHso35jtgU
WD1/itg9BJWbYUwJ4tfILpB2F0wbk1GcZDCDZoyW3Xf3trApz/Zd93gF3joc9Hh9RFveKRzWQ7ddUt3egTCCB/8wggXnoAMCAQIC
CQDB6YYWDajpgDANBgkqhkiG9w0BAQ0FADCBlTERMA8GA1UEChMIRnJlZSBUU0ExEDAOBgNVBAsTB1Jvb3QgQ0ExGDAWBgNVBAMT
D3d3dy5mcmVldHNhLm9yZzEiMCAGCSqGSIb3DQEJARYTYnVzaWxlemFzQGdtYWlsLmNvbTESMBAGA1UEBxMJV3VlcnpidXJnMQ8w
DQYDVQQIEwZCYXllcm4xCzAJBgNVBAYTAkRFMB4XDTE2MDMxMzAxNTIxM1oXDTQxMDMwNzAxNTIxM1owgZUxETAPBgNVBAoTCEZy
ZWUgVFNBMRAwDgYDVQQLEwdSb290IENBMRgwFgYDVQQDEw93d3cuZnJlZXRzYS5vcmcxIjAgBgkqhkiG9w0BCQEWE2J1c2lsZXph
c0BnbWFpbC5jb20xEjAQBgNVBAcTCVd1ZXJ6YnVyZzEPMA0GA1UECBMGQmF5ZXJuMQswCQYDVQQGEwJERTCCAiIwDQYJKoZIhvcN
AQEBBQADggIPADCCAgoCggIBALYCjg4wMvERENlkzalLnQJ44ZQq6ROqpZkHzaaXk5lb2ax+M7rZ/jcE2hwBqY0hr+P1kaWdcGdw
UWeZj1AWci4KtGKyH0ORcdLPzEWT83Na95SlqzEfbAEMeJjeM9dcRRDudvS9HRSYzxfTA/BqXdn3lsxsqbZXpW/j6k/vvnzmtqGN
PjWjDO5f8XDRzzmjM9P9qJZNIttoWynlYb6JDwqoRYc7LoSrJquDn/6PrenSO7MeYdJzzJuIBkkYX6vs+gU0YAq6kBthTi6FRYLe
oiJvwZzX31K+1Q2Hd82ZiMBTo/x9wyh6BopP8StxPNmANmbpVThUVv84+AKYz2uThW6SJHdKZs8c3RHC+O/YUgPXRYslZksT7WOc
3tT/gRPWzFNT0nKUc8PDBxV8ciqltd0L+y1sOLG5N0nIgexgAm0IlRs4JL1xusvORzrr1jbwuRi0osj/RpTwdFevLW8c+CVU0XcP
15/10xTc0QTN3KvJQTgFbfzwF+frhXL9UvcBRPGI2gX1gj9Y3QYpfnOHvtLXcsE9qCZmAQRf5BLdcJhsDJh7pzRLkDc4dRbSWOeI
W1H4lot/JgEhO8TLTIX4/wuEr2qYgzfN+4GGj37PMdymcW1+wt2ALBZyYp5cAFLLNX3Smq/EP2FbOx/51OHOCMccc+H+u33FajNi
Eynp7WwjAgMBAAGjggJOMIICSjAMBgNVHRMEBTADAQH/MA4GA1UdDwEB/wQEAwIBxjAdBgNVHQ4EFgQU+lUNjDRmUUNM9+ezp2yV
r3rmpJcwgcoGA1UdIwSBwjCBv4AU+lUNjDRmUUNM9+ezp2yVr3rmpJehgZukgZgwgZUxETAPBgNVBAoTCEZyZWUgVFNBMRAwDgYD
VQQLEwdSb290IENBMRgwFgYDVQQDEw93d3cuZnJlZXRzYS5vcmcxIjAgBgkqhkiG9w0BCQEWE2J1c2lsZXphc0BnbWFpbC5jb20x
EjAQBgNVBAcTCVd1ZXJ6YnVyZzEPMA0GA1UECBMGQmF5ZXJuMQswCQYDVQQGEwJERYIJAMHphhYNqOmAMDMGA1UdHwQsMCowKKAm
oCSGImh0dHA6Ly93d3cuZnJlZXRzYS5vcmcvcm9vdF9jYS5jcmwwgc8GA1UdIASBxzCBxDCBwQYKKwYBBAGB8iQBATCBsjAzBggr
BgEFBQcCARYnaHR0cDovL3d3dy5mcmVldHNhLm9yZy9mcmVldHNhX2Nwcy5odG1sMDIGCCsGAQUFBwIBFiZodHRwOi8vd3d3LmZy
ZWV0c2Eub3JnL2ZyZWV0c2FfY3BzLnBkZjBHBggrBgEFBQcCAjA7GjlGcmVlVFNBIHRydXN0ZWQgdGltZXN0YW1waW5nIFNvZnR3
YXJlIGFzIGEgU2VydmljZSAoU2FhUykwNwYIKwYBBQUHAQEEKzApMCcGCCsGAQUFBzABhhtodHRwOi8vd3d3LmZyZWV0c2Eub3Jn
OjI1NjAwDQYJKoZIhvcNAQENBQADggIBAGivfr+ThWLvTOs7WAvi+vbMNaJncpYvPZWQH6VjDIfQkZiYTOigajP4qcKC7Z8csRrG
wj4XEI7k785vspTelcEzJiJVclUiymGXHUo7f3glDfuNSu7A+xlZsWQQBSC5wQ5kxiZi5K1NCrriKY/JSPxOmejZ5rj9vkQEEh7H
wUIurLLJ1zKOBzluYLTzu4A61KVVyA/vtT+F53ZKCp+0r8OZ9M0vX79YcQXGCBzz0FM3trt9GwELdJ9IiMkS82lrobaQLXe338BG
wEoMwexPjRheLaVd+3vCogNsYhkkak+Z3btvH4KTmPO4A9wK2Q3LWb70wnx3QEuZBDt4JxhnmRFSw5nxLL/ExiWtwJY1WuRONCEA
7FF6UC4vBvlAuNQ1mbvBFU+K52GgsNVV+0oTkdTzQgr42/EvLX3bnXfc4VN4BAdK8XXk8tbVWzS11vfcvdMXMK9WSA1MDP8UP56D
vBUYZtC6Dwu9xH/ieGQXa71sGrhd8yXt93eIm8RHG/P6c+VsxZHosWDNp7B4ah7ASsOyT6LijV0Z5eSABNXhZqg8guxv1U+zheuv
cTOoW1LeRttSROHDSujTbnEvn84NST19Pt1YbGGY4+w+bpY0b0F6yfIh4K/zOo9qCx70wCNjC3atqo2RQzgl7MQcSaW5ixgcfaMO
mXq5VMc8LNgFr9qZMYIB7DCCAegCAQEwgaMwgZUxETAPBgNVBAoTCEZyZWUgVFNBMRAwDgYDVQQLEwdSb290IENBMRgwFgYDVQQD
Ew93d3cuZnJlZXRzYS5vcmcxIjAgBgkqhkiG9w0BCQEWE2J1c2lsZXphc0BnbWFpbC5jb20xEjAQBgNVBAcTCVd1ZXJ6YnVyZzEP
MA0GA1UECBMGQmF5ZXJuMQswCQYDVQQGEwJERQIJAMLphhYNqOnNMA0GCWCGSAFlAwQCAwUAoIG4MBoGCSqGSIb3DQEJAzENBgsq
hkiG9w0BCRABBDAcBgkqhkiG9w0BCQUxDxcNMjYxMDAzMDI1MTE5WjArBgsqhkiG9w0BCRACDDEcMBowGDAWBBRIH9U8U004QYDA
KGUZoDb5iFRHZjBPBgkqhkiG9w0BCQQxQgRATPme/qlPRyEB4xlfL6jKoTjrVUfliVLw7c/s3K62ZYkBT5swYM9eOqpPLViqMFyR
iJX6qQ/zDKuO2hTp7UcaYTAKBggqhkjOPQQDBARnMGUCMGD7F4x3/oISLhB11axRNxBdzaty79BPXs+l2KP9eq1kCospdqgUVLSu
V6CT8ltc2AIxAOHk47S9M/PtCCHMncdIxZZlOt8Yo/tVRBPOWWDZi28kPwvLIwk0uGDipl3b5P+DgQ==`);

const nines = new Uint8Array(32).fill(9);

// ================================================================ part 0: the port's constants match the Swift

{
  const swift = readFileSync(join(repoRoot, "Seal/Record/TimestampVerifier.swift"), "utf8");
  const block = swift.match(/pinnedCertificates: Set<Data> = \[([\s\S]*?)\n\s*\]/);
  const swiftPins = block
    ? [...block[1].matchAll(/Data\(\[([^\]]*)\]\)/g)].map((m) => toHex(Uint8Array.from(m[1].match(/0x[0-9a-fA-F]{2}/g), (h) => parseInt(h, 16))))
    : [];
  check(swiftPins.length > 0, "the Swift pin set is found");
  check(swiftPins.length === pinnedCertificates.length && swiftPins.every((p, i) => p === pinnedCertificates[i]),
    "the pinned certificates are byte for byte the Swift's", `${pinnedCertificates} vs ${swiftPins}`);
  const cap = swift.match(/static let maxTokenBytes = 64 \* 1024/);
  check(!!cap && maxTokenBytes === 65536, "maxTokenBytes matches the Swift");
}

// ================================================================ part 1: TimestampVerifierTests.swift and FreeTSATests.swift

// timestamp.verify
equal(await verifiedGenTimeWithPins(p384SHA384, digest, testPin), stampedAt,
  "a real token signed with ecdsa-with-SHA384 gives the authority's time");
equal(await verifiedGenTimeWithPins(p384SHA256, digest, testPin), stampedAt,
  "and one signed with ecdsa-with-SHA256");
equal(await verifiedGenTimeWithPins(p384SHA384, nines, testPin), null,
  "a token for another event gives nothing");
equal(await verifiedGenTime(p384SHA384, digest), null,
  "a token from an authority that is not pinned gives nothing (the app pins FreeTSA only)");
equal(await verifiedGenTimeWithPins(p384SHA384, digest, []), null, "no pins, no time");

// timestamp.hostile
equal(await verifiedGenTimeWithPins(otherSigner, digest, testPin), null,
  "carrying the pinned certificate is not enough: the pinned key must have signed it");
{
  const time = utf8("20260915120000Z");
  const scanBait = concat(Uint8Array.of(0x30, 0x10, 0x04, 0x20), digest, Uint8Array.of(0x02, 0x01, 0x07),
    Uint8Array.of(0x18, time.length), time);
  equal(await verifiedGenTimeWithPins(scanBait, digest, testPin), null, "a hand-built digest-then-date token is refused");
}
{
  let truncationsAccepted = 0;
  for (let n = 0; n < p384SHA384.length; n++) {
    if ((await verifiedGenTimeWithPins(p384SHA384.subarray(0, n), digest, testPin)) !== null) truncationsAccepted++;
  }
  equal(truncationsAccepted, 0, "no truncated token verifies");
}
{
  let wrongTimes = 0;
  for (let i = 0; i < p384SHA384.length; i += 5) {
    for (const mask of [0x01, 0xff]) {
      const bent = new Uint8Array(p384SHA384);
      bent[i] ^= mask;
      const got = await verifiedGenTimeWithPins(bent, digest, testPin);
      if (got !== null && got !== stampedAt) wrongTimes++;
    }
  }
  equal(wrongTimes, 0, "no single changed byte yields a different time");
}
{
  const liars = [
    new Uint8Array(0), Uint8Array.of(0x30), Uint8Array.of(0x30, 0x80, 0x00, 0x00),
    Uint8Array.of(0x30, 0x84, 0xff, 0xff, 0xff, 0xff), Uint8Array.of(0x30, 0x85, 1, 2, 3, 4, 5),
    new Uint8Array(4096).fill(0x30), Uint8Array.of(0x1f, 0x01, 0x00),
    new Uint8Array(maxTokenBytes + 1),
  ];
  for (const liar of liars) {
    let got;
    try { got = await verifiedGenTimeWithPins(liar, digest, testPin); } catch (e) { got = `threw ${e}`; }
    equal(got, null, `malformed DER is refused, not trusted and not a crash [${Array.from(liar.subarray(0, 8))}]`);
  }
}

// timestamp.generalizedTime
{
  const g = (s) => generalizedTime(utf8(s));
  equal(g("20261002214952Z"), stampedAt, "plain seconds");
  equal(g("20261002214952.123Z"), stampedAt, "a fraction is allowed and ignored");
  equal(g("20261302214952Z"), null, "month 13 is refused");
  equal(g("20260230120000Z"), null, "February 30 is refused");
  equal(g("2026100221495Z"), null, "too short is refused");
  equal(g("20261002214952"), null, "no Z is refused");
  equal(g("20261002214952.Z"), null, "an empty fraction is refused");
  equal(g("2026100221495xZ"), null, "a letter is refused");
}

// timestamp.feed (ReleaseFeed.effectiveTime, ported in release.js)
{
  const e = { digest: await sha256(utf8("a heartbeat")), occurredAt: 1_790_000_000 };
  const time = utf8("20200101000000Z");
  e.timestampToken = concat(Uint8Array.of(0x04, 0x20), e.digest, Uint8Array.of(0x02, 0x01, 0x07),
    Uint8Array.of(0x18, time.length), time);
  equal(await effectiveTime(e), e.occurredAt, "a forged token does not move an event in time");
  e.timestampToken = p384SHA384;
  equal(await effectiveTime(e), e.occurredAt, "nor does a real token for some other event");
}

// timestamp.realFreeTSA (the production path: default pins)
equal(await verifiedGenTime(freeTSA, freeTSADigest), freeTSAStampedAt,
  "a real FreeTSA token verifies under the app's own pin (P-384, SHA-512)");
equal(await verifiedGenTime(freeTSA, nines), null, "and gives nothing for another event");

// ================================================================ part 2: more OpenSSL tokens (same request shape)

// Made with `openssl ts -reply` (OpenSSL 3.0.13) from throwaway authorities,
// for SHA-256("seal-test-event"), and checked with `openssl ts -verify`.
// genTime 2026-10-18 03:12:33 UTC; the third has ".316" as a fraction.
const stampedAt2 = Date.UTC(2026, 9, 18, 3, 12, 33) / 1000;
const generated = [
  {
    name: "a P-256 key, ecdsa-with-SHA256, signer digest SHA-256",
    pin: "e6b98e97536ebe8d706fd6691f69f991d17e1e6cca1b44a791c23370c63a9219",
    token: b64(`
MIIDgTADAgEAMIIDeAYJKoZIhvcNAQcCoIIDaTCCA2UCAQMxDzANBglghkgBZQMEAgEFADByBgsqhkiG9w0BCRABBKBjBGEwXwIB
AQYEKgMEATAxMA0GCWCGSAFlAwQCAQUABCDnoNnkEA9ZxwIBvJqRyKHz5V0zJxcgRE/sp6ELtaYPNQIBAhgPMjAyNjEwMTgwMzEy
MzNaMAMCAQECCH95c4u/r8ztoIIBkTCCAY0wggEzoAMCAQICFAVuSczookXxr2TFOK9nZuS7LHAkMAoGCCqGSM49BAMCMBkxFzAV
BgNVBAMMDlNlYWwgVGVzdCBwMjU2MCAXDTI2MTAxODAzMTIyNFoYDzIxMjYwOTI0MDMxMjI0WjAZMRcwFQYDVQQDDA5TZWFsIFRl
c3QgcDI1NjBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABGptA5/gwwxBMD19x4vnLV72s649kuPz96I/05+gEOJ33PFgmN8wIL8t
RiDxUEuHvW2FDjW/1ZaWTEfKxrae0tSjVzBVMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgbAMBYGA1UdJQEB/wQMMAoGCCsG
AQUFBwMIMB0GA1UdDgQWBBSPqrIvCsClMSdSCWjXgDaj9vXYiDAKBggqhkjOPQQDAgNIADBFAiEAqfTAIpyWlGhDo5U9auwKy8sg
WLM1LeNPTrozb+ch1WoCIDVC66widKwcFDdYN1c8+ZgY6waKz7LKNxcFpgCDltmHMYIBRDCCAUACAQEwMTAZMRcwFQYDVQQDDA5T
ZWFsIFRlc3QgcDI1NgIUBW5JzOiiRfGvZMU4r2dm5LsscCQwDQYJYIZIAWUDBAIBBQCggaQwGgYJKoZIhvcNAQkDMQ0GCyqGSIb3
DQEJEAEEMBwGCSqGSIb3DQEJBTEPFw0yNjEwMTgwMzEyMzNaMC8GCSqGSIb3DQEJBDEiBCDpesQ6w2mqjxuRXmlz+YJZ/C0gYxEY
EjB3kD2ZqA+BdjA3BgsqhkiG9w0BCRACLzEoMCYwJDAiBCDmuY6XU26+jXBv1mkfafmR0X4ebMobRKeRwjNwxjqSGTAKBggqhkjO
PQQDAgRGMEQCIBrq7pb+4rhe6fCnB8B4iOX8ee5cW6QfI/zy/6UHk6F0AiBBDbgbnT6ZzY37ADy81JaHCzFoTHQnGvMZMxa2bbew
gg==`),
  },
  {
    name: "a P-521 key, ecdsa-with-SHA512, signer digest SHA-512",
    pin: "851d6c6d2ab3a09756741f070d2f93cce3e80b077e837205c52767a9800984d7",
    token: b64(`
MIIEbDADAgEAMIIEYwYJKoZIhvcNAQcCoIIEVDCCBFACAQMxDzANBglghkgBZQMEAgMFADByBgsqhkiG9w0BCRABBKBjBGEwXwIB
AQYEKgMEATAxMA0GCWCGSAFlAwQCAQUABCDnoNnkEA9ZxwIBvJqRyKHz5V0zJxcgRE/sp6ELtaYPNQIBAhgPMjAyNjEwMTgwMzEy
MzNaMAMCAQECCHKYAxNMfuXQoIICGTCCAhUwggF2oAMCAQICFC4cNYi24lHgDNbTAM/v2lB2v/VrMAoGCCqGSM49BAMCMBkxFzAV
BgNVBAMMDlNlYWwgVGVzdCBwNTIxMCAXDTI2MTAxODAzMTIyNFoYDzIxMjYwOTI0MDMxMjI0WjAZMRcwFQYDVQQDDA5TZWFsIFRl
c3QgcDUyMTCBmzAQBgcqhkjOPQIBBgUrgQQAIwOBhgAEASauEMZmJ2Vs+dRYhkzT0vsy2HkZ8l2ikZn70NzyHTomu1C+xGCAoNC/
WO02lVoVrN9rZ6xaEVQ1ToHXXfBGiSVIAXDVfpf+uApOPhui56SWGn4A7WPuPtdAHUQZrZ5qS24Zi08sMf/ci2BiOk4Xjd9zNX5L
sBSmKxPrOLY99OO4u3uUo1cwVTAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIGwDAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAd
BgNVHQ4EFgQUl3TTqG+4mEXEvcfgvWbYDmxNyB0wCgYIKoZIzj0EAwIDgYwAMIGIAkIAyC9D4gb59oh3M9jaM3VhYWxr1NbBT9oo
FbBaNY2KzSPZd4OceaAY0KFltHAO6zqNuaHDt7jkCbYaHZvDV1ToY2QCQgFkWAKM6SGeK6MD6ovcFG4ts4TUAzjxr0V3RTFyOi9E
r02ddYtmSqBfYAQVLe30lyXn3vo3CyTIHUHQBb/ZwWAMTjGCAacwggGjAgEBMDEwGTEXMBUGA1UEAwwOU2VhbCBUZXN0IHA1MjEC
FC4cNYi24lHgDNbTAM/v2lB2v/VrMA0GCWCGSAFlAwQCAwUAoIHEMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRABBDAcBgkqhkiG
9w0BCQUxDxcNMjYxMDE4MDMxMjMzWjA3BgsqhkiG9w0BCRACLzEoMCYwJDAiBCCFHWxtKrOgl1Z0HwcNL5PM4+gLB36DcgXFJ2ep
gAmE1zBPBgkqhkiG9w0BCQQxQgRA2KDZd8usS/vxJ+3cuYLFvtJ9NrKS3sep9YRSjpFpTjbBf7KscRIPlD4gs6u4+ziqR3IvoZu8
xXZ7UQ+zdUb5MTAKBggqhkjOPQQDBASBiDCBhQJBW+5xzAWU5AtrJocJPGqXEwcN6rKbndHVTVb2TnFG+IIKoAAgmovayqe7iQFh
yvacRtIjg72p2kgzG+miWEEb9qkCQCyP/F4QPP/oTxwvWnwPyoHNo11T1O9L/LYlOMXAuuORItBvmUNw36JSJ3TXTJVj+/I1lpob
11cuPQlRLn/y9M0=`),
  },
  {
    name: "a P-384 key, a genTime with a fraction (.316), signer digest SHA-384",
    pin: "b1d15cb3b189532463a918f307db3dbe81c2a2cbefa29d033ab6a1039c6b5d6e",
    token: b64(`
MIID9DADAgEAMIID6wYJKoZIhvcNAQcCoIID3DCCA9gCAQMxDzANBglghkgBZQMEAgIFADB3BgsqhkiG9w0BCRABBKBoBGYwZAIB
AQYEKgMEATAxMA0GCWCGSAFlAwQCAQUABCDnoNnkEA9ZxwIBvJqRyKHz5V0zJxcgRE/sp6ELtaYPNQIBAhgTMjAyNjEwMTgwMzEy
MzMuMzE2WjADAgEBAgkA559UDBmhfZ+gggHOMIIByjCCAVCgAwIBAgIUTW/o663q9zLszRoC8MqjPkHvRzwwCgYIKoZIzj0EAwIw
GTEXMBUGA1UEAwwOU2VhbCBUZXN0IGZyYWMwIBcNMjYxMDE4MDMxMjI0WhgPMjEyNjA5MjQwMzEyMjRaMBkxFzAVBgNVBAMMDlNl
YWwgVGVzdCBmcmFjMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEX11gtrS5Jh7BZmg2NrBdJfVBnzPvuRmrcc8ZRe1Fxp80nTMCJiy3
Bhdm3XQdx4vXe362Ri1aRC407nFdu3UdZNuSzp2/wLOPEPQD02Q4jz7x+aHyrhcG+KZNJYtxNvoQo1cwVTAMBgNVHRMBAf8EAjAA
MA4GA1UdDwEB/wQEAwIGwDAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAdBgNVHQ4EFgQUQvfE2DKdJ1ZXj4m9hZ+alq/tZdswCgYI
KoZIzj0EAwIDaAAwZQIxAI6jQackpKxNW9kxpVxLtfoPXM7dLq8SstvcIXCFGgOJNacICYSFF/td5tf+udzTYAIwRvHdaYjGUQhO
3WmYblAkaNjj0wFf1MnVKqW/Tl6b0MgdwYy8ZmDdNajucTvu5SE9MYIBdTCCAXECAQEwMTAZMRcwFQYDVQQDDA5TZWFsIFRlc3Qg
ZnJhYwIUTW/o663q9zLszRoC8MqjPkHvRzwwDQYJYIZIAWUDBAICBQCggbQwGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMBwG
CSqGSIb3DQEJBTEPFw0yNjEwMTgwMzEyMzNaMDcGCyqGSIb3DQEJEAIvMSgwJjAkMCIEILHRXLOxiVMkY6kY8wfbPb6BwqLL76Kd
Azq2oQOca11uMD8GCSqGSIb3DQEJBDEyBDDMyRfiv4PhaID19fDv37WWaHjWTZyUSL/BIF/mrEx+fxyY4ZIaAYjcCm4sk+LA9gcw
CgYIKoZIzj0EAwMEZzBlAjEAjObsy/+MN79NChMDTxr/cNoREvvZoC6l96+HlDT4kDiODGt8xM4QOuWEgysEaTu7AjBmQYSBMwPk
BQUWzXl5oRsnY6NRCfl7pu5FkKYsMwKFYvGC3BfAvyLUGf9ls3UC0Q0=`),
  },
];
for (const g of generated) {
  equal(await verifiedGenTimeWithPins(g.token, digest, [g.pin]), stampedAt2, `${g.name} verifies`);
  equal(await verifiedGenTimeWithPins(g.token, digest, testPin), null, `${g.name}, under another pin, gives nothing`);
  equal(await verifiedGenTimeWithPins(g.token, nines, [g.pin]), null, `${g.name}, for another event, gives nothing`);
}

// ================================================================ part 3: a changed byte in each region

/** Offsets of each region in a token, found by walking it as the verifier does. */
function regions(token) {
  const der = new DERReader(token);
  const r = der.children(der.whole(0x30));
  const ci = der.children(r[1]);
  const sd = der.children(der.children(ci[1])[0]);
  const encap = der.children(sd[2]);
  const octets = der.children(encap[1])[0];
  const tst = new DERReader(der.value(octets));
  const t = tst.children(tst.whole(0x30));
  const imprint = tst.children(t[2]);
  const base = octets.valueStart;
  const si = der.children(der.children(sd[sd.length - 1])[0]);
  const certs = der.children(sd[3]);
  const mid = (n) => n.valueStart + ((n.end - n.valueStart) >> 1);
  return {
    "the message imprint": base + mid(imprint[1]),
    "the genTime": base + t[4].valueStart + 13,               // the last digit of the seconds
    "the TSTInfo serial number": base + mid(t[3]),
    "the signed attributes": mid(si[3]),
    "the signature": mid(si[5]),
    "the signer's digest algorithm": si[2].end - 3,
    "the first certificate": mid(certs[0]),
    "the first certificate's public key": der.subjectPublicKeyInfo(certs[0]).length > 0
      ? certs[0].start + (() => { const tbs = der.children(der.children(certs[0])[0]); return mid(tbs[(tbs[0].tag === 0xa0 ? 1 : 0) + 5]); })()
      : -1,
  };
}

for (const [label, token, dg, pins] of [
  ["the FreeTSA token", freeTSA, freeTSADigest, pinnedCertificates],
  ["the test P-384 token", p384SHA384, digest, testPin],
]) {
  equal(await verifiedGenTimeWithPins(token, dg, pins), label === "the FreeTSA token" ? freeTSAStampedAt : stampedAt,
    `${label} verifies before it is changed`);
  for (const [region, at] of Object.entries(regions(token))) {
    for (const mask of [0x01, 0x80]) {
      const bent = new Uint8Array(token);
      bent[at] ^= mask;
      let got = await verifiedGenTimeWithPins(bent, dg, pins);
      // The test token carries the pinned certificate twice, and a spare
      // copy is not signed over (TimestampVerifier.swift line 159: any one
      // pinned certificate will do). So a change to the first copy must
      // leave the time standing, and a change to both copies must not.
      if (label === "the test P-384 token" && region.startsWith("the first certificate")) {
        equal(got, stampedAt, `${label}: a change to one spare copy of the certificate (${region}, mask ${mask}) changes nothing`);
        const der = new DERReader(bent);
        const sd = der.children(der.children(der.children(der.children(der.whole(0x30))[1])[1])[0]);
        const certs = der.children(sd[3]);
        bent[at - certs[0].start + certs[1].start] ^= mask;
        got = await verifiedGenTimeWithPins(bent, dg, pins);
        equal(got, null, `${label}: the same change to both copies (${region}, mask ${mask}) gives nothing`);
        continue;
      }
      equal(got, null, `${label}: a change in ${region} (mask ${mask}) gives nothing`);
    }
  }
}

// The token is never changed, and a Node Buffer works the same.
{
  const before = toHex(freeTSA);
  const buf = Buffer.from(freeTSA);
  equal(await verifiedGenTime(buf, Buffer.from(freeTSADigest)), freeTSAStampedAt, "a Node Buffer token verifies the same");
  check(toHex(buf) === before && toHex(freeTSA) === before, "verifying never changes the token's bytes");
  equal(await verifiedGenTime(freeTSA, freeTSADigest), freeTSAStampedAt, "a remembered verdict comes back the same");
  equal(await verifiedGenTime(freeTSA, nines), null, "and a remembered refusal too");
  equal(await verifiedGenTime(new Uint8Array(maxTokenBytes + 1), digest), null, "an oversized token is refused before anything else");
  equal(await verifiedGenTime(freeTSA, new Uint8Array(0)), null, "an empty digest is refused");
  equal(await verifiedGenTime("not bytes", freeTSADigest), null, "a token that is not bytes is refused");
}

// ================================================================ part 4: tokens built field by field

// A tiny DER writer and a throwaway P-384 authority. The verifier does not
// check the certificate's own signature or its fields (only its SHA-256 pin
// and the key at TBSCertificate field 6), so a minimal certificate is enough.

function len(n, longBytes = 0) {
  if (!longBytes && n < 0x80) return Uint8Array.of(n);
  const out = [];
  for (let x = n; x > 0; x = Math.floor(x / 256)) out.unshift(x & 0xff);
  while (out.length < longBytes) out.unshift(0);
  return Uint8Array.of(0x80 | out.length, ...out);
}
const tlv = (tag, ...parts) => { const c = concat(...parts); return concat(Uint8Array.of(tag), len(c.length), c); };
const tlvLong = (tag, bytes, ...parts) => { const c = concat(...parts); return concat(Uint8Array.of(tag), len(c.length, bytes), c); };
const seq = (...p) => tlv(0x30, ...p);
const set = (...p) => tlv(0x31, ...p);
const oid = (o) => tlv(0x06, o);
const int = (...b) => tlv(0x02, Uint8Array.of(...b));
const octets = (b) => tlv(0x04, b);
const NULL = Uint8Array.of(0x05, 0x00);
const alg = (o, params = true) => (params ? seq(oid(o), NULL) : seq(oid(o)));
const OID_MD5 = fromHex("2a864886f70d0205");
const OID_ECDSA_SHA1 = fromHex("2a8648ce3d0401");

function rawToDer(raw) {
  const half = raw.length / 2;
  const intOf = (b) => {
    let i = 0;
    while (i < b.length - 1 && b[i] === 0) i++;
    let n = b.subarray(i);
    if (n[0] & 0x80) n = concat(Uint8Array.of(0), n);
    return tlv(0x02, n);
  };
  return seq(intOf(raw.subarray(0, half)), intOf(raw.subarray(half)));
}

const keys = await subtle.generateKey({ name: "ECDSA", namedCurve: "P-384" }, true, ["sign", "verify"]);
const spki = new Uint8Array(await subtle.exportKey("spki", keys.publicKey));
const certificate = seq(
  seq(tlv(0xa0, int(2)), int(1), alg(OID.ecdsaSHA384, false), seq(), seq(), seq(), spki),
  alg(OID.ecdsaSHA384, false), tlv(0x03, Uint8Array.of(0)));
const builtPin = [toHex(await sha256(certificate))];
const spareKeys = await subtle.generateKey({ name: "ECDSA", namedCurve: "P-384" }, true, ["sign", "verify"]);
const spareCertificate = seq(
  seq(tlv(0xa0, int(2)), int(2), alg(OID.ecdsaSHA384, false), seq(), seq(), seq(),
    new Uint8Array(await subtle.exportKey("spki", spareKeys.publicKey))),
  alg(OID.ecdsaSHA384, false), tlv(0x03, Uint8Array.of(0)));

const hashOf = async (name, data) => new Uint8Array(await subtle.digest(name, data));

/** A TimeStampResp. Every field can be replaced through `o`. */
async function build(o = {}) {
  const imprintAlg = o.imprintAlg ?? OID.sha256;
  const tstInfo = o.tstInfo ?? seq(
    o.tstVersion ?? int(1), oid(fromHex("2a030401")),
    seq(alg(imprintAlg), octets(o.imprint ?? digest)),
    int(7), tlv(0x18, utf8(o.genTime ?? "20261002214952Z")),
    ...(o.tstExtra ?? []));
  const digestName = o.digestName ?? "SHA-384";
  const digestOID = o.digestOID ?? { "SHA-256": OID.sha256, "SHA-384": OID.sha384, "SHA-512": OID.sha512 }[digestName];
  const mdValue = o.messageDigest ?? await hashOf(digestName, tstInfo);
  const contentTypeAttr = seq(oid(OID.contentType), set(oid(o.contentTypeValue ?? OID.tstInfo)));
  const messageDigestAttr = seq(oid(OID.messageDigest), set(octets(mdValue)));
  const attrs = o.attrs ?? [contentTypeAttr, messageDigestAttr, ...(o.extraAttrs ?? [])];
  const attrsSet = set(...attrs);
  const signName = o.signName ?? "SHA-384";
  const toSign = o.signOverImplicitTag ? concat(Uint8Array.of(0xa0), attrsSet.subarray(1)) : attrsSet;
  const raw = new Uint8Array(await subtle.sign({ name: "ECDSA", hash: signName }, (o.signKey ?? keys).privateKey, toSign));
  const signatureOID = o.signatureOID ?? { "SHA-256": OID.ecdsaSHA256, "SHA-384": OID.ecdsaSHA384, "SHA-512": OID.ecdsaSHA512 }[signName];
  const signerInfo = seq(
    int(1),
    o.sid ?? seq(seq(), int(1)),
    alg(digestOID),
    tlv(0xa0, ...attrs),
    alg(signatureOID),
    octets(o.signature ?? rawToDer(raw)),
    ...(o.unsignedAttrs ? [tlv(0xa1, seq(oid(fromHex("2a0304")), set(NULL)))] : []));
  const certs = o.certs ?? [certificate];
  const middle = o.middle ?? [tlv(0xa0, ...certs), ...(o.crls ? [tlv(0xa1)] : [])];
  const signedData = seq(
    int(3), set(alg(digestOID)),
    seq(oid(OID.tstInfo), tlv(0xa0, octets(tstInfo))),
    ...middle,
    set(...(o.signerInfos ?? [signerInfo])));
  const contentInfo = seq(oid(o.signedDataOID ?? OID.signedData), tlv(0xa0, signedData));
  const status = seq(int(o.status ?? 0));
  const resp = o.outerLong ? tlvLong(0x30, o.outerLong, status, contentInfo) : seq(status, contentInfo);
  return concat(resp, o.trailing ?? new Uint8Array(0));
}

const built = async (o) => verifiedGenTimeWithPins(await build(o), digest, builtPin);

// Each expectation is what the Swift does with that token, read from the
// line named. Accepted means stampedAt, refused means null.
const cases = [
  ["the builder's plain token is accepted", {}, stampedAt],
  ["status 1, granted with modifications, is accepted (line 215)", { status: 1 }, stampedAt],
  ["status 2, rejection, is refused (line 215)", { status: 2 }, null],
  ["a signer digest of SHA-256 is accepted (line 268)", { digestName: "SHA-256" }, stampedAt],
  ["a signer digest of SHA-512 is accepted (line 270)", { digestName: "SHA-512" }, stampedAt],
  ["a signer digest of MD5 is refused (line 120)", { digestOID: OID_MD5 }, null],
  ["ecdsa-with-SHA256 on a P-384 key is accepted (line 275)", { signName: "SHA-256" }, stampedAt],
  ["ecdsa-with-SHA512 on a P-384 key is accepted (line 277)", { signName: "SHA-512" }, stampedAt],
  ["a bare id-ecPublicKey signature algorithm uses the signer digest's hash (line 125)",
    { signatureOID: OID.ecPublicKey, digestName: "SHA-512", signName: "SHA-512" }, stampedAt],
  ["a bare id-ecPublicKey with a different hash than the signer digest is refused (line 126)",
    { signatureOID: OID.ecPublicKey, digestName: "SHA-256", signName: "SHA-384" }, null],
  ["ecdsa-with-SHA1 is refused (line 128)", { signatureOID: OID_ECDSA_SHA1, signName: "SHA-1" }, null],
  ["a signature by another key is refused (line 163)", { signKey: spareKeys }, null],
  ["a signature over the [0] tag instead of the SET tag is refused (line 155)", { signOverImplicitTag: true }, null],
  ["a message digest of other bytes is refused (line 146)", { messageDigest: new Uint8Array(48) }, null],
  ["a message digest of SHA-256 under a SHA-384 signer digest is refused (line 146)",
    { digestName: "SHA-384", messageDigest: new Uint8Array(32) }, null],
  ["no content type attribute is refused (line 150)", { attrs: "noContentType" }, null],
  ["two message digest attributes are refused (line 150)", { attrs: "twoDigests" }, null],
  ["a content type that is not TSTInfo is refused (line 142)", { contentTypeValue: OID.signedData }, null],
  ["an unknown extra signed attribute is accepted (line 136 to 149)",
    { extraAttrs: [seq(oid(fromHex("2a864886f70d010905")), set(tlv(0x17, utf8("261002214952Z"))))] }, stampedAt],
  ["a signed attribute that is not a SEQUENCE is refused (line 137)", { extraAttrs: [set()] }, null],
  ["unsigned attributes [1] are accepted (line 119)", { unsignedAttrs: true }, stampedAt],
  ["a subjectKeyIdentifier sid [0] is accepted (line 117)", { sid: tlv(0x80, new Uint8Array(20)) }, stampedAt],
  ["an issuerAndSerialNumber sid with the SET tag is refused (line 117)", { sid: set(seq(), int(1)) }, null],
  ["a crls [1] after the certificates is accepted (line 100)", { crls: true }, stampedAt],
  ["no certificates is refused (line 100)", { middle: [] }, null],
  ["crls before certificates is refused (line 100)", { middle: "crlsFirst" }, null],
  ["an empty certificate set is refused (line 158)", { certs: [] }, null],
  ["an unpinned spare certificate before the pinned one is accepted (line 159)", { certs: [spareCertificate, certificate] }, stampedAt],
  ["only an unpinned certificate is refused (line 161)", { certs: [spareCertificate] }, null],
  ["two signer infos are refused (line 115)", { signerInfos: "two" }, null],
  ["an imprint algorithm of SHA-384 is refused, even with the right bytes (line 176)", { imprintAlg: OID.sha384 }, null],
  ["a TSTInfo version 2 is refused (line 173)", { tstVersion: int(2) }, null],
  ["a TSTInfo with extra fields after genTime is accepted (line 172, t.count >= 5)",
    { tstExtra: [seq(int(1)), tlv(0x01, Uint8Array.of(0xff))] }, stampedAt],
  ["a ContentInfo that is not signedData is refused (line 91)", { signedDataOID: OID.tstInfo }, null],
  ["a trailing byte after the response is refused (line 313)", { trailing: Uint8Array.of(0) }, null],
  ["a long form length with leading zeros on the response is accepted, as the Swift does not insist on the shortest (line 325 to 335)",
    { outerLong: 4 }, stampedAt],
  ["a genTime of February 29 in a leap year is accepted (line 206)", { genTime: "20280229000000Z", expect: Date.UTC(2028, 1, 29) / 1000 }, "expect"],
  ["a genTime of February 29 in 2100 is refused (line 206)", { genTime: "21000229000000Z" }, null],
  ["a genTime with a fraction keeps whole seconds (line 195)", { genTime: "20261002214952.999999Z" }, stampedAt],
  ["a genTime with a + offset is refused (line 184)", { genTime: "20261002214952+0000" }, null],
  ["a genTime of second 60 is refused (line 200)", { genTime: "20261002214960Z" }, null],
];
for (const [label, o, want] of cases) {
  const opts = { ...o };
  if (opts.attrs === "noContentType") {
    opts.attrs = [seq(oid(OID.messageDigest), set(octets(await hashOf("SHA-384", (await tstOf(opts))))))];
  } else if (opts.attrs === "twoDigests") {
    const md = seq(oid(OID.messageDigest), set(octets(await hashOf("SHA-384", (await tstOf(opts))))));
    opts.attrs = [seq(oid(OID.contentType), set(oid(OID.tstInfo))), md, md];
  }
  // The pinned certificate sits in both, so only the order can refuse it.
  if (opts.middle === "crlsFirst") opts.middle = [tlv(0xa1, certificate), tlv(0xa0, certificate)];
  if (opts.signerInfos === "two") {
    const one = await signerInfoOf(await build({}));
    opts.signerInfos = [one, one];
  }
  equal(await built(opts), want === "expect" ? o.expect : want, label);
}

/** The TSTInfo bytes the builder makes for these options. */
async function tstOf(o) {
  const der = new DERReader(await build({ ...o, attrs: undefined }));
  const sd = der.children(der.children(der.children(der.children(der.whole(0x30))[1])[1])[0]);
  return der.value(der.children(der.children(sd[2])[1])[0]);
}

/** The one SignerInfo of a built token, as bytes. */
async function signerInfoOf(token) {
  const der = new DERReader(token);
  const sd = der.children(der.children(der.children(der.children(der.whole(0x30))[1])[1])[0]);
  return der.full(der.children(sd[sd.length - 1])[0]);
}

// GeneralizedTime against Foundation's gregorian calendar, which is Julian
// before 1582-10-15 (TimestampVerifier.swift line 201; swift-foundation
// Calendar_Gregorian.swift). Read from Foundation's code, not run on a phone.
{
  const g = (s) => generalizedTime(utf8(s));
  equal(g("19700101000000Z"), 0, "the epoch is 0");
  equal(g("99991231235959Z"), Date.UTC(9999, 11, 31, 23, 59, 59) / 1000, "the last second of year 9999");
  equal(g("16000229000000Z"), Date.UTC(1600, 1, 29) / 1000, "1600 is a leap year");
  equal(g("19000229000000Z"), null, "1900 is not a leap year");
  equal(g("15821015000000Z"), -12219292800, "1582-10-15 is the first Gregorian day");
  equal(g("15821004000000Z"), -12219292800 - 86400, "1582-10-04 is the day before it, on the Julian calendar");
  equal(g("15821010000000Z"), null, "1582-10-10 never happened, so it is refused");
  equal(g("15000229000000Z") !== null, true, "1500-02-29 exists on the Julian calendar, so it is accepted");
  equal(g("00000101000000Z"), null, "year 0000 is refused: it reads back as 1 BC");
  equal(g("00010101000000Z") !== null, true, "year 0001 is accepted");
  equal(g("20261002214952.1234567890123456Z"), stampedAt, "a fraction up to 32 bytes in all is allowed");
  equal(g("20261002214952.12345678901234567Z"), null, "a GeneralizedTime over 32 bytes is refused");
  equal(g("20261002214952,1Z"), null, "a comma for the fraction is refused");
  equal(g("20261002244952Z"), null, "hour 24 is refused");
  equal(g("20261000214952Z"), null, "day 0 is refused");
  equal(g("20260931214952Z"), null, "September 31 is refused");
}

console.log(`${checks} checks, ${failures} failures`);
process.exit(failures ? 1 : 0);
