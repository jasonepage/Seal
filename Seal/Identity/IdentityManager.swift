import Foundation
import CryptoKit

/// Owns the local user's root identity, Secure Enclave device key,
/// and verification of endorsement chains (SDS §2, §3).
@Observable
final class IdentityManager {
    private(set) var rootIdentity: RootIdentity?
    private(set) var deviceEndorsement: DeviceEndorsement?

    // Device + KEM keys are scoped to the identity hash so the SAME phone
    // keeps the SAME device key across sign-out (re-login reclaims its slot
    // instead of minting a duplicate), while a DIFFERENT identity on this
    // phone gets its own key (no cross-identity device-key linkage).
    private static func deviceKeyTag(_ hash: String) -> String { "seal.deviceKey.\(hash)" }
    private static func kemKeyTag(_ hash: String) -> String { "seal.kemKey.\(hash)" }
    // Legacy un-scoped tags (pre-scoping builds) — migrated once on load.
    private static let legacyDeviceKeyTag = "seal.deviceKey"
    private static let legacyKemKeyTag = "seal.kemKey"
    static let identityKey = "seal.rootIdentity"        // internal: DemoFixtures swaps/restores it
    static let endorsementKey = "seal.deviceEndorsement"

    var isRegistered: Bool { rootIdentity != nil }

    init() { load() }

    // MARK: - Device key

    /// The non-exportable Secure Enclave P-256 signing key for this device.
    /// Access: this-device-only. NOT biometry-gated — it signs every outgoing
    /// message, so gating is done at app level (Face ID app lock), not per-sign.
    private(set) var deviceKey: SecureEnclave.P256.Signing.PrivateKey?

    /// Mint a fresh device key + KEM key for `identityHash`. Use during
    /// registration (genuinely new device). For sign-in prefer
    /// `loadOrCreateDeviceKey(for:)`, which reuses an existing key.
    @discardableResult
    func createDeviceKey(for identityHash: String) throws -> SecureEnclave.P256.Signing.PrivateKey {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage],
            &error
        ) else { throw error!.takeRetainedValue() as Error }

        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        KeychainStore.save(key.dataRepresentation, for: Self.deviceKeyTag(identityHash))
        deviceKey = key

        // X25519 KEM key for sender-chain wrapping (SDS §2). Software key,
        // this-device-only; its public half is published in the endorsement.
        let kem = Curve25519.KeyAgreement.PrivateKey()
        KeychainStore.save(kem.rawRepresentation, for: Self.kemKeyTag(identityHash))
        kemPrivateKey = kem
        return key
    }

    /// Reuse this phone's existing device key for `identityHash` if the
    /// keychain still holds it (survives sign-out), otherwise mint one. This
    /// is what keeps a returning phone from being counted as a NEW device:
    /// the device public key stays stable, so `publishIdentity` dedupes the
    /// endorsement by it instead of appending a ghost.
    @discardableResult
    func loadOrCreateDeviceKey(for identityHash: String) throws -> SecureEnclave.P256.Signing.PrivateKey {
        guard let data = KeychainStore.load(Self.deviceKeyTag(identityHash)),
              let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data) else {
            return try createDeviceKey(for: identityHash)
        }
        deviceKey = key
        if let kemData = KeychainStore.load(Self.kemKeyTag(identityHash)) {
            kemPrivateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: kemData)
        }
        // Device key present but KEM somehow missing → mint a KEM so the
        // endorsement can still commit to a valid encryption key.
        if kemPrivateKey == nil {
            let kem = Curve25519.KeyAgreement.PrivateKey()
            KeychainStore.save(kem.rawRepresentation, for: Self.kemKeyTag(identityHash))
            kemPrivateKey = kem
        }
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

    /// Change the display name after registration and persist it. The name is
    /// metadata only — it's NOT part of any signature, the endorsement
    /// commitment, or the credential hash — so renaming never affects
    /// verification or identity. The caller republishes the Identity record so
    /// friends pick up the new name on their next directory fetch.
    func updateDisplayName(_ newName: String) {
        guard var root = rootIdentity else { return }
        root.displayName = newName
        rootIdentity = root
        if let data = try? JSONEncoder().encode(root) {
            KeychainStore.save(data, for: Self.identityKey)
        }
    }

    /// Reviewer/demo access (FR-22): install the fully-local demo account and
    /// load it, so the app drops straight into demo without a key or Face ID.
    /// Gated behind the access code in RegistrationView — never the default.
    func activateDemo() {
        DemoFixtures.activate()   // seeds the demo identity + friends + chats
        load()                    // pull the just-installed demo identity into rootIdentity
    }

    /// Sign out: forget the identity on this device but KEEP this device's
    /// Secure Enclave + KEM keys in the keychain, so signing back into the
    /// SAME identity is recognized as the SAME device (no ghost). Local
    /// chats/friends are wiped by the caller. Use `reset()` for full deletion.
    func signOut() {
        rootIdentity = nil
        deviceEndorsement = nil
        deviceKey = nil          // in-memory only — keychain copy survives
        kemPrivateKey = nil
        KeychainStore.delete(Self.identityKey)
        KeychainStore.delete(Self.endorsementKey)
    }

    /// Full wipe (account deletion / hard reset): everything signOut clears
    /// PLUS this identity's device + KEM keys, so nothing of this identity
    /// remains on the device. (Revocation flow is FR-19.)
    func reset() {
        let hash = rootIdentity?.credentialIDHash
        rootIdentity = nil
        deviceEndorsement = nil
        deviceKey = nil
        kemPrivateKey = nil
        KeychainStore.delete(Self.identityKey)
        KeychainStore.delete(Self.endorsementKey)
        if let hash {
            KeychainStore.delete(Self.deviceKeyTag(hash))
            KeychainStore.delete(Self.kemKeyTag(hash))
        }
        // Legacy un-scoped keys, if any, go too.
        KeychainStore.delete(Self.legacyDeviceKeyTag)
        KeychainStore.delete(Self.legacyKemKeyTag)
    }

    private func load() {
        if let data = KeychainStore.load(Self.identityKey) {
            rootIdentity = try? JSONDecoder().decode(RootIdentity.self, from: data)
        }
        if let data = KeychainStore.load(Self.endorsementKey) {
            deviceEndorsement = try? JSONDecoder().decode(DeviceEndorsement.self, from: data)
        }
        guard let hash = rootIdentity?.credentialIDHash else { return }
        // One-time migration: a pre-scoping build stored this device's key
        // under the legacy un-scoped tag. Move it under the current identity
        // so the existing install keeps its device slot instead of orphaning.
        if KeychainStore.load(Self.deviceKeyTag(hash)) == nil,
           let legacy = KeychainStore.load(Self.legacyDeviceKeyTag) {
            KeychainStore.save(legacy, for: Self.deviceKeyTag(hash))
            if let legacyKem = KeychainStore.load(Self.legacyKemKeyTag) {
                KeychainStore.save(legacyKem, for: Self.kemKeyTag(hash))
            }
            KeychainStore.delete(Self.legacyDeviceKeyTag)
            KeychainStore.delete(Self.legacyKemKeyTag)
        }
        if let data = KeychainStore.load(Self.deviceKeyTag(hash)) {
            deviceKey = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data)
        }
        if let data = KeychainStore.load(Self.kemKeyTag(hash)) {
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
