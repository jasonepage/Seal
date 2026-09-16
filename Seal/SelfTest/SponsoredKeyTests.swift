// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import CryptoKit

//  SponsoredKeyTests.swift
//  Seal
//
//  The lock around a sponsored key's virtual device: it opens with the
//  key's secret and with nothing else, the public halves it endorses are
//  the ones the private halves match, and an endorsement carrying the
//  locked blob still verifies exactly like a phone's.

enum SponsoredKeyTests {

    static var suites: [SelfTest.Suite] { [
        .init(name: "sponsored.lockOpensOnlyWithTheKey") { try lockOpensOnlyWithTheKey($0) },
        .init(name: "sponsored.halvesMatchPublicParts") { try halvesMatchPublicParts($0) },
        .init(name: "sponsored.endorsementVerifiesLikeAPhone") { try endorsementVerifiesLikeAPhone($0) },
    ] }

    static func lockOpensOnlyWithTheKey(_ t: SelfTest.Context) throws {
        let halves = SponsoredKey.makeHalves()
        let prf = SymmetricKey(size: .bits256)
        let salt = SponsoredKey.randomSalt()
        let locked = try SponsoredKey.lock(halves, prf: prf, salt: salt)
        t.equal(try SponsoredKey.unlock(locked, prf: prf, salt: salt), halves, "the right secret and salt open it")
        t.throwsError("a different secret does not") { _ = try SponsoredKey.unlock(locked, prf: SymmetricKey(size: .bits256), salt: salt) }
        t.throwsError("a different salt does not") { _ = try SponsoredKey.unlock(locked, prf: prf, salt: SponsoredKey.randomSalt()) }
        var flipped = locked; flipped[flipped.count / 2] ^= 0x01
        t.throwsError("a swapped blob does not") { _ = try SponsoredKey.unlock(flipped, prf: prf, salt: salt) }
        t.check(!locked.contains(halves.x25519.prefix(8)) , "the private key is not visible in the blob")
    }

    static func halvesMatchPublicParts(_ t: SelfTest.Context) throws {
        let halves = SponsoredKey.makeHalves()
        let parts = try SponsoredKey.publicParts(of: halves)
        t.equal(parts.devicePublicKey.count, 65, "a P-256 x963 public key")
        let bundle = KEMBundle.parse(parts.kemBundle)
        t.check(bundle != nil, "the KEM bundle parses")
        // Wrap something to the public bundle and open it with the halves.
        let secret = Data("the envelope content key".utf8)
        let wraps = try HybridWrap.wrapToAll(secret, to: [parts.kemBundle], aad: Data("t".utf8))
        guard let kem = halves.kemBundle else { t.fail("halves have no KEM bundle"); return }
        t.equal(try HybridWrap.openAny(wraps, with: kem, aad: Data("t".utf8)), secret, "what is wrapped to the virtual device opens with the halves")
    }

    static func endorsementVerifiesLikeAPhone(_ t: SelfTest.Context) throws {
        let root = TestAuthenticator()
        let halves = SponsoredKey.makeHalves()
        let parts = try SponsoredKey.publicParts(of: halves)
        let commitment = IdentityManager.endorsementCommitment(devicePublicKey: parts.devicePublicKey,
                                                               kemBundlePublicKeys: parts.kemBundle)
        let prf = SymmetricKey(size: .bits256)
        let salt = SponsoredKey.randomSalt()
        let endorsement = DeviceEndorsement(devicePublicKey: parts.devicePublicKey,
                                            kemBundlePublicKeys: parts.kemBundle,
                                            assertion: try JSONEncoder().encode(root.assertion(challenge: commitment)),
                                            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                                            lockedPrivate: try SponsoredKey.lock(halves, prf: prf, salt: salt),
                                            prfSalt: salt)
        t.check(endorsement.isSponsored, "it is a sponsored endorsement")
        let verified = IdentityManager.verifiedDevices(root: root.rootIdentity, endorsements: [endorsement])
        t.equal(verified.count, 1, "a sponsored endorsement verifies like a phone's")
        t.equal(verified.first?.kemBundlePublicKeys, parts.kemBundle, "and offers the virtual device's bundle for wrapping")
        // Round trip through JSON keeps the locked blob and the salt, and an
        // endorsement without them decodes as an ordinary phone.
        let back = try JSONDecoder().decode(DeviceEndorsement.self, from: try JSONEncoder().encode(endorsement))
        t.equal(back, endorsement, "round trips")
        let plain = DeviceEndorsement(devicePublicKey: parts.devicePublicKey, kemBundlePublicKeys: parts.kemBundle,
                                      assertion: endorsement.assertion, createdAt: endorsement.createdAt)
        t.check(!plain.isSponsored, "a phone endorsement is not sponsored")
        let old = try JSONDecoder().decode(DeviceEndorsement.self, from: try JSONEncoder().encode(plain))
        t.check(old.lockedPrivate == nil && old.prfSalt == nil, "an older endorsement decodes with neither")
    }
}
