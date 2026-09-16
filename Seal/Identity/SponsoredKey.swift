// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import CryptoKit

//  SponsoredKey.swift
//  Seal
//
//  A KEY THAT CARRIES A SECRET (docs/PENDING_RECIPIENTS.md, option A).
//
//  A dad wants to write to his daughter. She uses Android and lives in
//  another state. Today an envelope is wrapped to the recipient's phone,
//  and she has none. So the dad registers a spare hardware security key
//  AS her, on his phone, and hands it over like a house key.
//
//  What makes that work is the WebAuthn PRF extension: the key can compute
//  a secret from a salt, the same secret every time, for whoever holds the
//  key and its PIN. Seal makes a fresh device key pair for her (a signing
//  key and the hybrid KEM bundle), locks the private halves under that
//  secret, and publishes the locked blob in the directory beside the
//  public halves as a "virtual device" endorsed by her root credential.
//  Envelopes are then wrapped to it like to any phone. Years later she
//  plugs the key into any iPhone, signs in, the PRF secret unlocks the
//  private halves, and her envelope opens.
//
//  What the owner's phone keeps: nothing. The private halves are made,
//  locked, published and dropped in one function. What a thief with the
//  key and PIN gets: they are her, which is what a house key means, and
//  still nothing opens before the release.
//
//  Not the endorsement commitment: `lockedPrivate` is outside it on
//  purpose. A directory that swapped the blob would only hand a future
//  phone bytes that fail to decrypt (AES-GCM authenticates them).

enum SponsoredKey {

    /// The private halves of the virtual device, in the clear only inside
    /// `register` on the owner's phone and inside `unlock` on the future
    /// recipient's phone.
    struct PrivateHalves: Codable, Hashable {
        /// P-256 signing key, raw representation. The virtual device never
        /// signs an event today (recipients write none), but every endorsed
        /// device has one and the future phone may want to.
        let signingKey: Data
        let x25519: Data
        let mlkem768Seed: Data?

        var kemBundle: KEMPrivateBundle? {
            guard let x = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: x25519) else { return nil }
            return KEMPrivateBundle(x25519: x, mlkem768Seed: mlkem768Seed)
        }
    }

    static let hkdfInfo = Data("seal.sponsored.lock.v1".utf8)
    static let aad = Data("seal.sponsored.v1".utf8)

    /// Fresh halves for a new virtual device.
    static func makeHalves() -> PrivateHalves {
        PrivateHalves(signingKey: P256.Signing.PrivateKey().rawRepresentation,
                      x25519: Curve25519.KeyAgreement.PrivateKey().rawRepresentation,
                      mlkem768Seed: KEMPrivateBundle.newMLKEMSeed())
    }

    /// The public halves the endorsement commits to.
    static func publicParts(of halves: PrivateHalves) throws -> (devicePublicKey: Data, kemBundle: Data) {
        let signing = try P256.Signing.PrivateKey(rawRepresentation: halves.signingKey)
        guard let kem = halves.kemBundle else { throw Failure.badHalves }
        return (signing.publicKey.x963Representation, kem.publicBundle.encoded)
    }

    /// The lock key: HKDF over the PRF output, salted with the same salt
    /// the key was asked to evaluate, so two identities on two keys never
    /// share a lock even if a key were to answer the same for both.
    static func lockKey(prf: SymmetricKey, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: prf, salt: salt, info: hkdfInfo, outputByteCount: 32)
    }

    static func lock(_ halves: PrivateHalves, prf: SymmetricKey, salt: Data) throws -> Data {
        let plaintext = try JSONEncoder().encode(halves)
        let box = try AES.GCM.seal(plaintext, using: lockKey(prf: prf, salt: salt), authenticating: aad)
        guard let combined = box.combined else { throw Failure.badHalves }
        return combined
    }

    static func unlock(_ locked: Data, prf: SymmetricKey, salt: Data) throws -> PrivateHalves {
        let box = try AES.GCM.SealedBox(combined: locked)
        let plaintext = try AES.GCM.open(box, using: lockKey(prf: prf, salt: salt), authenticating: aad)
        return try JSONDecoder().decode(PrivateHalves.self, from: plaintext)
    }

    static func randomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    enum Failure: LocalizedError {
        case prfUnsupported
        case prfMissing
        case badHalves
        case wrongKey

        var errorDescription: String? {
            switch self {
            case .prfUnsupported:
                "This security key cannot carry a secret. Seal needs a key with the PRF feature (a current YubiKey 5 does). The key was not changed."
            case .prfMissing:
                "The key did not return its secret. Try again, and make sure the key's PIN is set."
            case .badHalves:
                "Something went wrong making the keys. Nothing was published."
            case .wrongKey:
                "This key does not unlock this identity."
            }
        }
    }
}
