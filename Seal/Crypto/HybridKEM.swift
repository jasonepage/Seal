import Foundation
import CryptoKit

/// Key wrapping for sender-chain distribution (SDS §2).
/// v1: X25519 ephemeral-static ECDH + HKDF + AES-256-GCM.
/// TODO(post-spike): add ML-KEM-768 alongside X25519 (hybrid — both secrets
/// feed one HKDF) once the CryptoKit API surface is confirmed on-device.
enum HybridKEM {
    struct Envelope: Codable {
        let ephemeralPublicKey: Data
        let ciphertext: Data        // AES.GCM combined (nonce ‖ ct ‖ tag)
    }

    enum KEMError: Error { case badRecipientKey, badEnvelope }

    /// Wrap a sender chain key to a recipient device's X25519 public key.
    static func wrap(_ chainKey: Data, to recipientKEMPublicKey: Data) throws -> Data {
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
        let envelope = Envelope(
            ephemeralPublicKey: ephemeral.publicKey.rawRepresentation,
            ciphertext: sealed.combined!
        )
        return try JSONEncoder().encode(envelope)
    }

    /// Unwrap with this device's X25519 private key.
    static func unwrap(_ envelopeData: Data, with myPrivateKey: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: envelopeData),
              let ephPub = try? Curve25519.KeyAgreement.PublicKey(
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
}
