import Foundation
import CryptoKit

/// Owns the local user's root identity, Secure Enclave device key,
/// and verification of endorsement chains (SDS §2, §3).
@Observable
final class IdentityManager {
    private(set) var rootIdentity: RootIdentity?
    private(set) var deviceEndorsement: DeviceEndorsement?

    private static let deviceKeyTag = "seal.deviceKey"
    private static let kemKeyTag = "seal.kemKey"
    static let identityKey = "seal.rootIdentity"        // internal: DemoFixtures swaps/restores it
    static let endorsementKey = "seal.deviceEndorsement"

    var isRegistered: Bool { rootIdentity != nil }

    init() { load() }

    // MARK: - Device key

    /// The non-exportable Secure Enclave P-256 signing key for this device.
    /// Access: this-device-only. NOT biometry-gated — it signs every outgoing
    /// message, so gating is done at app level (Face ID app lock), not per-sign.
    private(set) var deviceKey: SecureEnclave.P256.Signing.PrivateKey?

    @discardableResult
    func createDeviceKey() throws -> SecureEnclave.P256.Signing.PrivateKey {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage],
            &error
        ) else { throw error!.takeRetainedValue() as Error }

        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        KeychainStore.save(key.dataRepresentation, for: Self.deviceKeyTag)
        deviceKey = key

        // X25519 KEM key for sender-chain wrapping (SDS §2). Software key,
        // this-device-only; its public half is published in the endorsement.
        let kem = Curve25519.KeyAgreement.PrivateKey()
        KeychainStore.save(kem.rawRepresentation, for: Self.kemKeyTag)
        kemPrivateKey = kem
        return key
    }

    /// This device's X25519 KEM private key (decrypts wrapped sender keys).
    private(set) var kemPrivateKey: Curve25519.KeyAgreement.PrivateKey?

    var kemPublicKeyData: Data? { kemPrivateKey?.publicKey.rawRepresentation }

    // MARK: - Registration persistence

    func completeRegistration(identity: RootIdentity, endorsement: DeviceEndorsement) {
        rootIdentity = identity
        deviceEndorsement = endorsement
        if let data = try? JSONEncoder().encode(identity) {
            KeychainStore.save(data, for: Self.identityKey)
        }
        if let data = try? JSONEncoder().encode(endorsement) {
            KeychainStore.save(data, for: Self.endorsementKey)
        }
        // TODO(SyncEngine): publish Identity record to CloudKit public DB (FR-4)
    }

    /// Wipe local identity (dev/testing; revocation flow is FR-19).
    func reset() {
        rootIdentity = nil
        deviceEndorsement = nil
        deviceKey = nil
        kemPrivateKey = nil
        KeychainStore.delete(Self.identityKey)
        KeychainStore.delete(Self.endorsementKey)
        KeychainStore.delete(Self.deviceKeyTag)
        KeychainStore.delete(Self.kemKeyTag)
    }

    private func load() {
        if let data = KeychainStore.load(Self.identityKey) {
            rootIdentity = try? JSONDecoder().decode(RootIdentity.self, from: data)
        }
        if let data = KeychainStore.load(Self.endorsementKey) {
            deviceEndorsement = try? JSONDecoder().decode(DeviceEndorsement.self, from: data)
        }
        if let data = KeychainStore.load(Self.deviceKeyTag) {
            deviceKey = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data)
        }
        if let data = KeychainStore.load(Self.kemKeyTag) {
            kemPrivateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
        }
    }

    // MARK: - Verification

    /// Returns the device public keys + KEM keys from `endorsements` whose
    /// signature chain back to `root` actually verifies. Everything else is
    /// dropped — the server is untrusted for integrity (SDS §7).
    static func verifiedDevices(root: RootIdentity, endorsements: [DeviceEndorsement]) -> [DeviceEndorsement] {
        guard let rootPub = try? P256.Signing.PublicKey(rawRepresentation: root.publicKey) else { return [] }
        return endorsements.filter { e in
            guard e.revokedAt == nil,
                  let assertion = try? JSONDecoder().decode(WebAuthnAssertion.self, from: e.assertion),
                  assertion.verify(with: rootPub) else { return false }
            // v2 commitment binds signing AND KEM keys — a directory that
            // swaps either one fails verification.
            let commitment = Data(SHA256.hash(data:
                Data("seal.endorse.v2".utf8) + e.devicePublicKey + e.kemBundlePublicKeys))
            return CeremonyManager.clientDataChallengeMatches(assertion.clientDataJSON, expected: commitment)
        }
    }

    /// Device public keys with a VALID revocation (assertion verifies under
    /// the root key and commits to that device key). Forged revocations are
    /// ignored — only the root key can kill a device.
    static func revokedDevicePublicKeys(root: RootIdentity, revocations: [DeviceRevocation]) -> Set<Data> {
        guard let rootPub = try? P256.Signing.PublicKey(rawRepresentation: root.publicKey) else { return [] }
        var revoked: Set<Data> = []
        for revocation in revocations {
            guard let assertion = try? JSONDecoder().decode(WebAuthnAssertion.self, from: revocation.assertion),
                  assertion.verify(with: rootPub) else { continue }
            let commitment = Data(SHA256.hash(data: Data("seal.revoke.v1".utf8) + revocation.devicePublicKey))
            if CeremonyManager.clientDataChallengeMatches(assertion.clientDataJSON, expected: commitment) {
                revoked.insert(revocation.devicePublicKey)
            }
        }
        return revoked
    }

    /// Verify a full chain: root key → device endorsement → payload signature.
    /// Every inbound record passes through this before reaching the model layer.
    func verify(signature: Data, over payload: Data, deviceKey: Data,
                claimedRoot: RootIdentity, endorsements: [DeviceEndorsement]) -> Bool {
        let trusted = Self.verifiedDevices(root: claimedRoot, endorsements: endorsements)
        guard trusted.contains(where: { $0.devicePublicKey == deviceKey }),
              let pub = try? P256.Signing.PublicKey(x963Representation: deviceKey),
              let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature)
        else { return false }
        return pub.isValidSignature(sig, for: payload)
    }
}
