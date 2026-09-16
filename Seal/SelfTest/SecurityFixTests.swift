// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import CryptoKit

//  SecurityFixTests.swift
//  Seal
//
//  One suite per security fix from the conversion brief (section 6). Each
//  test states the attack it closes in its name.

enum SecurityFixTests {

    static var suites: [SelfTest.Suite] { [
        .init(name: "fix1.keyPinning", run: keyPinning),
        .init(name: "fix2.webauthnContext", run: webAuthnContext),
        .init(name: "fix3.unsignedRevokedAt", run: unsignedRevokedAt),
        .init(name: "fix4.endorsementFraming", run: endorsementFraming),
    ] }

    // MARK: fix 1

    static func keyPinning(_ t: SelfTest.Context) throws {
        let keyA = Data(repeating: 0xA1, count: 64)
        let keyB = Data(repeating: 0xB2, count: 64)
        var pins: [String: Data] = [:]

        t.equal(KeyPinStore.check(hash: "h1", publicKey: keyA, pins: pins), .firstSeen,
                "unknown hash is first seen, not a match")
        pins = KeyPinStore.pinning(hash: "h1", publicKey: keyA, into: pins)
        t.equal(KeyPinStore.check(hash: "h1", publicKey: keyA, pins: pins), .matches,
                "pinned key matches itself")
        t.equal(KeyPinStore.check(hash: "h1", publicKey: keyB, pins: pins), .mismatch,
                "directory serving a different key under a pinned hash is a mismatch")
        let again = KeyPinStore.pinning(hash: "h1", publicKey: keyB, into: pins)
        t.equal(again["h1"], keyA, "a pin is never overwritten by pinning again")
        let empty = KeyPinStore.pinning(hash: "h2", publicKey: Data(), into: pins)
        t.check(empty["h2"] == nil, "an empty key is never pinned")
    }

    // MARK: fix 2

    static func webAuthnContext(_ t: SelfTest.Context) throws {
        let key = TestAuthenticator()
        let challenge = Data(SHA256.hash(data: Data("hello".utf8)))

        t.check(key.assertion(challenge: challenge).verify(with: key.publicKey),
                "a well formed assertion verifies")
        t.check(!key.assertion(challenge: challenge).verify(with: TestAuthenticator().publicKey),
                "wrong key is refused")

        var wrongRP = TestAuthenticator.Options(); wrongRP.relyingPartyID = "evil.example"
        t.check(!key.assertion(challenge: challenge, options: wrongRP).verify(with: key.publicKey),
                "a signature made for another relying party is refused")

        var noUP = TestAuthenticator.Options(); noUP.userPresent = false
        t.check(!key.assertion(challenge: challenge, options: noUP).verify(with: key.publicKey),
                "an assertion with no user presence is refused")

        var create = TestAuthenticator.Options(); create.type = "webauthn.create"
        t.check(!key.assertion(challenge: challenge, options: create).verify(with: key.publicKey),
                "a registration signature is not accepted as an assertion")

        t.check(!key.assertion(challenge: challenge).verify(with: key.publicKey, requireUserVerification: true),
                "UV required and unset is refused")
        var uv = TestAuthenticator.Options(); uv.userVerified = true
        t.check(key.assertion(challenge: challenge, options: uv).verify(with: key.publicKey, requireUserVerification: true),
                "UV required and set verifies")

        t.check(WebAuthnAssertion.enforceContextChecks, "context checks are enforced, not logged")
    }

    // MARK: fix 3

    static func unsignedRevokedAt(_ t: SelfTest.Context) throws {
        let root = TestAuthenticator()
        let device = P256.Signing.PrivateKey()
        let kem = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let endorsement = root.endorse(deviceKey: device, kem: kem)

        // The attack: a directory writer sets revokedAt on the blob. The
        // struct no longer has the field, so the JSON is decoded with the key
        // ignored, and the device must still verify.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(endorsement)) as! [String: Any]
        json["revokedAt"] = 1_700_000_500.0
        let tampered = try JSONDecoder().decode(DeviceEndorsement.self,
                                                from: JSONSerialization.data(withJSONObject: json))
        let live = IdentityManager.verifiedDevices(root: root.rootIdentity, endorsements: [tampered])
        t.equal(live.count, 1, "an unsigned revokedAt field cannot un-verify a device")

        // The only real channel: a root-signed revocation.
        let revoked = IdentityManager.revokedDevicePublicKeys(
            root: root.rootIdentity,
            revocations: [root.revoke(devicePublicKey: endorsement.devicePublicKey)])
        t.check(revoked.contains(endorsement.devicePublicKey), "a root-signed revocation is honoured")

        let forged = IdentityManager.revokedDevicePublicKeys(
            root: root.rootIdentity,
            revocations: [TestAuthenticator().revoke(devicePublicKey: endorsement.devicePublicKey)])
        t.check(forged.isEmpty, "a revocation signed by some other key is ignored")
    }

    // MARK: fix 4

    static func endorsementFraming(_ t: SelfTest.Context) throws {
        let root = TestAuthenticator()
        let device = P256.Signing.PrivateKey()
        let kem = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let devicePub = device.publicKey.x963Representation

        // v3: moving a byte across the field boundary changes the commitment.
        let honest = IdentityManager.endorsementCommitment(devicePublicKey: devicePub, kemBundlePublicKeys: kem)
        let shifted = IdentityManager.endorsementCommitment(devicePublicKey: devicePub + kem.prefix(1),
                                                            kemBundlePublicKeys: kem.dropFirst())
        t.check(honest != shifted, "v3 framing: re-splitting the bytes changes the commitment")

        // v2: the SAME re-split hashes identically (that is the bug), so the
        // verifier must refuse any v2 endorsement whose fields are not the
        // one canonical shape.
        let v2Honest = IdentityManager.legacyEndorsementCommitmentV2(devicePublicKey: devicePub, kemBundlePublicKeys: kem)
        let v2Shifted = IdentityManager.legacyEndorsementCommitmentV2(devicePublicKey: devicePub + kem.prefix(1),
                                                                      kemBundlePublicKeys: kem.dropFirst())
        t.check(v2Honest == v2Shifted, "v2 has the collision this fix exists for")

        let legacy = root.endorse(deviceKey: device, kem: kem, legacyV2: true)
        t.equal(IdentityManager.verifiedDevices(root: root.rootIdentity, endorsements: [legacy]).count, 1,
                "a canonical v2 endorsement still verifies during the migration window")

        let resplit = DeviceEndorsement(devicePublicKey: legacy.devicePublicKey + kem.prefix(1),
                                        kemBundlePublicKeys: kem.dropFirst(),
                                        assertion: legacy.assertion,
                                        createdAt: legacy.createdAt)
        t.equal(IdentityManager.verifiedDevices(root: root.rootIdentity, endorsements: [resplit]).count, 0,
                "a re-split v2 endorsement is refused even though its signature checks out")

        let v3 = root.endorse(deviceKey: device, kem: kem)
        t.equal(IdentityManager.verifiedDevices(root: root.rootIdentity, endorsements: [v3]).count, 1,
                "a v3 endorsement verifies")
    }
}
