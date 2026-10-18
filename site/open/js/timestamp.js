// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  timestamp.js
//
//  CHECKING A TIMESTAMP TOKEN ON THE PAGE (audit H2). A line by line port
//  of TimestampVerifier, TimestampOID, TimestampHash, DERReader and
//  TimestampVerdicts in Seal/Record/TimestampVerifier.swift. It must make
//  the same accept or refuse decision as the phone for every input, so the
//  page never believes an authority time the phone would not.
//
//  A token's time is believed only when ALL of this holds:
//    1. It is a granted RFC 3161 TimeStampResp, read as DER from the outside
//       in, every length checked against its parent. Nothing is scanned for.
//    2. Its TSTInfo's message imprint is SHA-256 and holds exactly this
//       event's digest.
//    3. Its one SignerInfo's signed attributes name the content a TSTInfo
//       and carry the hash of exactly these TSTInfo bytes.
//    4. The ECDSA signature over those attributes verifies, with WebCrypto
//       alone, under the key of a certificate in the token whose SHA-256 is
//       pinned below.
//  Anything else gives null, and the caller falls back to the actor's own
//  signed clock, exactly as for an event with no token. A wrong answer here
//  can only ever be "no authority time", never an invented one.
//
//  Times are seconds since 1970. Like the Swift, a fraction of a second in
//  genTime is checked for shape and then ignored, so the result is always a
//  whole number of seconds (TimestampVerifier.swift line 195 to 207: the
//  fraction never reaches DateComponents).

import { toHex, concat, same, sha256, sha384, subtle } from "./bytes.js";
import { verifyECDSA, derToRaw } from "./ecdsa.js";

// ---------------------------------------------------------------- pins

/**
 * SHA-256 of the DER of each timestamp signing certificate the page
 * believes, as lowercase hex. FreeTSA's TSA certificate: ECDSA P-384, valid
 * 2026-02-15 to 2040-02-02. The bytes are copied from
 * TimestampVerifier.pinnedCertificates; the test checks they still match.
 * Add new pins; never remove an old one while tokens it signed are in
 * anyone's record.
 */
export const pinnedCertificates = Object.freeze([
  toHex(Uint8Array.of(
    0x32, 0xe8, 0x41, 0xa9, 0x5c, 0xc1, 0x16, 0x41, 0x01, 0xff, 0xde, 0x41, 0x29, 0x8e, 0xf2, 0xfc,
    0x75, 0xc1, 0xc4, 0x37, 0x2e, 0xf0, 0x95, 0xe8, 0x8a, 0x6b, 0xbd, 0x47, 0xdf, 0xb1, 0x91, 0xfc)),
]);

/** A timestamp token is a couple of kilobytes. Anything this large is not one. */
export const maxTokenBytes = 64 * 1024;

// ---------------------------------------------------------------- object identifiers

/** DER contents, without tag and length. TimestampOID. */
export const OID = Object.freeze({
  signedData: Uint8Array.of(0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02),            // 1.2.840.113549.1.7.2
  tstInfo: Uint8Array.of(0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x10, 0x01, 0x04),    // 1.2.840.113549.1.9.16.1.4
  contentType: Uint8Array.of(0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x03),           // 1.2.840.113549.1.9.3
  messageDigest: Uint8Array.of(0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x04),         // 1.2.840.113549.1.9.4
  sha256: Uint8Array.of(0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01),                // 2.16.840.1.101.3.4.2.1
  sha384: Uint8Array.of(0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02),                // 2.16.840.1.101.3.4.2.2
  sha512: Uint8Array.of(0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03),                // 2.16.840.1.101.3.4.2.3
  ecdsaSHA256: Uint8Array.of(0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02),                 // 1.2.840.10045.4.3.2
  ecdsaSHA384: Uint8Array.of(0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x03),                 // 1.2.840.10045.4.3.3
  ecdsaSHA512: Uint8Array.of(0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x04),                 // 1.2.840.10045.4.3.4
  ecPublicKey: Uint8Array.of(0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01),                       // 1.2.840.10045.2.1
});

// ---------------------------------------------------------------- hashes

// TimestampHash: the three hashes the Swift accepts, as WebCrypto names.
// SHA-256, SHA-384 and SHA-512 are all accepted, for the signer's digest
// algorithm and for the signature, because the Swift accepts all three
// (TimestampHash, Swift lines 264 to 288). The real FreeTSA token is signed
// with ecdsa-with-SHA512.

/** TimestampHash(digestOID:) */
function hashFromDigestOID(oid) {
  if (same(oid, OID.sha256)) return "SHA-256";
  if (same(oid, OID.sha384)) return "SHA-384";
  if (same(oid, OID.sha512)) return "SHA-512";
  return null;
}

/** TimestampHash(ecdsaOID:) */
function hashFromECDSAOID(oid) {
  if (same(oid, OID.ecdsaSHA256)) return "SHA-256";
  if (same(oid, OID.ecdsaSHA384)) return "SHA-384";
  if (same(oid, OID.ecdsaSHA512)) return "SHA-512";
  return null;
}

/** TimestampHash.hash */
async function hashWith(name, data) {
  if (name === "SHA-256") return sha256(data);
  if (name === "SHA-384") return sha384(data);
  if (name === "SHA-512") return new Uint8Array(await subtle.digest("SHA-512", data));
  throw new Error("unknown hash");
}

// ---------------------------------------------------------------- a strict, bounded DER reader

/**
 * DERReader. Reads DER without recursion and without trusting a single
 * length: every node must fit inside its parent, and anything malformed is
 * null. Only what timestamp tokens use: low tag numbers, definite lengths
 * of at most four bytes. Like the Swift, it does not insist that a long
 * length form is the shortest one (Swift lines 325 to 335 accept it), so
 * neither does this.
 *
 * A node is { tag, start, valueStart, end }: `start..end` is the Swift's
 * `full` range and `valueStart..end` its `value` range.
 */
export class DERReader {
  constructor(bytes) { this.bytes = bytes; }

  /** The one node that spans every byte, with this tag. Trailing bytes are refused. */
  whole(tag) {
    const node = this.node(0, this.bytes.length);
    if (!node || node.tag !== tag || node.end !== this.bytes.length) return null;
    return node;
  }

  node(start, end) {
    const b = this.bytes;
    if (!(start >= 0 && end <= b.length && start < end && end - start >= 2)) return null;
    const tag = b[start];
    if ((tag & 0x1f) === 0x1f) return null;                 // high tag numbers: not here
    let i = start + 1;
    const first = b[i];
    i += 1;
    let length = 0;
    if (first < 0x80) {
      length = first;
    } else {
      const count = first & 0x7f;
      // 0x80 is BER's indefinite length, never DER. Over four bytes is never a token.
      if (count < 1 || count > 4 || count > end - i) return null;
      // Multiply, not shift: a JavaScript shift is signed 32-bit, and a
      // negative length would slip past the bound below.
      for (let k = 0; k < count; k++) { length = length * 256 + b[i]; i += 1; }
    }
    if (length > end - i) return null;
    return { tag, start, valueStart: i, end: i + length };
  }

  /**
   * The children of a constructed node, which must tile its contents
   * exactly. At most 64, which is far more than a token has anywhere.
   */
  children(node) {
    if ((node.tag & 0x20) === 0) return null;
    const out = [];
    let i = node.valueStart;
    while (i < node.end) {
      if (out.length >= 64) return null;
      const child = this.node(i, node.end);
      if (!child) return null;
      out.push(child);
      i = child.end;
    }
    return out;
  }

  /** The contents of a node, as a view into the reader's bytes. */
  value(node) { return this.bytes.subarray(node.valueStart, node.end); }

  /** Tag, length and contents, as a view into the reader's bytes. */
  full(node) { return this.bytes.subarray(node.start, node.end); }

  isOID(node, oid) { return node.tag === 0x06 && same(this.value(node), oid); }

  /** AlgorithmIdentifier ::= SEQUENCE { algorithm OID, parameters OPTIONAL } */
  algorithmOID(node) {
    if (node.tag !== 0x30) return null;
    const parts = this.children(node);
    if (!parts || parts.length < 1 || parts.length > 2 || parts[0].tag !== 0x06) return null;
    return this.value(parts[0]);
  }

  /**
   * Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signature }
   * TBSCertificate ::= SEQUENCE { [0] version OPTIONAL, serialNumber,
   *   signature, issuer, validity, subject, subjectPublicKeyInfo, ... }
   */
  subjectPublicKeyInfo(certificate) {
    const parts = this.children(certificate);
    if (!parts || parts.length !== 3 || parts[0].tag !== 0x30) return null;
    const tbs = this.children(parts[0]);
    if (!tbs || tbs.length === 0) return null;
    const index = (tbs[0].tag === 0xa0 ? 1 : 0) + 5;
    if (!(tbs.length > index) || tbs[index].tag !== 0x30) return null;
    return this.full(tbs[index]);
  }
}

// ---------------------------------------------------------------- the check

/** TimestampVerdicts: verdicts by token, bounded, cleared outright when full. */
const verdicts = new Map();

function remember(key, verdict) {
  // An owner who checks in daily for years stamps a few thousand events;
  // this holds far more, so a busy estate never thrashes.
  if (verdicts.size >= 65_536) verdicts.clear();
  verdicts.set(key, verdict);
}

/**
 * The authority's time for the event with `digest`, in seconds since 1970,
 * or null unless every check passes, against the pinned certificates.
 * Remembered per token, as on the phone.
 */
export async function verifiedGenTime(token, digest) {
  if (!(token instanceof Uint8Array) || !(digest instanceof Uint8Array)) return null;
  if (token.length > maxTokenBytes) return null;
  const key = toHex(await sha256(concat(token, digest)));
  if (verdicts.has(key)) return verdicts.get(key);
  const verdict = await verifiedGenTimeWithPins(token, digest, pinnedCertificates);
  remember(key, verdict);
  return verdict;
}

/**
 * The same, against any set of pins (hex strings or byte arrays of
 * certificate SHA-256s). The tests use their own. Not remembered.
 */
export async function verifiedGenTimeWithPins(token, digest, pins) {
  if (!(token instanceof Uint8Array) || !(digest instanceof Uint8Array)) return null;
  const pinSet = new Set();
  for (const p of pins ?? []) pinSet.add(p instanceof Uint8Array ? toHex(p) : String(p).toLowerCase());
  try {
    return await check(token, digest, pinSet);
  } catch {
    // The Swift cannot throw here. Anything unexpected is "no authority time".
    return null;
  }
}

async function check(token, digest, pins) {
  if (digest.length === 0 || pins.size === 0 || token.length > maxTokenBytes) return null;
  const der = new DERReader(token);

  // TimeStampResp ::= SEQUENCE { status PKIStatusInfo, timeStampToken ContentInfo }
  const response = der.whole(0x30);
  if (!response) return null;
  const r = der.children(response);
  if (!r || r.length !== 2 || !isGranted(der, r[0])) return null;

  // ContentInfo ::= SEQUENCE { id-signedData, [0] EXPLICIT SignedData }
  if (r[1].tag !== 0x30) return null;
  const ci = der.children(r[1]);
  if (!ci || ci.length !== 2 || !der.isOID(ci[0], OID.signedData) || ci[1].tag !== 0xa0) return null;
  const wrapped = der.children(ci[1]);
  if (!wrapped || wrapped.length !== 1 || wrapped[0].tag !== 0x30) return null;
  const sd = der.children(wrapped[0]);
  if (!sd || sd.length < 5) return null;

  // SignedData ::= SEQUENCE { version, digestAlgorithms SET, encapContentInfo,
  //   certificates [0] IMPLICIT, crls [1] IMPLICIT OPTIONAL, signerInfos SET }
  // Certificates are required: Seal always asks for them (certReq).
  const last = sd[sd.length - 1];
  if (sd[0].tag !== 0x02 || sd[1].tag !== 0x31 || sd[2].tag !== 0x30 || last.tag !== 0x31) return null;
  const middle = sd.slice(3, sd.length - 1).map((n) => n.tag);
  const middleOK = (middle.length === 1 && middle[0] === 0xa0)
    || (middle.length === 2 && middle[0] === 0xa0 && middle[1] === 0xa1);
  if (!middleOK) return null;
  const certificateSet = sd[3];

  // EncapsulatedContentInfo ::= SEQUENCE { id-ct-TSTInfo, [0] EXPLICIT OCTET STRING }
  const encap = der.children(sd[2]);
  if (!encap || encap.length !== 2 || !der.isOID(encap[0], OID.tstInfo) || encap[1].tag !== 0xa0) return null;
  const content = der.children(encap[1]);
  if (!content || content.length !== 1 || content[0].tag !== 0x04) return null;
  const tstInfo = der.value(content[0]);

  // The cheap checks first: is this token about this event at all?
  const genTime = genTimeOfTSTInfo(tstInfo, digest);
  if (genTime === null) return null;

  // SignerInfo ::= SEQUENCE { version, sid, digestAlgorithm, signedAttrs [0],
  //   signatureAlgorithm, signature OCTET STRING, unsignedAttrs [1] OPTIONAL }
  // RFC 3161: the token carries the TSA's signature and no other.
  const signers = der.children(last);
  if (!signers || signers.length !== 1 || signers[0].tag !== 0x30) return null;
  const si = der.children(signers[0]);
  if (!si || !(si.length === 6 || si.length === 7)) return null;
  if (si[0].tag !== 0x02 || !(si[1].tag === 0x30 || si[1].tag === 0x80)) return null;
  if (si[2].tag !== 0x30 || si[3].tag !== 0xa0 || si[4].tag !== 0x30 || si[5].tag !== 0x04) return null;
  if (!(si.length === 6 || si[6].tag === 0xa1)) return null;
  const digestOID = der.algorithmOID(si[2]);
  if (!digestOID) return null;
  const digestHash = hashFromDigestOID(digestOID);
  if (!digestHash) return null;
  const signatureOID = der.algorithmOID(si[4]);
  if (!signatureOID) return null;
  let signatureHash = hashFromECDSAOID(signatureOID);
  if (!signatureHash) {
    if (same(signatureOID, OID.ecPublicKey)) signatureHash = digestHash;
    else return null;
  }

  // The signed attributes must say "this is a TSTInfo" and carry the hash
  // of exactly these TSTInfo bytes, each exactly once. The Swift hashes
  // inside the loop (line 146); hashing once before it gives the same answer.
  const attributes = der.children(si[3]);
  if (!attributes) return null;
  const tstInfoHash = await hashWith(digestHash, tstInfo);
  let contentTypes = 0;
  let messageDigests = 0;
  for (const attribute of attributes) {
    if (attribute.tag !== 0x30) return null;
    const parts = der.children(attribute);
    if (!parts || parts.length !== 2 || parts[0].tag !== 0x06 || parts[1].tag !== 0x31) return null;
    const values = der.children(parts[1]);
    if (!values) return null;
    const type = der.value(parts[0]);
    if (same(type, OID.contentType)) {
      if (values.length !== 1 || !der.isOID(values[0], OID.tstInfo)) return null;
      contentTypes += 1;
    } else if (same(type, OID.messageDigest)) {
      if (values.length !== 1 || values[0].tag !== 0x04 || !same(der.value(values[0]), tstInfoHash)) return null;
      messageDigests += 1;
    }
  }
  if (contentTypes !== 1 || messageDigests !== 1) return null;

  // What was signed is the attributes as a SET: the same bytes with the
  // [0] IMPLICIT tag put back to the SET tag it stands for (RFC 5652 5.4).
  // A fresh copy, so the caller's token is never changed. (Not .slice():
  // on a Node Buffer that is a view, not a copy.)
  const signedBytes = new Uint8Array(der.full(si[3]));
  signedBytes[0] = 0x31;
  const signature = der.value(si[5]);

  const certificates = der.children(certificateSet);
  if (!certificates || certificates.length === 0) return null;
  // certificates.contains { ... }: true at the first pinned certificate
  // whose key verifies. A spare unpinned or broken copy does not matter.
  for (const certificate of certificates) {
    if (certificate.tag !== 0x30) continue;
    if (!pins.has(toHex(await sha256(der.full(certificate))))) continue;
    const spki = der.subjectPublicKeyInfo(certificate);
    if (!spki) continue;
    if (await ecdsaVerifies(spki, signature, signedBytes, signatureHash)) return genTime;
  }
  return null;
}

/**
 * TSTInfo ::= SEQUENCE { version 1, policy, messageImprint, serialNumber,
 * genTime, ... }. The imprint must be SHA-256 over exactly `digest`.
 */
function genTimeOfTSTInfo(bytes, digest) {
  const tst = new DERReader(bytes);
  const top = tst.whole(0x30);
  if (!top) return null;
  const t = tst.children(top);
  if (!t || t.length < 5) return null;
  if (t[0].tag !== 0x02 || !same(tst.value(t[0]), Uint8Array.of(0x01))) return null;
  if (t[1].tag !== 0x06 || t[2].tag !== 0x30 || t[3].tag !== 0x02 || t[4].tag !== 0x18) return null;
  const imprint = tst.children(t[2]);
  if (!imprint || imprint.length !== 2 || imprint[1].tag !== 0x04) return null;
  const alg = tst.algorithmOID(imprint[0]);
  if (!alg || !same(alg, OID.sha256)) return null;
  if (!same(tst.value(imprint[1]), digest)) return null;
  return generalizedTime(tst.value(t[4]));
}

function isGranted(der, status) {
  // PKIStatusInfo ::= SEQUENCE { status INTEGER, ... }: 0 granted, 1 with mods.
  if (status.tag !== 0x30) return false;
  const parts = der.children(status);
  if (!parts || parts.length === 0 || parts[0].tag !== 0x02) return false;
  const value = der.value(parts[0]);
  return same(value, Uint8Array.of(0x00)) || same(value, Uint8Array.of(0x01));
}

// ---------------------------------------------------------------- GeneralizedTime

/**
 * GeneralizedTime as RFC 3161 requires it: YYYYMMDDhhmmss[.f...]Z, UTC.
 * Seconds since 1970, or null. The fraction is checked and then ignored.
 */
export function generalizedTime(raw) {
  const b = raw;
  if (!(b instanceof Uint8Array) || b.length < 15 || b.length > 32 || b[b.length - 1] !== 0x5a) return null;
  const number = (from, count) => {
    let value = 0;
    for (let i = from; i < from + count; i++) {
      if (!(b[i] >= 0x30 && b[i] <= 0x39)) return null;
      value = value * 10 + (b[i] - 0x30);
    }
    return value;
  };
  const year = number(0, 4), month = number(4, 2), day = number(6, 2);
  const hour = number(8, 2), minute = number(10, 2), second = number(12, 2);
  if (year === null || month === null || day === null || hour === null || minute === null || second === null) return null;
  if (b.length > 15) {
    // A fraction of a second: a dot, at least one digit, then the Z.
    if (b[14] !== 0x2e || b.length < 17) return null;
    for (let i = 15; i < b.length - 1; i++) if (!(b[i] >= 0x30 && b[i] <= 0x39)) return null;
  }
  if (month < 1 || month > 12 || day < 1 || day > 31 || hour >= 24 || minute >= 60 || second >= 60) return null;
  return gregorianDate(year, month, day, hour, minute, second);
}

// The Swift builds the date with Calendar(identifier: .gregorian) in GMT
// and refuses it unless DateComponents.isValidDate says yes (Swift lines
// 201 to 207). Foundation's gregorian calendar is not proleptic: before
// 1582-10-15 it is the Julian calendar, the ten days 1582-10-05 to
// 1582-10-14 do not exist, and year 0000 is refused (it reads back as
// 1 BC). JavaScript's Date is proleptic Gregorian, so this ports
// Foundation's own arithmetic instead (swift-foundation,
// Calendar_Gregorian.swift: julianDay(ofDay:month:year:),
// yearMonthDayFromJulianDay, date(from:) and isValidDate). For any year
// after 1582 the answer is the same as Date.UTC.

const JULIAN_CUTOVER_DAY = 2299161;              // 1582-10-15, noon based
const GREGORIAN_START = -12219292800;            // 1582-10-15T00:00:00Z
const JULIAN_DAY_AT_1970 = 2440588;              // 1970-01-01, noon based
const tdiv = (a, b) => Math.trunc(a / b);        // Swift's Int division

function julianDayOf(day, month, year, useJulianReference) {
  const y = 4716, j = 1401, m = 2, n = 12, r = 4, p = 1461, q = 0, u = 5, s = 153, t = 2, A = 184, C = -38;
  const h = month - m;
  const g = year + y - tdiv(n - h, n);
  const f = (h - 1 + n) % n;
  const e = tdiv(p * g + q, r) + day - 1 - j;
  const J = e + tdiv(s * f + t, u);
  return useJulianReference ? J : J - tdiv(3 * tdiv(g + A, 100), 4) - C;
}

function yearMonthDayFromJulianDay(julianDay, useJulianRef) {
  const y = 4716, j = 1401, m = 2, n = 12, r = 4, p = 1461, v = 3, u = 5, s = 153, w = 2, B = 274277, C = -38;
  const f1 = julianDay + j;
  const f = useJulianRef ? f1 : f1 + tdiv(tdiv(4 * julianDay + B, 146097) * 3, 4) + C;
  const e = r * f + v;
  const remainder = (num, den) => { const x = num % den; return x >= 0 ? x : x + den; };
  const floorDivide = (num, den) => (num >= 0 ? tdiv(num, den) : tdiv(num + 1, den) - 1);
  const g = tdiv(remainder(e, p), r);
  const h = u * g + w;
  const day = floorDivide(h % s, u) + 1;
  const month = ((floorDivide(h, s) + m) % n) + 1;
  const year = floorDivide(e, p) - y + tdiv(n + m - month, n);
  return { year, month, day };
}

function gregorianDate(year, month, day, hour, minute, second) {
  // date(from:): Gregorian first, then the Julian reference if before the cutover.
  let jd = julianDayOf(0, month, year, false) + day;
  if (jd < JULIAN_CUTOVER_DAY) jd = julianDayOf(0, month, year, true) + day;
  const unix = (jd - JULIAN_DAY_AT_1970) * 86400 + hour * 3600 + minute * 60 + second;

  // isValidDate: read the date back and compare every component given.
  const back = yearMonthDayFromJulianDay(JULIAN_DAY_AT_1970 + Math.floor(unix / 86400), unix < GREGORIAN_START);
  const backYear = back.year < 1 ? 1 - back.year : back.year;   // era years: 0 reads back as 1 BC
  const inDay = ((unix % 86400) + 86400) % 86400;
  if (backYear !== year || back.month !== month || back.day !== day) return null;
  if (Math.floor(inDay / 3600) !== hour || Math.floor((inDay % 3600) / 60) !== minute || inDay % 60 !== second) return null;
  return unix;
}

// ---------------------------------------------------------------- ECDSA

/**
 * ECDSA on whichever NIST curve the certificate's key is (Swift
 * ecdsaVerifies). The Swift reads the key with
 * P384/P256/P521.Signing.PublicKey(derRepresentation:), which parses the
 * SubjectPublicKeyInfo as strict DER and takes the BIT STRING as an x9.63
 * point; the point's length picks the curve (97 bytes P-384, 65 P-256, 133
 * P-521). Like swift-crypto, the algorithm and curve OIDs are not checked.
 * In practice this only ever sees a pinned certificate, whose bytes the pin
 * fixes, so this parse only has to agree with the Swift on that one key.
 *
 * The Swift verifies a digest it computed, `isValidSignature(sig, for:
 * SHA384.hash(data: message))`. WebCrypto's verify with `hash` hashes the
 * message itself with that hash and then runs the same ECDSA check (with
 * the same truncation when the hash is longer than the curve, as SHA-512 on
 * P-384 is), so passing the message and the hash name is the equivalent
 * call.
 */
async function ecdsaVerifies(spki, signature, message, hash) {
  const point = spkiPoint(spki);
  if (!point || point[0] !== 0x04) return false;
  if (point.length === 97) return verifyECDSA("P-384", point, signature, message, hash);
  if (point.length === 65) return verifyECDSA("P-256", point, signature, message, hash);
  if (point.length === 133) return verifyP521(point, signature, message, hash);
  return false;
}

/**
 * The Swift also accepts a P-521 key (line 236). ecdsa.js knows only P-256
 * and P-384, so this is the same call for P-521, built from its derToRaw
 * (66-byte numbers) and WebCrypto. Nothing FreeTSA sends uses it today.
 */
async function verifyP521(point, signature, message, hash) {
  const raw = derToRaw(signature, 66);
  if (!raw) return false;
  try {
    const key = await subtle.importKey("raw", point, { name: "ECDSA", namedCurve: "P-521" }, false, ["verify"]);
    return await subtle.verify({ name: "ECDSA", hash }, key, raw, message);
  } catch {
    return false;
  }
}

/**
 * SubjectPublicKeyInfo ::= SEQUENCE { algorithm AlgorithmIdentifier,
 * subjectPublicKey BIT STRING }, read as swift-crypto's ASN1.parse does:
 * DER lengths in their shortest form, no indefinite lengths, nothing
 * trailing, every constructed node fully parsed, at most 10 deep. The BIT
 * STRING must start with 0 unused bits. Returns the key bytes after that.
 */
function spkiPoint(spki) {
  const root = strictNode(spki, 0, spki.length, 1);
  if (!root || root.end !== spki.length || root.tag !== 0x30) return null;
  const parts = root.children;
  if (parts.length !== 2) return null;
  const [alg, key] = parts;
  if (alg.tag !== 0x30 || alg.children.length < 1 || alg.children.length > 2) return null;
  if (alg.children[0].tag !== 0x06 || !validOID(spki.subarray(alg.children[0].valueStart, alg.children[0].end))) return null;
  if (key.tag !== 0x03 || key.end - key.valueStart < 1 || spki[key.valueStart] !== 0x00) return null;
  return spki.subarray(key.valueStart + 1, key.end);
}

function strictNode(b, start, end, depth) {
  if (depth > 10 || start >= end) return null;
  const tag = b[start];
  if ((tag & 0x1f) === 0x1f) return null;
  let i = start + 1;
  if (i >= end) return null;
  const first = b[i++];
  let length;
  if (first === 0x80) return null;
  if (first & 0x80) {
    const count = first & 0x7f;
    if (count > end - i || count > 8) return null;
    length = 0;
    for (let k = 0; k < count; k++) length = length * 256 + b[i++];
    if (length < 0x80) return null;                   // the short form was required
    let needed = 0;
    for (let rest = length; rest > 0; rest = Math.floor(rest / 256)) needed++;
    if (count > needed) return null;                  // not the fewest bytes
  } else {
    length = first;
  }
  if (length > end - i) return null;
  const node = { tag, valueStart: i, end: i + length, children: [] };
  if (tag & 0x20) {
    let at = i;
    while (at < node.end) {
      const child = strictNode(b, at, node.end, depth + 1);
      if (!child) return null;
      node.children.push(child);
      at = child.end;
    }
  }
  return node;
}

/**
 * swift-crypto's ASN1ObjectIdentifier: every subidentifier ends, none is
 * over 9 bytes (it must fit a 64-bit UInt), and there are at least two.
 */
function validOID(content) {
  if (content.length === 0 || content[content.length - 1] & 0x80) return false;
  let count = 0;
  let run = 0;
  for (const byte of content) {
    run++;
    if (run > 9) return false;
    if ((byte & 0x80) === 0) { count++; run = 0; }
  }
  return count >= 2;
}
