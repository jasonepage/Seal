// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  identity.test.mjs
//
//  Tests for site/open/js/identity.js. A port of the cases in
//  Seal/SelfTest/SecurityFixTests.swift (fix 2, 3, 4) and the parts of
//  SponsoredKeyTests.swift that touch verifiedDevices, plus the backup
//  credential, revocation and record rules from IdentityManager.swift,
//  BackupCredential.swift and SyncEngine.fetchIdentity.
//
//  The software authenticator below is TestAuthenticator.swift in
//  JavaScript: byte exact WebAuthn assertions signed with WebCrypto P-256,
//  so the code under test is the same code that checks a real key.
//
//      node tools/webtests/identity.test.mjs

import {
  parseAssertion, verifyAssertion, contextViolations, clientDataChallengeMatches,
  endorsementCommitment, legacyEndorsementCommitmentV2, legacyV2ShapeIsCanonical,
  deviceRevocationCommitment, backupEndorsementCommitment, backupAcceptanceCommitment,
  backupRevocationCommitment, verifiedDevices, verifiedBackupCredentials, authorityKeys,
  revokedDevicePublicKeys, revokedBackupPublicKeys, identityFromRecord, parseDeviceEndorsements,
  RELYING_PARTY_ID,
} from "../../site/open/js/identity.js";
import { utf8, toB64, toB64url, toHex, concat, same, framed, sha256, APPLE_EPOCH } from "../../site/open/js/bytes.js";

const subtle = globalThis.crypto.subtle;

// ---------------------------------------------------------------- tiny harness

let checks = 0;
let failures = 0;
function check(ok, what) {
  checks++;
  if (!ok) { failures++; console.log(`FAIL: ${what}`); }
}
const equal = (a, b, what) => {
  const ok = a === b;
  check(ok, ok ? what : `${what} (got ${a}, want ${b})`);
};

// ---------------------------------------------------------------- software authenticator

/** WebCrypto raw r ‖ s to DER, as a security key or CryptoKit writes it. */
function rawToDer(raw) {
  const int = (b) => {
    let i = 0;
    while (i < b.length - 1 && b[i] === 0) i++;
    let v = b.subarray(i);
    if (v[0] & 0x80) v = concat(Uint8Array.of(0), v);
    return concat(Uint8Array.of(0x02, v.length), v);
  };
  const body = concat(int(raw.subarray(0, 32)), int(raw.subarray(32)));
  return concat(Uint8Array.of(0x30, body.length), body);
}

const randomBytes = (n) => globalThis.crypto.getRandomValues(new Uint8Array(n));

async function newP256() {
  const pair = await subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const x963 = new Uint8Array(await subtle.exportKey("raw", pair.publicKey));
  return { privateKey: pair.privateKey, x963, raw: x963.subarray(1) };
}

/** Swift's JSONEncoder: Data as base64, Date as seconds since 2001. */
const jsonBytes = (o) => utf8(JSON.stringify(o));
const appleSeconds = (unix) => unix - APPLE_EPOCH;

/** Swift JSONSerialization with .sortedKeys. */
const sortedJSON = (o) => utf8(JSON.stringify(Object.fromEntries(Object.entries(o).sort(([a], [b]) => (a < b ? -1 : 1)))));

class TestAuthenticator {
  static async make(credentialID = randomBytes(16)) {
    const a = new TestAuthenticator();
    a.key = await newP256();
    a.credentialID = credentialID;
    a.publicKeyData = a.key.raw;
    a.credentialIDHash = toHex(await sha256(credentialID));
    return a;
  }

  get rootIdentity() {
    return {
      credentialIDHash: this.credentialIDHash,
      publicKey: this.publicKeyData,
      tier: "verified",
      displayName: `Test ${this.credentialIDHash.slice(0, 4)}`,
      rawCredentialID: this.credentialID,
      backupCredentials: null,
    };
  }

  /** An assertion object, like WebAuthnAssertion. */
  async assertion(challenge, { relyingPartyID = RELYING_PARTY_ID, userPresent = true, userVerified = false, type = "webauthn.get" } = {}) {
    let flags = 0;
    if (userPresent) flags |= 0x01;
    if (userVerified) flags |= 0x04;
    const authenticatorData = concat(await sha256(utf8(relyingPartyID)), Uint8Array.of(flags), Uint8Array.of(0, 0, 0, 1));
    const clientDataJSON = sortedJSON({ type, challenge: toB64url(challenge), origin: `https://${relyingPartyID}` });
    const signed = concat(authenticatorData, await sha256(clientDataJSON));
    const raw = new Uint8Array(await subtle.sign({ name: "ECDSA", hash: "SHA-256" }, this.key.privateKey, signed));
    return { credentialID: this.credentialID, clientDataJSON, authenticatorData, signature: rawToDer(raw) };
  }

  /** WebAuthnAssertion as Swift's JSONEncoder stores it. */
  async assertionBytes(challenge, options) {
    return encodeAssertion(await this.assertion(challenge, options));
  }

  /** A DeviceEndorsement object, the way registration makes one. */
  async endorse(device, kem, { legacyV2 = false } = {}) {
    const commitment = legacyV2
      ? await legacyEndorsementCommitmentV2(device.x963, kem)
      : await endorsementCommitment(device.x963, kem);
    return {
      devicePublicKey: device.x963,
      kemBundlePublicKeys: kem,
      assertion: await this.assertionBytes(commitment),
      createdAt: 1_700_000_000,
      lockedPrivate: null,
      prfSalt: null,
    };
  }

  async revoke(devicePublicKey) {
    return {
      devicePublicKey,
      assertion: await this.assertionBytes(await deviceRevocationCommitment(devicePublicKey)),
      revokedAt: 1_700_000_100,
    };
  }

  async revokeBackup(publicKey) {
    return {
      devicePublicKey: publicKey,
      assertion: await this.assertionBytes(await backupRevocationCommitment(publicKey)),
      revokedAt: 1_700_000_200,
    };
  }
}

const encodeAssertion = (a) => jsonBytes({
  credentialID: toB64(a.credentialID),
  clientDataJSON: toB64(a.clientDataJSON),
  authenticatorData: toB64(a.authenticatorData),
  signature: toB64(a.signature),
});

const endorsementJSON = (e) => {
  const o = {
    devicePublicKey: toB64(e.devicePublicKey),
    kemBundlePublicKeys: toB64(e.kemBundlePublicKeys),
    assertion: toB64(e.assertion),
    createdAt: appleSeconds(e.createdAt),
  };
  if (e.lockedPrivate) o.lockedPrivate = toB64(e.lockedPrivate);
  if (e.prfSalt) o.prfSalt = toB64(e.prfSalt);
  return o;
};
const revocationJSON = (r) => ({
  devicePublicKey: toB64(r.devicePublicKey), assertion: toB64(r.assertion), revokedAt: appleSeconds(r.revokedAt),
});

/** A backup credential for `root`, signed both ways, as BackupCredential is made. */
async function makeBackup(root, backup, { rootIDHash = root.credentialIDHash, signAcceptanceWith = backup } = {}) {
  const assertion = await root.assertionBytes(await backupEndorsementCommitment(backup.credentialID, backup.publicKeyData));
  const acceptance = await signAcceptanceWith.assertionBytes(
    await backupAcceptanceCommitment(rootIDHash, backup.credentialID, backup.publicKeyData));
  return {
    credentialID: backup.credentialID,
    publicKey: backup.publicKeyData,
    tier: "passkey",
    label: "Backup in the safe",
    assertion,
    acceptance,
    createdAt: 1_700_000_050,
  };
}
const backupJSON = (b) => ({
  credentialID: toB64(b.credentialID),
  publicKey: toB64(b.publicKey),
  tier: b.tier,
  label: b.label,
  assertion: toB64(b.assertion),
  acceptance: toB64(b.acceptance),
  createdAt: appleSeconds(b.createdAt),
});

const kem32 = () => randomBytes(32);

// ---------------------------------------------------------------- fix 2: WebAuthn context

async function webAuthnContext() {
  const key = await TestAuthenticator.make();
  const other = await TestAuthenticator.make();
  const challenge = await sha256(utf8("hello"));

  check(await verifyAssertion(await key.assertion(challenge), key.publicKeyData), "a well formed assertion verifies");
  check(!(await verifyAssertion(await key.assertion(challenge), other.publicKeyData)), "wrong key is refused");
  check(!(await verifyAssertion(await key.assertion(challenge, { relyingPartyID: "evil.example" }), key.publicKeyData)),
    "a signature made for another relying party is refused");
  check(!(await verifyAssertion(await key.assertion(challenge, { userPresent: false }), key.publicKeyData)),
    "an assertion with no user presence is refused");
  check(!(await verifyAssertion(await key.assertion(challenge, { type: "webauthn.create" }), key.publicKeyData)),
    "a registration signature is not accepted as an assertion");
  check(!(await verifyAssertion(await key.assertion(challenge), key.publicKeyData, { requireUserVerification: true })),
    "UV required and unset is refused");
  check(await verifyAssertion(await key.assertion(challenge, { userVerified: true }), key.publicKeyData, { requireUserVerification: true }),
    "UV required and set verifies");

  // Tampering.
  const good = await key.assertion(challenge);
  const sig = good.signature.slice(); sig[sig.length - 1] ^= 0x01;
  check(!(await verifyAssertion({ ...good, signature: sig }, key.publicKeyData)), "a tampered signature is refused");
  const ad = good.authenticatorData.slice(); ad[36] ^= 0x01;
  check(!(await verifyAssertion({ ...good, authenticatorData: ad }, key.publicKeyData)), "tampered authenticatorData is refused");
  const cd = concat(good.clientDataJSON.subarray(0, -1), utf8(" }"));
  check(!(await verifyAssertion({ ...good, clientDataJSON: cd }, key.publicKeyData)), "tampered clientDataJSON is refused");
  check(!(await verifyAssertion({ ...good, signature: new Uint8Array(64) }, key.publicKeyData)), "a non DER signature is refused");
  check(!(await verifyAssertion(good, key.key.x963)), "a 65 byte key is not a raw root key");
  check(!(await verifyAssertion(null, key.publicKeyData)), "null assertion is refused");

  // contextViolations details.
  const short = { ...good, authenticatorData: good.authenticatorData.subarray(0, 36) };
  const v = await contextViolations(short);
  check(v.length === 1 && v[0].includes("too short"), "short authenticatorData is one violation");
  check((await contextViolations(good)).length === 0, "a good assertion has no violations");

  // A signature valid over a missing type is still refused. Build clientData by hand.
  async function customClientData(obj) {
    const authenticatorData = concat(await sha256(utf8(RELYING_PARTY_ID)), Uint8Array.of(1), Uint8Array.of(0, 0, 0, 1));
    const clientDataJSON = typeof obj === "string" ? utf8(obj) : sortedJSON(obj);
    const signed = concat(authenticatorData, await sha256(clientDataJSON));
    const raw = new Uint8Array(await subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key.key.privateKey, signed));
    return { credentialID: key.credentialID, clientDataJSON, authenticatorData, signature: rawToDer(raw) };
  }
  check(!(await verifyAssertion(await customClientData({ challenge: toB64url(challenge) }), key.publicKeyData)),
    "clientData with no type is refused");
  check(!(await verifyAssertion(await customClientData({ type: 7, challenge: "x" }), key.publicKeyData)),
    "clientData with a non string type is refused");
  check(!(await verifyAssertion(await customClientData("[1,2]"), key.publicKeyData)), "clientData that is not an object is refused");
  check(!(await verifyAssertion(await customClientData("{not json"), key.publicKeyData)), "clientData that is not JSON is refused");

  // parseAssertion is strict.
  const bytes = encodeAssertion(good);
  const parsed = parseAssertion(bytes);
  check(parsed && same(parsed.signature, good.signature) && same(parsed.credentialID, good.credentialID), "parseAssertion round trips");
  const withExtra = jsonBytes({ ...JSON.parse(new TextDecoder().decode(bytes)), extra: 1 });
  check(parseAssertion(withExtra) !== null, "unknown keys are ignored");
  const missing = JSON.parse(new TextDecoder().decode(bytes)); delete missing.signature;
  check(parseAssertion(jsonBytes(missing)) === null, "a missing field fails the decode");
  const wrongType = JSON.parse(new TextDecoder().decode(bytes)); wrongType.signature = 5;
  check(parseAssertion(jsonBytes(wrongType)) === null, "a field of the wrong type fails the decode");
  const nulled = JSON.parse(new TextDecoder().decode(bytes)); nulled.credentialID = null;
  check(parseAssertion(jsonBytes(nulled)) === null, "null for a required field fails the decode");
  const badB64 = JSON.parse(new TextDecoder().decode(bytes)); badB64.signature = "abc";
  check(parseAssertion(jsonBytes(badB64)) === null, "base64 without padding fails the decode");
  const urlB64 = JSON.parse(new TextDecoder().decode(bytes)); urlB64.signature = toB64url(good.signature);
  if (/[-_]/.test(urlB64.signature) || urlB64.signature.length % 4) check(parseAssertion(jsonBytes(urlB64)) === null, "base64url is not standard base64");
  check(parseAssertion(utf8("[]")) === null, "an array is not an assertion");
  check(parseAssertion(Uint8Array.of(0xff, 0xfe)) === null, "bad UTF-8 fails the decode");
  check(parseAssertion(utf8('{"credentialID":"","clientDataJSON":"","authenticatorData":"","signature":"","x":"\\ud800"}')) === null,
    "an unpaired surrogate anywhere fails the parse, as in Foundation");
}

// ---------------------------------------------------------------- challenge matching

async function challengeMatching() {
  const expected = Uint8Array.of(0xfb, 0xff, 0xfe, 0x01);   // base64 has + and / and padding
  equal(toB64(expected), "+//+AQ==", "fixture uses the characters that differ");
  const cd = (challenge) => utf8(JSON.stringify({ type: "webauthn.get", challenge }));
  check(clientDataChallengeMatches(cd("-__-AQ"), expected), "base64url without padding matches");
  check(!clientDataChallengeMatches(cd("-__-AQ=="), expected), "padded base64url does not match");
  check(!clientDataChallengeMatches(cd("+//+AQ=="), expected), "standard base64 does not match");
  check(!clientDataChallengeMatches(cd("-__-AA"), expected), "a different challenge does not match");
  check(!clientDataChallengeMatches(utf8('{"challenge":5}'), expected), "a non string challenge does not match");
  check(!clientDataChallengeMatches(utf8("not json"), expected), "non JSON does not match");
  check(!clientDataChallengeMatches(utf8('"-__-AQ"'), expected), "a JSON string at the top does not match");
}

// ---------------------------------------------------------------- fix 3: unsigned revokedAt, revocations

async function revocations() {
  const root = await TestAuthenticator.make();
  const device = await newP256();
  const endorsement = await root.endorse(device, kem32());

  // The attack: a directory writer sets revokedAt on the blob. Unknown key, ignored.
  const tamperedJSON = jsonBytes([{ ...endorsementJSON(endorsement), revokedAt: 1_700_000_500 }]);
  const tampered = parseDeviceEndorsements(tamperedJSON);
  check(tampered !== null && tampered.length === 1, "an endorsement with a stray revokedAt still decodes");
  equal((await verifiedDevices(root.rootIdentity, tampered)).length, 1, "an unsigned revokedAt field cannot un-verify a device");

  const revoked = await revokedDevicePublicKeys(root.rootIdentity, [await root.revoke(endorsement.devicePublicKey)]);
  check(revoked.has(toHex(endorsement.devicePublicKey)), "a root-signed revocation is honoured");

  const stranger = await TestAuthenticator.make();
  const forged = await revokedDevicePublicKeys(root.rootIdentity, [await stranger.revoke(endorsement.devicePublicKey)]);
  check(forged.size === 0, "a revocation signed by some other key is ignored");

  // Root-signed, but committing to a different device.
  const otherDevice = await newP256();
  const mismatch = { ...(await root.revoke(otherDevice.x963)), devicePublicKey: endorsement.devicePublicKey };
  check((await revokedDevicePublicKeys(root.rootIdentity, [mismatch])).size === 0, "a revocation for another device kills nothing");

  // A backup revocation does not kill a device, and a device revocation does not kill a backup.
  const crossed = await root.revokeBackup(endorsement.devicePublicKey);
  check((await revokedDevicePublicKeys(root.rootIdentity, [crossed])).size === 0, "a backup revocation cannot stand in for a device one");
  const crossed2 = await root.revoke(endorsement.devicePublicKey);
  check((await revokedBackupPublicKeys(root.rootIdentity, [crossed2])).size === 0, "a device revocation cannot stand in for a backup one");

  // A revocation with no user presence is refused (verify includes context).
  const noUP = {
    devicePublicKey: endorsement.devicePublicKey,
    assertion: await root.assertionBytes(await deviceRevocationCommitment(endorsement.devicePublicKey), { userPresent: false }),
    revokedAt: 0,
  };
  check((await revokedDevicePublicKeys(root.rootIdentity, [noUP])).size === 0, "a revocation with no tap is ignored");
}

// ---------------------------------------------------------------- fix 4: endorsement framing

async function endorsementFraming() {
  const root = await TestAuthenticator.make();
  const device = await newP256();
  const kem = kem32();
  const devicePub = device.x963;

  // Pin the exact byte layout too, not just self consistency.
  const v3Expected = await sha256(concat(utf8("seal.endorse.v3"),
    Uint8Array.of(0, 0, 0, 65), devicePub, Uint8Array.of(0, 0, 0, 32), kem));
  check(same(await endorsementCommitment(devicePub, kem), v3Expected), "v3 is SHA256(domain ‖ u32be len ‖ D ‖ u32be len ‖ K)");
  check(same(v3Expected, await sha256(framed("seal.endorse.v3", [devicePub, kem]))), "and matches bytes.js framed");
  check(same(await legacyEndorsementCommitmentV2(devicePub, kem), await sha256(concat(utf8("seal.endorse.v2"), devicePub, kem))),
    "v2 is SHA256(domain ‖ D ‖ K)");

  const honest = await endorsementCommitment(devicePub, kem);
  const shifted = await endorsementCommitment(concat(devicePub, kem.subarray(0, 1)), kem.subarray(1));
  check(!same(honest, shifted), "v3 framing: re-splitting the bytes changes the commitment");

  const v2Honest = await legacyEndorsementCommitmentV2(devicePub, kem);
  const v2Shifted = await legacyEndorsementCommitmentV2(concat(devicePub, kem.subarray(0, 1)), kem.subarray(1));
  check(same(v2Honest, v2Shifted), "v2 has the collision this fix exists for");

  check(legacyV2ShapeIsCanonical(devicePub, kem), "65 and 32 is the canonical v2 shape");
  check(!legacyV2ShapeIsCanonical(concat(devicePub, kem.subarray(0, 1)), kem.subarray(1)), "66 and 31 is not");
  check(!legacyV2ShapeIsCanonical(device.raw, kem), "64 and 32 is not");

  const legacy = await root.endorse(device, kem, { legacyV2: true });
  equal((await verifiedDevices(root.rootIdentity, [legacy])).length, 1, "a canonical v2 endorsement still verifies during the migration window");

  const resplit = { ...legacy, devicePublicKey: concat(legacy.devicePublicKey, kem.subarray(0, 1)), kemBundlePublicKeys: kem.subarray(1) };
  equal((await verifiedDevices(root.rootIdentity, [resplit])).length, 0,
    "a re-split v2 endorsement is refused even though its signature checks out");

  const v3 = await root.endorse(device, kem);
  equal((await verifiedDevices(root.rootIdentity, [v3])).length, 1, "a v3 endorsement verifies");

  // v3 with a long KEM bundle (hybrid X25519 plus ML-KEM) verifies too.
  const bundle = randomBytes(32 + 1184 + 3);
  equal((await verifiedDevices(root.rootIdentity, [await root.endorse(device, bundle)])).length, 1,
    "a v3 endorsement with a hybrid sized bundle verifies");

  // Swapping either key after signing fails.
  const swappedKem = { ...v3, kemBundlePublicKeys: kem32() };
  equal((await verifiedDevices(root.rootIdentity, [swappedKem])).length, 0, "a directory that swaps the KEM key fails verification");
  const swappedDev = { ...v3, devicePublicKey: (await newP256()).x963 };
  equal((await verifiedDevices(root.rootIdentity, [swappedDev])).length, 0, "a directory that swaps the device key fails verification");

  // Order is kept, bad ones dropped.
  const d2 = await newP256();
  const second = await root.endorse(d2, kem32());
  const stranger = await TestAuthenticator.make();
  const foreign = await stranger.endorse(await newP256(), kem32());
  const out = await verifiedDevices(root.rootIdentity, [second, foreign, v3]);
  check(out.length === 2 && out[0] === second && out[1] === v3, "verifiedDevices keeps order and drops the foreign endorsement");

  // Context violations inside an endorsement.
  const commitment = await endorsementCommitment(devicePub, kem);
  for (const [opts, what] of [
    [{ relyingPartyID: "evil.example" }, "wrong RP ID"],
    [{ userPresent: false }, "UP flag unset"],
    [{ type: "webauthn.create" }, "type webauthn.create"],
  ]) {
    const e = { ...v3, assertion: await root.assertionBytes(commitment, opts) };
    equal((await verifiedDevices(root.rootIdentity, [e])).length, 0, `an endorsement with ${what} is refused`);
  }
  const wrongChallenge = { ...v3, assertion: await root.assertionBytes(await sha256(utf8("something else"))) };
  equal((await verifiedDevices(root.rootIdentity, [wrongChallenge])).length, 0, "an endorsement over the wrong challenge is refused");
  const garbage = { ...v3, assertion: utf8("{}") };
  equal((await verifiedDevices(root.rootIdentity, [garbage])).length, 0, "an endorsement whose assertion does not decode is refused");

  // A root whose public key is not a valid raw key has no authorities.
  const badRoot = { ...root.rootIdentity, publicKey: device.x963 };
  equal((await verifiedDevices(badRoot, [v3])).length, 0, "a root with a 65 byte key verifies nothing");
  equal((await authorityKeys(badRoot)).length, 0, "and has no authorities");
}

// ---------------------------------------------------------------- sponsored endorsement

async function sponsored() {
  const root = await TestAuthenticator.make();
  const device = await newP256();
  const bundle = randomBytes(1216);
  const e = await root.endorse(device, bundle);
  e.lockedPrivate = randomBytes(200);
  e.prfSalt = randomBytes(32);
  const decoded = parseDeviceEndorsements(jsonBytes([endorsementJSON(e)]));
  check(decoded && same(decoded[0].lockedPrivate, e.lockedPrivate) && same(decoded[0].prfSalt, e.prfSalt),
    "lockedPrivate and prfSalt survive decoding");
  const verified = await verifiedDevices(root.rootIdentity, decoded);
  equal(verified.length, 1, "a sponsored endorsement verifies like a phone's");
  check(same(verified[0].kemBundlePublicKeys, bundle), "and offers the virtual device's bundle for wrapping");
  const plain = parseDeviceEndorsements(jsonBytes([{ ...endorsementJSON(e), lockedPrivate: null, prfSalt: undefined }]));
  check(plain && plain[0].lockedPrivate === null && plain[0].prfSalt === null, "an older endorsement decodes with neither");
  equal(decoded[0].createdAt, 1_700_000_000, "createdAt comes back as unix seconds");
  check(parseDeviceEndorsements(jsonBytes([{ ...endorsementJSON(e), prfSalt: 3 }])) === null, "a wrong type optional field fails the decode");
}

// ---------------------------------------------------------------- backup credentials

async function backups() {
  const root = await TestAuthenticator.make();
  const backup = await TestAuthenticator.make();
  const stranger = await TestAuthenticator.make();
  const device = await newP256();
  const kem = kem32();

  const good = await makeBackup(root, backup);
  const rootWithBackup = { ...root.rootIdentity, backupCredentials: [good] };
  const byBackup = await backup.endorse(device, kem);

  equal((await verifiedBackupCredentials([good], root.rootIdentity)).length, 1, "a backup signed both ways verifies");
  equal((await verifiedDevices(root.rootIdentity, [byBackup])).length, 0, "a backup-signed endorsement is refused without the backup on the root");
  equal((await verifiedDevices(rootWithBackup, [byBackup])).length, 1, "a backup-signed endorsement is accepted with a verified backup");
  equal((await authorityKeys(rootWithBackup)).length, 2, "root plus one backup is two authorities");

  // One-sided: no valid acceptance from the backup itself.
  const oneSided = await makeBackup(root, backup, { signAcceptanceWith: stranger });
  equal((await verifiedDevices({ ...root.rootIdentity, backupCredentials: [oneSided] }, [byBackup])).length, 0,
    "a backup whose acceptance is not signed by the backup key is refused");
  // Acceptance lifted from another identity.
  const lifted = await makeBackup(root, backup, { rootIDHash: stranger.credentialIDHash });
  equal((await verifiedBackupCredentials([lifted], root.rootIdentity)).length, 0, "an acceptance naming another root is refused");
  // Root half signed by a stranger.
  const strangerAuth = await makeBackup(stranger, backup, { rootIDHash: root.credentialIDHash });
  equal((await verifiedBackupCredentials([strangerAuth], root.rootIdentity)).length, 0, "a backup authorised by some other root is refused");
  // Swapped public key after signing.
  const swapped = { ...good, publicKey: stranger.publicKeyData };
  equal((await verifiedBackupCredentials([swapped], root.rootIdentity)).length, 0, "a backup with a swapped public key is refused");
  // Wrong length key.
  const longKey = { ...good, publicKey: concat(Uint8Array.of(4), backup.publicKeyData) };
  equal((await verifiedBackupCredentials([longKey], root.rootIdentity)).length, 0, "a backup public key that is not 64 bytes is refused");
  // Revoked.
  const revokedSet = await revokedBackupPublicKeys(root.rootIdentity, [await root.revokeBackup(backup.publicKeyData)]);
  check(revokedSet.has(toHex(backup.publicKeyData)), "a root-signed backup revocation is honoured");
  equal((await verifiedBackupCredentials([good], root.rootIdentity, revokedSet)).length, 0, "a revoked backup is refused");
  const forgedSet = await revokedBackupPublicKeys(root.rootIdentity, [await stranger.revokeBackup(backup.publicKeyData)]);
  check(forgedSet.size === 0, "a backup revocation signed by some other key is ignored");
  const byBackupItself = await revokedBackupPublicKeys(root.rootIdentity, [await backup.revokeBackup(backup.publicKeyData)]);
  check(byBackupItself.size === 0, "a backup cannot revoke anything, not even itself");

  // credentialID flip: the assertion names the wrong authority. Not covered
  // by the signature, so verification must fall through to every authority.
  const flippedToRoot = await backup.endorse(device, kem);
  const a = parseAssertion(flippedToRoot.assertion);
  flippedToRoot.assertion = encodeAssertion({ ...a, credentialID: root.credentialID });
  equal((await verifiedDevices(rootWithBackup, [flippedToRoot])).length, 1,
    "a backup-signed endorsement whose credentialID was flipped to the root still verifies");
  const rootSigned = await root.endorse(device, kem);
  const b = parseAssertion(rootSigned.assertion);
  rootSigned.assertion = encodeAssertion({ ...b, credentialID: backup.credentialID });
  equal((await verifiedDevices(rootWithBackup, [rootSigned])).length, 1,
    "a root-signed endorsement whose credentialID was flipped to the backup still verifies");
  const unknownID = await root.endorse(device, kem);
  const c = parseAssertion(unknownID.assertion);
  unknownID.assertion = encodeAssertion({ ...c, credentialID: randomBytes(16) });
  equal((await verifiedDevices(rootWithBackup, [unknownID])).length, 1, "an unknown credentialID falls back to every authority");
  const legacyRoot = { ...root.rootIdentity, rawCredentialID: null };
  equal((await verifiedDevices(legacyRoot, [await root.endorse(device, kem)])).length, 1,
    "a root with no published credential ID still verifies its endorsements");
  const flippedStranger = await stranger.endorse(device, kem);
  const d = parseAssertion(flippedStranger.assertion);
  flippedStranger.assertion = encodeAssertion({ ...d, credentialID: root.credentialID });
  equal((await verifiedDevices(rootWithBackup, [flippedStranger])).length, 0,
    "naming the root does not make a stranger's signature verify");
}

// ---------------------------------------------------------------- identityFromRecord

async function records() {
  const root = await TestAuthenticator.make();
  const backup = await TestAuthenticator.make();
  const stranger = await TestAuthenticator.make();
  const d1 = await newP256();
  const d2 = await newP256();
  const d3 = await newP256();
  const e1 = await root.endorse(d1, kem32());
  const e2 = await root.endorse(d2, kem32());
  const e3 = await backup.endorse(d3, kem32());
  const good = await makeBackup(root, backup);

  const baseFields = () => ({
    publicKey: root.publicKeyData,
    tier: "verified",
    displayName: "Grandma",
    deviceEndorsements: jsonBytes([e1, e2, e3].map(endorsementJSON)),
    credentialID: root.credentialID,
    backupEndorsements: jsonBytes([backupJSON(good)]),
  });
  const hash = root.credentialIDHash;

  // The plain case.
  const r = await identityFromRecord(baseFields(), [], hash);
  check(r !== null, "a good record decodes");
  equal(r.root.credentialIDHash, hash, "root carries the hash it was fetched under");
  check(same(r.root.publicKey, root.publicKeyData) && r.root.tier === "verified" && r.root.displayName === "Grandma",
    "root carries key, tier, name");
  check(r.root.rawCredentialID && same(r.root.rawCredentialID, root.credentialID), "root carries the credential ID");
  equal(r.root.backupCredentials?.length, 1, "root carries the verified backup");
  equal(r.endorsements.length, 3, "all three endorsements come through");
  equal((await verifiedDevices(r.root, r.endorsements)).length, 3, "and all three verify, including the backup-signed one");

  // Tombstone, missing fields, wrong types.
  check(await identityFromRecord({ ...baseFields(), tier: "deleted" }, [], hash) === null, "a tombstoned identity reads as not found");
  check(await identityFromRecord({ ...baseFields(), tier: "gold" }, [], hash) === null, "an unknown tier reads as not found");
  check(await identityFromRecord({ ...baseFields(), publicKey: undefined }, [], hash) === null, "no public key reads as not found");
  check(await identityFromRecord({ ...baseFields(), displayName: 3 }, [], hash) === null, "a non string name reads as not found");
  check(await identityFromRecord({ ...baseFields(), deviceEndorsements: undefined }, [], hash) === null, "no endorsements reads as not found");
  const oneBad = jsonBytes([endorsementJSON(e1), { ...endorsementJSON(e2), createdAt: "yesterday" }]);
  check(await identityFromRecord({ ...baseFields(), deviceEndorsements: oneBad }, [], hash) === null,
    "one bad endorsement fails the whole array, as try? decode([DeviceEndorsement]) does");
  const noCred = await identityFromRecord({ ...baseFields(), credentialID: "abc" }, [], hash);
  check(noCred !== null && noCred.root.rawCredentialID === null, "a credentialID of the wrong type is just absent");
  let threw = false;
  try { await identityFromRecord(baseFields(), undefined, hash); } catch { threw = true; }
  check(threw, "side revocations that failed to load must not read as none");

  // Revocations on the record and on the side.
  const rev1 = await root.revoke(e1.devicePublicKey);
  const rev2 = await root.revoke(e2.devicePublicKey);
  const onRecord = await identityFromRecord({ ...baseFields(), revocations: jsonBytes([revocationJSON(rev1)]) }, [], hash);
  check(onRecord.endorsements.length === 2 && onRecord.endorsements.every((e) => !same(e.devicePublicKey, e1.devicePublicKey)),
    "a root-signed revocation on the record removes that device");
  const onSide = await identityFromRecord(baseFields(), [jsonBytes(revocationJSON(rev2)), utf8("junk"), jsonBytes({ devicePublicKey: 1 })], hash);
  check(onSide.endorsements.length === 2 && onSide.endorsements.every((e) => !same(e.devicePublicKey, e2.devicePublicKey)),
    "a root-signed side revocation removes that device, and junk side records are skipped");
  const forged = await stranger.revoke(e1.devicePublicKey);
  const byBackup = await backup.revoke(e1.devicePublicKey);
  const ignored = await identityFromRecord(baseFields(), [jsonBytes(revocationJSON(forged)), jsonBytes(revocationJSON(byBackup))], hash);
  equal(ignored.endorsements.length, 3, "revocations signed by a stranger or by a backup key are ignored");
  const badList = jsonBytes([revocationJSON(rev1), { devicePublicKey: "x" }]);
  const badListResult = await identityFromRecord({ ...baseFields(), revocations: badList }, [], hash);
  equal(badListResult.endorsements.length, 3, "one bad entry voids the whole record revocation list, as in Swift");

  // Backup revoked: the backup disappears and so does its device, after verifiedDevices.
  const revB = await root.revokeBackup(backup.publicKeyData);
  const noBackup = await identityFromRecord(baseFields(), [jsonBytes(revocationJSON(revB))], hash);
  check(noBackup.root.backupCredentials === null, "a revoked backup is gone from the root");
  equal(noBackup.endorsements.length, 3, "revoking a backup removes no endorsement by itself");
  const live = await verifiedDevices(noBackup.root, noBackup.endorsements);
  check(live.length === 2 && live.every((e) => !same(e.devicePublicKey, e3.devicePublicKey)),
    "but the device the revoked backup endorsed no longer verifies");

  // Bad backup list: all or nothing.
  const mixedBackups = jsonBytes([backupJSON(good), { ...backupJSON(good), tier: "gold" }]);
  const mixed = await identityFromRecord({ ...baseFields(), backupEndorsements: mixedBackups }, [], hash);
  check(mixed.root.backupCredentials === null, "one undecodable backup voids the whole backup list");
  const strangerBackup = await makeBackup(stranger, backup, { rootIDHash: root.credentialIDHash });
  const filtered = await identityFromRecord({ ...baseFields(), backupEndorsements: jsonBytes([backupJSON(strangerBackup), backupJSON(good)]) }, [], hash);
  equal(filtered.root.backupCredentials?.length, 1, "a decodable but forged backup is filtered out, the good one kept");
  const onlyForged = await identityFromRecord({ ...baseFields(), backupEndorsements: jsonBytes([backupJSON(strangerBackup)]) }, [], hash);
  check(onlyForged.root.backupCredentials === null, "no live backups means null, not an empty list");

  // The hash matters: acceptance names the root hash, so a wrong one drops the backup.
  const wrongHash = await identityFromRecord(baseFields(), [], stranger.credentialIDHash);
  check(wrongHash.root.backupCredentials === null, "a backup does not verify under a record name it did not accept");

  // A tampered endorsement comes through the record but fails verifiedDevices.
  const tampered = { ...endorsementJSON(e1), kemBundlePublicKeys: toB64(kem32()) };
  const t = await identityFromRecord({ ...baseFields(), deviceEndorsements: jsonBytes([tampered]) }, [], hash);
  equal(t.endorsements.length, 1, "identityFromRecord does not verify endorsements itself");
  equal((await verifiedDevices(t.root, t.endorsements)).length, 0, "verifiedDevices drops the tampered one");
}

// ---------------------------------------------------------------- run

await webAuthnContext();
await challengeMatching();
await revocations();
await endorsementFraming();
await sponsored();
await backups();
await records();

console.log(`${checks} checks, ${failures} failures`);
if (failures > 0) process.exit(1);
