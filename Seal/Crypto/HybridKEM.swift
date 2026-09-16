// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import CryptoKit

/// Classical key wrapping (X25519 ephemeral-static ECDH + HKDF + AES-256-GCM).
/// Used by custody receipts. The estate wraps use the hybrid X25519 plus
/// ML-KEM-768 construction in Crypto/KEMBundle.swift instead.
enum HybridKEM {
    struct Envelope: Codable {
        let ephemeralPublicKey: Data
        let ciphertext: Data        // AES.GCM combined (nonce ‖ ct ‖ tag)
    }

    enum KEMError: Error { case badRecipientKey, badEnvelope }

    // MARK: - Single-envelope primitives

    /// ECDH-wrap a chain key to ONE recipient device X25519 public key.
    private static func wrapEnvelope(_ chainKey: Data, to recipientKEMPublicKeyOrBundle: Data) throws -> Envelope {
        // An endorsement may now carry a hybrid KEMBundle (Crypto/KEMBundle.swift)
        // instead of a bare X25519 key. This legacy path uses the X25519 half
        // either way, so receipts keep working against every endorsement.
        guard let bundle = KEMBundle.parse(recipientKEMPublicKeyOrBundle) else { throw KEMError.badRecipientKey }
        let recipientKEMPublicKey = bundle.x25519
        guard let recipientPub = try? Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: recipientKEMPublicKey) else { throw KEMError.badRecipientKey }

        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipientPub)
        let wrapKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: ephemeral.publicKey.rawRepresentation + recipientKEMPublicKey,
            sharedInfo: Data("seal.kem.x25519.v1".utf8),
            outputByteCount: 32
        )
        let sealed = try AES.GCM.seal(chainKey, using: wrapKey)
        return Envelope(ephemeralPublicKey: ephemeral.publicKey.rawRepresentation,
                        ciphertext: sealed.combined!)
    }

    private static func openEnvelope(_ envelope: Envelope,
                                     with myPrivateKey: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        guard let ephPub = try? Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: envelope.ephemeralPublicKey) else { throw KEMError.badEnvelope }
        let shared = try myPrivateKey.sharedSecretFromKeyAgreement(with: ephPub)
        let wrapKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: envelope.ephemeralPublicKey + myPrivateKey.publicKey.rawRepresentation,
            sharedInfo: Data("seal.kem.x25519.v1".utf8),
            outputByteCount: 32
        )
        return try AES.GCM.open(try AES.GCM.SealedBox(combined: envelope.ciphertext), using: wrapKey)
    }

    // MARK: - Public API

    /// Wrap to a SINGLE recipient key (kept for compatibility / callers that
    /// genuinely have one target).
    static func wrap(_ chainKey: Data, to recipientKEMPublicKey: Data) throws -> Data {
        try JSONEncoder().encode(wrapEnvelope(chainKey, to: recipientKEMPublicKey))
    }

    /// Wrap the same chain key to EVERY one of a recipient's endorsed device
    /// KEM keys. The receiver holds only one private key but may be endorsed
    /// under several (multi-device, or a re-key the sender's directory view
    /// hasn't caught up to). Wrapping to all of them means whichever key the
    /// receiver actually has can open its own copy, self-healing against a
    /// stale `.last`-endorsement view, which was a real cross-device failure
    /// ("Sync failed / CryptoKit error 3"). Empty/duplicate keys are skipped;
    /// at least one must wrap or this throws.
    static func wrapToAll(_ chainKey: Data, to recipientKEMPublicKeys: [Data]) throws -> Data {
        var seen = Set<Data>()
        let envelopes = recipientKEMPublicKeys.compactMap { key -> Envelope? in
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return try? wrapEnvelope(chainKey, to: key)
        }
        guard !envelopes.isEmpty else { throw KEMError.badRecipientKey }
        return try JSONEncoder().encode(envelopes)
    }

    /// Unwrap with this device's X25519 private key. Accepts BOTH the new
    /// multi-envelope array (try our key against each copy until one opens)
    /// and a legacy single-envelope record. Array-vs-object JSON shapes are
    /// mutually exclusive, so the format is detected unambiguously.
    static func unwrap(_ envelopeData: Data, with myPrivateKey: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        if let envelopes = try? JSONDecoder().decode([Envelope].self, from: envelopeData) {
            for env in envelopes {
                if let opened = try? openEnvelope(env, with: myPrivateKey) { return opened }
            }
            throw KEMError.badEnvelope          // none of our copies opened
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: envelopeData) else {
            throw KEMError.badEnvelope
        }
        return try openEnvelope(envelope, with: myPrivateKey)   // legacy single
    }
}
