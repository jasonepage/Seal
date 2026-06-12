import Foundation
import CryptoKit

/// Owns the local user's root identity, Secure Enclave device key,
/// and verification of endorsement chains (SDS §2, §3).
@Observable
final class IdentityManager {
    private(set) var rootIdentity: RootIdentity?
    private(set) var deviceEndorsement: DeviceEndorsement?

    private static let deviceKeyTag = "seal.deviceKey"
    private static let identityKey = "seal.rootIdentity"
    private static let endorsementKey = "seal.deviceEndorsement"

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
        return key
    }

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
        KeychainStore.delete(Self.identityKey)
        KeychainStore.delete(Self.endorsementKey)
        KeychainStore.delete(Self.deviceKeyTag)
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
    }

    // MARK: - Verification

    /// Verify a full chain: root key → device endorsement → record signature.
    /// Every inbound record passes through this before reaching the model layer.
    func verify(signature: Data, over payload: Data, deviceKey: Data, claimedRoot: RootIdentity) -> Bool {
        // TODO: 1. find unrevoked DeviceEndorsement for deviceKey in claimedRoot
        //       2. verify endorsement assertion against claimedRoot.publicKey
        //          (WebAuthnAssertion.verify + challenge commitment check)
        //       3. verify signature over payload with deviceKey
        false
    }
}
