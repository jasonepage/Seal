// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  identity.js
//
//  Which devices did this person really endorse? This answers that on the
//  recipient page, the same way the app does. It is a line by line port of:
//
//    Seal/Crypto/WebAuthnParsing.swift    WebAuthnAssertion: verify, contextViolations
//    Seal/Ceremony/CeremonyManager.swift  relyingPartyID, clientDataChallengeMatches
//    Seal/Identity/IdentityManager.swift  endorsement commitments (v3, v2), authorityKeys,
//                                         verifiedBackups, verifiedDevices, revocations
//    Seal/Identity/BackupCredential.swift commitments and verified(_:root:revokedPublicKeys:)
//    Seal/Sync/SyncEngine.swift           fetchIdentity, minus the network and key pins
//    Seal/Models/Models.swift             RootIdentity, DeviceEndorsement, DeviceRevocation
//
//  The directory is untrusted (SDS section 7). Anything that does not parse
//  or does not verify is dropped, never guessed at. Decoding is as strict as
//  Swift's JSONDecoder: a required field that is missing, null, or of the
//  wrong type fails that item; unknown keys are ignored; Data is standard
//  base64 with padding; a Date is seconds since 2001-01-01.
//
//  Key pinning (KeyPinStore) is NOT here. The caller does it.
//
//  Only WebCrypto, through bytes.js and ecdsa.js. A browser and Node 22 both
//  run this unchanged.

import {
  utf8, fromUtf8, fromB64, toB64url, toHex, concat, same, framed, sha256, appleDateToUnix,
} from "./bytes.js";
import { verifyP256 } from "./ecdsa.js";

// ---------------------------------------------------------------- constants

/** CeremonyManager.relyingPartyID. */
export const RELYING_PARTY_ID = "sealmessenger.com";
/** SyncEngine.deletedTier: a tombstoned identity reads as not found. */
export const DELETED_TIER = "deleted";
/** IdentityTier raw values. */
export const TIERS = Object.freeze(["verified", "passkey"]);
/** IdentityManager.legacyV2DeviceKeyLength and legacyV2KEMKeyLength. */
export const LEGACY_V2_DEVICE_KEY_LENGTH = 65; // x963: 0x04 ‖ x ‖ y
export const LEGACY_V2_KEM_KEY_LENGTH = 32;    // raw X25519

const RP_ID_HASH = sha256(utf8(RELYING_PARTY_ID)); // a promise, awaited where used

// ---------------------------------------------------------------- small rules

const isBytes = (v) => v instanceof Uint8Array;
const isPlainObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

/**
 * Swift's `String ==`, which compares by canonical equivalence, not by code
 * units. So "K" (Kelvin sign) equals "K" in Swift. Both sides are
 * normalized here so the page agrees with the app on every string the app
 * compares this way (challenge, clientData.type, tier).
 */
const swiftStringEquals = (a, b) => a.normalize("NFC") === b.normalize("NFC");

/** `IdentityTier(rawValue:)`: the canonical raw value, or null. */
function tierFromRaw(raw) {
  if (typeof raw !== "string") return null;
  return TIERS.find((t) => swiftStringEquals(t, raw)) ?? null;
}

/**
 * `try? P256.Signing.PublicKey(rawRepresentation:)` succeeds: exactly 64
 * bytes (x ‖ y) and a real point on the curve. WebCrypto checks the point.
 */
async function isRawP256(pub) {
  if (!isBytes(pub) || pub.length !== 64) return false;
  try {
    await globalThis.crypto.subtle.importKey(
      "raw", concat(Uint8Array.of(0x04), pub), { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    return true;
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------- strict JSON decoding

const LONE_SURROGATE = /[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]/;
const wellFormed = (s) => (typeof s.isWellFormed === "function" ? s.isWellFormed() : !LONE_SURROGATE.test(s));

/**
 * JSON.parse accepts "\ud800" (half of a character). Swift's parsers do
 * not, so any string, key or value, holding one fails the whole parse.
 */
function assertWellFormed(v) {
  if (typeof v === "string") {
    if (!wellFormed(v)) throw new Error("unpaired surrogate");
  } else if (Array.isArray(v)) {
    v.forEach(assertWellFormed);
  } else if (v !== null && typeof v === "object") {
    for (const [k, x] of Object.entries(v)) { assertWellFormed(k); assertWellFormed(x); }
  }
}

/** JSONDecoder input: strict UTF-8, then JSON. Throws on either failing. */
function parseJSONBytes(bytes) {
  if (!isBytes(bytes)) throw new TypeError("not bytes");
  const value = JSON.parse(fromUtf8(bytes));
  assertWellFormed(value);
  return value;
}

const own = (o, k) => (Object.hasOwn(o, k) ? o[k] : undefined);

/** A required `Data` field: a base64 string. Missing, null or another type throws. */
function reqData(o, k) {
  const v = own(o, k);
  if (typeof v !== "string") throw new Error(`${k}: expected base64 string`);
  return fromB64(v);
}
/** An optional `Data?` field: absent or null is null, anything else must be base64. */
function optData(o, k) {
  const v = own(o, k);
  if (v === undefined || v === null) return null;
  if (typeof v !== "string") throw new Error(`${k}: expected base64 string`);
  return fromB64(v);
}
/** A required `Date`: a finite JSON number of seconds since 2001, returned as unix seconds. */
function reqDate(o, k) {
  const v = own(o, k);
  if (typeof v !== "number" || !Number.isFinite(v)) throw new Error(`${k}: expected number`);
  return appleDateToUnix(v);
}
function reqString(o, k) {
  const v = own(o, k);
  if (typeof v !== "string") throw new Error(`${k}: expected string`);
  return v;
}
function reqObject(v) {
  if (!isPlainObject(v)) throw new Error("expected object");
  return v;
}
function reqArray(v) {
  if (!Array.isArray(v)) throw new Error("expected array");
  return v;
}

function decodeAssertion(o) {
  reqObject(o);
  return {
    credentialID: reqData(o, "credentialID"),
    clientDataJSON: reqData(o, "clientDataJSON"),
    authenticatorData: reqData(o, "authenticatorData"),
    signature: reqData(o, "signature"),
  };
}

function decodeEndorsement(o) {
  reqObject(o);
  // A stale unsigned "revokedAt" key is ignored like any unknown key
  // (security fix 3: the field is gone from the type).
  return {
    devicePublicKey: reqData(o, "devicePublicKey"),
    kemBundlePublicKeys: reqData(o, "kemBundlePublicKeys"),
    assertion: reqData(o, "assertion"),
    createdAt: reqDate(o, "createdAt"),
    lockedPrivate: optData(o, "lockedPrivate"),
    prfSalt: optData(o, "prfSalt"),
  };
}

function decodeRevocation(o) {
  reqObject(o);
  return {
    devicePublicKey: reqData(o, "devicePublicKey"),
    assertion: reqData(o, "assertion"),
    revokedAt: reqDate(o, "revokedAt"),
  };
}

function decodeBackup(o) {
  reqObject(o);
  const tier = tierFromRaw(own(o, "tier"));
  const credentialID = reqData(o, "credentialID");
  const publicKey = reqData(o, "publicKey");
  if (tier === null) throw new Error("tier: not an IdentityTier");
  return {
    credentialID,
    publicKey,
    tier,
    label: reqString(o, "label"),
    assertion: reqData(o, "assertion"),
    acceptance: reqData(o, "acceptance"),
    createdAt: reqDate(o, "createdAt"),
  };
}

/** `try? JSONDecoder().decode(T.self, from:)`: the value, or null. */
function tryDecode(bytes, decode) {
  try { return decode(parseJSONBytes(bytes)); } catch { return null; }
}
/** `try? JSONDecoder().decode([T].self, from:)`: one bad element fails the WHOLE array. */
function tryDecodeArray(bytes, decode) {
  try { return reqArray(parseJSONBytes(bytes)).map(decode); } catch { return null; }
}

/** WebAuthnAssertion JSON bytes to { credentialID, clientDataJSON, authenticatorData, signature }, or null. */
export const parseAssertion = (bytes) => tryDecode(bytes, decodeAssertion);
/** [DeviceEndorsement] JSON bytes, all or nothing, or null. */
export const parseDeviceEndorsements = (bytes) => tryDecodeArray(bytes, decodeEndorsement);
/** One DeviceRevocation JSON, or null. */
export const parseDeviceRevocation = (bytes) => tryDecode(bytes, decodeRevocation);
/** [DeviceRevocation] JSON bytes, all or nothing, or null. */
export const parseDeviceRevocations = (bytes) => tryDecodeArray(bytes, decodeRevocation);
/** [BackupCredential] JSON bytes, all or nothing, or null. */
export const parseBackupCredentials = (bytes) => tryDecodeArray(bytes, decodeBackup);

const isAssertion = (a) => isPlainObject(a)
  && isBytes(a.credentialID) && isBytes(a.clientDataJSON) && isBytes(a.authenticatorData) && isBytes(a.signature);

// ---------------------------------------------------------------- WebAuthn

/** clientDataJSON as `JSONSerialization.jsonObject(with:) as? [String: Any]`, or null. */
function clientDataObject(clientDataJSON) {
  try {
    const obj = parseJSONBytes(clientDataJSON);
    return isPlainObject(obj) ? obj : null;
  } catch {
    return null;
  }
}

/**
 * WebAuthnAssertion.contextViolations: what a signature alone does not prove.
 * rpIdHash must be SHA256(RP ID), User Present must be set, and
 * clientData.type must be "webauthn.get". User Verified only when asked.
 * An empty list means the context is fine.
 */
export async function contextViolations(assertion, { requireUserVerification = false } = {}) {
  if (!isAssertion(assertion)) return ["not an assertion"];
  const ad = assertion.authenticatorData;
  if (ad.length < 37) return [`authenticatorData too short (${ad.length} bytes)`];
  const problems = [];
  if (!same(ad.subarray(0, 32), await RP_ID_HASH)) {
    problems.push(`rpIdHash is not SHA256 of ${RELYING_PARTY_ID}`);
  }
  const flags = ad[32];
  if ((flags & 0x01) === 0) problems.push("User Present flag unset");
  if (requireUserVerification && (flags & 0x04) === 0) problems.push("User Verified flag unset");
  const obj = clientDataObject(assertion.clientDataJSON);
  if (obj) {
    const type = own(obj, "type");
    if (typeof type !== "string") problems.push("clientData.type missing");
    else if (!swiftStringEquals(type, "webauthn.get")) problems.push(`clientData.type is ${type}, not webauthn.get`);
  } else {
    problems.push("clientDataJSON did not parse as JSON");
  }
  return problems;
}

/**
 * WebAuthnAssertion.verify(with:requireUserVerification:), with
 * enforceContextChecks = true. The DER ECDSA P-256 signature must be valid
 * over authenticatorData ‖ SHA256(clientDataJSON) AND the context checks
 * must pass. `publicKeyRaw64` is a raw x ‖ y key, as RootIdentity and
 * BackupCredential store it; any other length is refused.
 */
export async function verifyAssertion(assertion, publicKeyRaw64, { requireUserVerification = false } = {}) {
  if (!isAssertion(assertion) || !isBytes(publicKeyRaw64) || publicKeyRaw64.length !== 64) return false;
  const signed = concat(assertion.authenticatorData, await sha256(assertion.clientDataJSON));
  if (!(await verifyP256(publicKeyRaw64, assertion.signature, signed))) return false;
  return (await contextViolations(assertion, { requireUserVerification })).length === 0;
}

/**
 * CeremonyManager.clientDataChallengeMatches: clientDataJSON's "challenge"
 * string equals base64url of `expectedBytes`, no padding (Hex.swift:
 * standard base64, "+" to "-", "/" to "_", every "=" removed).
 */
export function clientDataChallengeMatches(clientDataJSONBytes, expectedBytes) {
  if (!isBytes(expectedBytes)) return false;
  const obj = clientDataObject(clientDataJSONBytes);
  if (!obj) return false;
  const challenge = own(obj, "challenge");
  if (typeof challenge !== "string") return false;
  return swiftStringEquals(challenge, toB64url(expectedBytes));
}

// ---------------------------------------------------------------- commitments

/** IdentityManager.endorsementCommitment: v3, length framed. */
export async function endorsementCommitment(devicePublicKey, kemBundlePublicKeys) {
  return sha256(framed("seal.endorse.v3", [devicePublicKey, kemBundlePublicKeys]));
}

/** IdentityManager.legacyV2ShapeIsCanonical: the only shape where v2 has one reading. */
export function legacyV2ShapeIsCanonical(devicePublicKey, kemBundlePublicKeys) {
  return devicePublicKey.length === LEGACY_V2_DEVICE_KEY_LENGTH
    && kemBundlePublicKeys.length === LEGACY_V2_KEM_KEY_LENGTH;
}

/** IdentityManager.legacyEndorsementCommitmentV2: unframed, accepted only in canonical shape. */
export async function legacyEndorsementCommitmentV2(devicePublicKey, kemBundlePublicKeys) {
  return sha256(concat(utf8("seal.endorse.v2"), devicePublicKey, kemBundlePublicKeys));
}

/** The device revocation commitment: SHA256("seal.revoke.v1" ‖ device key). */
export async function deviceRevocationCommitment(devicePublicKey) {
  return sha256(concat(utf8("seal.revoke.v1"), devicePublicKey));
}

/** BackupCredential.endorsementCommitment: what the ROOT signs to authorise a backup. */
export async function backupEndorsementCommitment(credentialID, publicKey) {
  return sha256(concat(utf8("seal.backup.v1"), credentialID, publicKey));
}

/** BackupCredential.acceptanceCommitment: what the BACKUP signs to accept this root. */
export async function backupAcceptanceCommitment(rootIDHash, credentialID, publicKey) {
  return sha256(concat(utf8("seal.backup.accept.v1"), utf8(rootIDHash), credentialID, publicKey));
}

/** BackupCredential.revocationCommitment: what the ROOT signs to kill a backup. */
export async function backupRevocationCommitment(publicKey) {
  return sha256(concat(utf8("seal.backup.revoke.v1"), publicKey));
}

// ---------------------------------------------------------------- roots, backups, revocations

const rootIsUsable = (root) => isPlainObject(root) && isBytes(root.publicKey) && typeof root.credentialIDHash === "string";

/**
 * BackupCredential.verified(_:root:revokedPublicKeys:). The backups that
 * verify under `root` and are not revoked, same order. `revokedPublicKeysHex`
 * is a Set of lowercase hex public keys (see revokedBackupPublicKeys).
 */
export async function verifiedBackupCredentials(backups, root, revokedPublicKeysHex = new Set()) {
  if (!Array.isArray(backups) || !rootIsUsable(root) || !(await isRawP256(root.publicKey))) return [];
  const out = [];
  for (const backup of backups) {
    if (!isPlainObject(backup) || !isBytes(backup.publicKey) || !isBytes(backup.credentialID)) continue;
    if (revokedPublicKeysHex.has(toHex(backup.publicKey))) continue;
    // Fixed 64 byte raw P-256 key, asserted rather than assumed.
    if (backup.publicKey.length !== 64 || !(await isRawP256(backup.publicKey))) continue;
    const endorsement = parseAssertion(backup.assertion);
    const acceptance = parseAssertion(backup.acceptance);
    if (!endorsement || !acceptance) continue;
    // Half one: the ROOT authorised this credential.
    if (!(await verifyAssertion(endorsement, root.publicKey))
      || !clientDataChallengeMatches(endorsement.clientDataJSON,
        await backupEndorsementCommitment(backup.credentialID, backup.publicKey))) continue;
    // Half two: the CREDENTIAL accepted this root.
    if (await verifyAssertion(acceptance, backup.publicKey)
      && clientDataChallengeMatches(acceptance.clientDataJSON,
        await backupAcceptanceCommitment(root.credentialIDHash, backup.credentialID, backup.publicKey))) {
      out.push(backup);
    }
  }
  return out;
}

/** IdentityManager.verifiedBackups: re-check the root signature on every backup on `root`. */
export async function verifiedBackups(root) {
  const backups = isPlainObject(root) ? root.backupCredentials : null;
  if (!Array.isArray(backups) || backups.length === 0) return [];
  return verifiedBackupCredentials(backups, root, new Set());
}

/**
 * IdentityManager.authorityKeys: [{ credentialID: Uint8Array|null, publicKey }]
 * for the root, then each verified backup. Root's credentialID is null for
 * an identity registered before credential publishing.
 */
export async function authorityKeys(root) {
  const keys = [];
  if (!isPlainObject(root)) return keys;
  if (await isRawP256(root.publicKey)) {
    keys.push({ credentialID: isBytes(root.rawCredentialID) ? root.rawCredentialID : null, publicKey: root.publicKey });
  }
  for (const backup of await verifiedBackups(root)) {
    if (await isRawP256(backup.publicKey)) keys.push({ credentialID: backup.credentialID, publicKey: backup.publicKey });
  }
  return keys;
}

/** Shared body of the two revocation readers: only the ROOT key counts. */
async function revokedBy(root, revocations, commitmentFor) {
  const revoked = new Set();
  if (!isPlainObject(root) || !(await isRawP256(root.publicKey)) || !Array.isArray(revocations)) return revoked;
  for (const revocation of revocations) {
    if (!isPlainObject(revocation) || !isBytes(revocation.devicePublicKey)) continue;
    const assertion = parseAssertion(revocation.assertion);
    if (!assertion || !(await verifyAssertion(assertion, root.publicKey))) continue;
    if (clientDataChallengeMatches(assertion.clientDataJSON, await commitmentFor(revocation.devicePublicKey))) {
      revoked.add(toHex(revocation.devicePublicKey));
    }
  }
  return revoked;
}

/** IdentityManager.revokedDevicePublicKeys: Set of hex device keys with a valid root-signed revocation. */
export const revokedDevicePublicKeys = (root, revocations) => revokedBy(root, revocations, deviceRevocationCommitment);
/** IdentityManager.revokedBackupPublicKeys: Set of hex backup keys with a valid root-signed revocation. */
export const revokedBackupPublicKeys = (root, revocations) => revokedBy(root, revocations, backupRevocationCommitment);

// ---------------------------------------------------------------- the answer

/**
 * IdentityManager.verifiedDevices: the endorsements whose signature chain
 * back to `root` verifies, same order, everything else dropped. The signer
 * may be the root or any verified backup credential (FR-3).
 */
export async function verifiedDevices(root, endorsements) {
  const authorities = await authorityKeys(root);
  if (authorities.length === 0 || !Array.isArray(endorsements)) return [];
  const out = [];
  for (const e of endorsements) {
    if (!isPlainObject(e) || !isBytes(e.devicePublicKey) || !isBytes(e.kemBundlePublicKeys)) continue;
    const assertion = parseAssertion(e.assertion);
    if (!assertion) continue;
    // The commitment binds signing AND KEM keys. v3 is current; v2 only in
    // its one canonical shape (security fix 4).
    const v3 = await endorsementCommitment(e.devicePublicKey, e.kemBundlePublicKeys);
    const v2Shape = legacyV2ShapeIsCanonical(e.devicePublicKey, e.kemBundlePublicKeys);
    const v2 = await legacyEndorsementCommitmentV2(e.devicePublicKey, e.kemBundlePublicKeys);
    if (!(clientDataChallengeMatches(assertion.clientDataJSON, v3)
      || (v2Shape && clientDataChallengeMatches(assertion.clientDataJSON, v2)))) continue;
    // Prefer the authority the assertion names. FALL THROUGH on failure:
    // credentialID is not covered by the signature, so a directory that
    // flips it must not be able to get a good endorsement dropped.
    const named = authorities.find((a) => a.credentialID !== null && same(a.credentialID, assertion.credentialID));
    if (named && await verifyAssertion(assertion, named.publicKey)) { out.push(e); continue; }
    let any = false;
    for (const a of authorities) {
      if (await verifyAssertion(assertion, a.publicKey)) { any = true; break; }
    }
    if (any) out.push(e);
  }
  return out;
}

/**
 * SyncEngine.fetchIdentity, without CloudKit and without key pinning.
 *
 * Call as identityFromRecord(fields, sideRevocationPayloads, credentialIDHash).
 *
 * fields: the Identity record's CloudKit fields, already decoded to plain
 * values. A field of the wrong type is treated like Swift's failed `as?`.
 *   {
 *     publicKey:           Uint8Array  raw 64 byte P-256 root key (required)
 *     tier:                string      "verified" | "passkey"; "deleted" means tombstoned (required)
 *     displayName:         string      (required)
 *     deviceEndorsements:  Uint8Array  JSON of [DeviceEndorsement] (required, all or nothing)
 *     credentialID?:       Uint8Array  raw root credential ID
 *     revocations?:        Uint8Array  JSON of [DeviceRevocation] (all or nothing; bad means none)
 *     backupEndorsements?: Uint8Array  JSON of [BackupCredential] (all or nothing; bad means none)
 *   }
 *
 * sideRevocationPayloads: REQUIRED array of Uint8Array, the `payload` of
 * every GroupInvite record with recipient "revoke.<hash>", each one
 * DeviceRevocation JSON. Bad ones are skipped one by one. If they could not
 * be fetched, do not call this: a revocation that failed to load must not
 * read as "nothing revoked", so a missing array throws.
 *
 * credentialIDHash: REQUIRED string, the record name (lowercase hex SHA256
 * of the root credential ID). It goes on the root and into the backup
 * acceptance commitment, so pass the name you fetched, never one read
 * from inside the record.
 *
 * Returns { root, endorsements } or null (not found, deleted, or broken).
 *   root: { credentialIDHash, publicKey, tier, displayName, rawCredentialID,
 *           backupCredentials }  backupCredentials are verified and not
 *           revoked, or null when there are none.
 *   endorsements: [{ devicePublicKey, kemBundlePublicKeys, assertion,
 *           createdAt (unix seconds), lockedPrivate, prfSalt }]
 *
 * Like fetchIdentity, revoked devices are removed but the endorsements are
 * NOT yet verified. The caller must pin the root key, then pass both to
 * verifiedDevices before trusting any device.
 */
export async function identityFromRecord(fields, sideRevocationPayloads, credentialIDHash) {
  if (typeof credentialIDHash !== "string") throw new TypeError("credentialIDHash must be a string");
  if (!Array.isArray(sideRevocationPayloads)) throw new TypeError("sideRevocationPayloads must be an array");
  if (!isPlainObject(fields)) return null;
  const f = (k) => own(fields, k);

  // Tombstoned identities read as not found (FR-19).
  if (typeof f("tier") === "string" && swiftStringEquals(f("tier"), DELETED_TIER)) return null;
  const publicKey = f("publicKey");
  if (!isBytes(publicKey)) return null;
  // (KeyPinStore.enforce happens here in Swift. The caller does it.)
  const tier = tierFromRaw(f("tier"));
  const displayName = f("displayName");
  const endorsementData = f("deviceEndorsements");
  if (tier === null || typeof displayName !== "string" || !isBytes(endorsementData)) return null;
  const endorsements = parseDeviceEndorsements(endorsementData);
  if (endorsements === null) return null;

  const root = {
    credentialIDHash,
    publicKey,
    tier,
    displayName,
    rawCredentialID: isBytes(f("credentialID")) ? f("credentialID") : null,
    backupCredentials: null,
  };

  // One revocation list, two kinds of subject, told apart by domain string.
  let revocations = [];
  if (isBytes(f("revocations"))) revocations = parseDeviceRevocations(f("revocations")) ?? [];
  for (const payload of sideRevocationPayloads) {
    if (!isBytes(payload)) continue;
    const r = parseDeviceRevocation(payload);
    if (r) revocations.push(r);
  }

  // Backup credentials: checked against the root signature and the
  // revocation list here, once, for every consumer downstream.
  if (isBytes(f("backupEndorsements"))) {
    const decoded = parseBackupCredentials(f("backupEndorsements"));
    if (decoded !== null) {
      const revokedBackups = await revokedBackupPublicKeys(root, revocations);
      const live = await verifiedBackupCredentials(decoded, root, revokedBackups);
      root.backupCredentials = live.length === 0 ? null : live;
    }
  }

  // Filter out revoked devices before anyone trusts them (FR-19).
  const revokedDevices = await revokedDevicePublicKeys(root, revocations);
  const live = endorsements.filter((e) => !revokedDevices.has(toHex(e.devicePublicKey)));
  return { root, endorsements: live };
}
