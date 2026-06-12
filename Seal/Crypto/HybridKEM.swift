import Foundation
import CryptoKit

/// Hybrid post-quantum key wrapping (SDS §2): X25519 AND ML-KEM-768 shared
/// secrets feed a single HKDF, so breaking the wrap requires breaking both.
/// KEM private keys are software (keychain, .afterFirstUnlockThisDeviceOnly,
/// non-synchronized); their public keys are signed by the SE device key.
enum HybridKEM {
    struct PublicBundle: Codable {
        let x25519: Data
        let mlkem768: Data
        let deviceSignature: Data   // SE device key signature over both
    }

    /// Wrap a sender chain key to a recipient device.
    static func wrap(_ chainKey: SymmetricKey, to recipient: PublicBundle) throws -> Data {
        // TODO: X25519 ephemeral ECDH + ML-KEM-768 encapsulation (CryptoKit, iOS 26)
        //       → combined = HKDF(ecdhSecret || kemSecret) → AES-GCM wrap chainKey.
        // Spike required: confirm CryptoKit ML-KEM API surface on target SDK
        // before building; fall back to X25519-only behind a protocol if needed.
        fatalError("unimplemented")
    }

    static func unwrap(_ envelope: Data) throws -> SymmetricKey {
        fatalError("unimplemented")
    }
}
