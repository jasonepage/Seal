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
        // Persist WITHOUT the backup credentials (FR-3). Everything else on a
        // RootIdentity is stable, but the authority set is revocable, and a
        // keychain copy is never re-filtered against the revocation list — it
        // would still name a revoked backup as an authorised endorser on the
        // next launch, and the next, forever. The in-memory value keeps them
        // for this session; anything that verifies uses the freshly fetched
        // identity, where `fetchIdentity` has just applied revocations.
        var persisted = identity
        persisted.backupCredentials = nil
        if let data = try? JSONEncoder().encode(persisted) {
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

    // MARK: - Endorsement commitments

    /// Commitment a root (or backup) credential signs to endorse a device.
    ///
    /// v3 length-frames both values. v2 did not: `SHA256(domain ‖ D ‖ K)` with
    /// two variable-length values means `(D, K)` and `(D‖K[0..<n], K[n...])`
    /// hash identically, so ONE root signature authorises many splits. The
    /// live consequence was revocation evasion — re-split a revoked
    /// endorsement as `devicePublicKey = D‖K`, and it still verifies while no
    /// longer byte-matching the revocation entry that killed it, so a dead
    /// device walks again. It also shifts which bytes `HybridKEM.wrapToAll`
    /// treats as a KEM key.
    ///
    /// `CustodyReceipt.commitment` already did this correctly — UInt32BE per
    /// field — and is the model this follows.
    static func endorsementCommitment(devicePublicKey: Data, kemBundlePublicKeys: Data) -> Data {
        var input = Data("seal.endorse.v3".utf8)
        func field(_ data: Data) {
            var length = UInt32(data.count).bigEndian
            withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
            input.append(data)
        }
        field(devicePublicKey)
        field(kemBundlePublicKeys)
        return Data(SHA256.hash(data: input))
    }

    /// The unframed v2 commitment. Still ACCEPTED during the migration window
    /// so that every endorsement published before v3 keeps verifying — an
    /// endorsement that stops verifying is a phone that can talk to nobody.
    /// Nothing creates v2 any more. Drop this once the family is known to be
    /// on a v3 build and every directory record has been re-endorsed (a
    /// sign-in on each phone rewrites it).
    static func legacyEndorsementCommitmentV2(devicePublicKey: Data, kemBundlePublicKeys: Data) -> Data {
        Data(SHA256.hash(data: Data("seal.endorse.v2".utf8) + devicePublicKey + kemBundlePublicKeys))
    }

    /// Every credential allowed to endorse a device for this identity: the
    /// root credential, plus each backup credential the root has endorsed and
    /// not revoked (FR-3, `seal.backup.v1`).
    ///
    /// Returned as (credential ID, public key) pairs because an endorsement's
    /// assertion names the credential that produced it, which lets
    /// `verifiedDevices` check exactly one signature instead of trying each
    /// authority in turn. Credential ID is nil only for the root of an
    /// identity registered before credential publishing (the same population
    /// `CeremonyError.missingCredentialID` already speaks about).
    static func authorityKeys(for root: RootIdentity) -> [(credentialID: Data?, publicKey: P256.Signing.PublicKey)] {
        // Element type spelled with its labels: an array of unlabelled tuples
        // is a DIFFERENT type here, not an implicit conversion.
        var keys: [(credentialID: Data?, publicKey: P256.Signing.PublicKey)] = []
        if let rootPub = try? P256.Signing.PublicKey(rawRepresentation: root.publicKey) {
            keys.append((credentialID: root.rawCredentialID, publicKey: rootPub))
        }
        // Re-verify the root signature on every backup rather than trusting
        // whoever assembled this RootIdentity: a hand-constructed or
        // tampered-with entry must not be able to widen the set of keys that
        // may speak for an identity. What this canNOT re-check is REVOCATION,
        // which lives in the record's revocation list, not on the identity —
        // so a backup revoked a moment ago stays trusted until the next
        // directory fetch. That is the same staleness window a revoked DEVICE
        // has today, and it self-heals through the same path: ChatEngine
        // refetches with `forceRefresh` on a verify miss, and every fresh
        // `fetchIdentity` strips revoked backups before they get here.
        for backup in verifiedBackups(for: root) {
            if let pub = try? P256.Signing.PublicKey(rawRepresentation: backup.publicKey) {
                keys.append((credentialID: backup.credentialID, publicKey: pub))
            }
        }
        return keys
    }

    /// The backup credentials on `root` whose root signature actually checks
    /// out. Revocation filtering happens upstream in `fetchIdentity`, which is
    /// where the revocation list lives.
    static func verifiedBackups(for root: RootIdentity) -> [BackupCredential] {
        guard let backups = root.backupCredentials, !backups.isEmpty else { return [] }
        return BackupCredential.verified(backups, root: root, revokedPublicKeys: [])
    }

    /// Returns the device public keys + KEM keys from `endorsements` whose
    /// signature chain back to `root` actually verifies. Everything else is
    /// dropped — the server is untrusted for integrity (SDS §7).
    ///
    /// **The endorsing credential may be the root OR a backup credential**
    /// (FR-3). That is the entire point of a backup key: sign-in endorses the
    /// phone it runs on, so a person recovering onto a new phone with their
    /// backup key produces a device endorsement signed by the BACKUP. If this
    /// function still demanded the root's signature, that endorsement would be
    /// dropped by every peer and the recovered phone would be able to send
    /// nothing anyone could verify — recovery that silently does not work.
    ///
    /// **Compatibility, stated plainly:** a build older than backup keys
    /// verifies against the root credential only, so it will NOT accept a
    /// backup-signed device endorsement. A recovered phone can talk to peers
    /// on this build or newer; older peers drop its messages the same way they
    /// dropped an unknown device key before. This is the same class of break
    /// as the `wrapToAll` envelope change (HANDOFF, 6/26) and has the same
    /// answer: the family updates together.
    static func verifiedDevices(root: RootIdentity, endorsements: [DeviceEndorsement]) -> [DeviceEndorsement] {
        let authorities = authorityKeys(for: root)
        guard !authorities.isEmpty else { return [] }
        return endorsements.filter { e in
            // NOTE: `e.revokedAt` is deliberately NOT consulted. It is a plain
            // field inside the directory-supplied blob, covered by no
            // signature, and it used to be the FIRST condition here — so
            // anyone able to write an Identity record could set it on every
            // endorsement and un-verify every device of that identity, with no
            // key, no revocation record and no signature. Worse, the symptom
            // is indistinguishable from the 6/26 desync, so it would have been
            // triaged as a regression. The only trustworthy revocation channel
            // is `revokedDevicePublicKeys` — root-signed, domain-separated,
            // already applied by `fetchIdentity` before anything reaches here.
            // (The app never writes a non-nil value: both construction sites
            // pass nil. The field only ever served an attacker.)
            guard let assertion = try? JSONDecoder().decode(WebAuthnAssertion.self, from: e.assertion)
            else { return false }
            // The commitment binds signing AND KEM keys — a directory that
            // swaps either one fails verification. v3 (length-framed) is what
            // this build creates; v2 is accepted for endorsements published
            // before the framing fix. See endorsementCommitment.
            let v3 = endorsementCommitment(devicePublicKey: e.devicePublicKey,
                                           kemBundlePublicKeys: e.kemBundlePublicKeys)
            let v2 = legacyEndorsementCommitmentV2(devicePublicKey: e.devicePublicKey,
                                                   kemBundlePublicKeys: e.kemBundlePublicKeys)
            guard CeremonyManager.clientDataChallengeMatches(assertion.clientDataJSON, expected: v3)
                    || CeremonyManager.clientDataChallengeMatches(assertion.clientDataJSON, expected: v2)
            else { return false }
            // Prefer the authority the assertion actually names. Trying every
            // authority in turn would also work, but each failed attempt logs
            // a "did NOT match the directory public key" error, and a healthy
            // backup-signed endorsement would print one of those on the root
            // attempt every time — exactly the misleading noise the messaging
            // os-log category exists to avoid. Fall back to trying them all
            // only when the ID matches nothing (pre-credential-publishing
            // identities, where rawCredentialID is nil).
            // FALL THROUGH on failure, never `return` on it: `credentialID`
            // is a sibling field in the assertion blob and is NOT covered by
            // the signature, so a directory that flips it could otherwise
            // point verification at the wrong authority and have the endorsement
            // dropped — silently killing exactly the phone recovery creates.
            if let named = authorities.first(where: { $0.credentialID == assertion.credentialID }),
               assertion.verify(with: named.publicKey) {
                return true
            }
            return authorities.contains { assertion.verify(with: $0.publicKey) }
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

    /// Backup credential public keys with a VALID revocation — a root-signed
    /// assertion committing to that credential under `seal.backup.revoke.v1`.
    /// Same shape and same discipline as `revokedDevicePublicKeys`, in the
    /// same `revocations` list on the record, with its own domain string so
    /// the two statements can never stand in for one another.
    ///
    /// Only the ROOT can sign these: a backup credential revokes nothing in
    /// v1, because a stolen backup that could evict the real owner would be
    /// worse than the key loss this feature exists to survive. See
    /// BackupCredential.swift for the full argument.
    static func revokedBackupPublicKeys(root: RootIdentity, revocations: [DeviceRevocation]) -> Set<Data> {
        guard let rootPub = try? P256.Signing.PublicKey(rawRepresentation: root.publicKey) else { return [] }
        var revoked: Set<Data> = []
        for revocation in revocations {
            guard let assertion = try? JSONDecoder().decode(WebAuthnAssertion.self, from: revocation.assertion),
                  assertion.verify(with: rootPub) else { continue }
            let commitment = BackupCredential.revocationCommitment(publicKey: revocation.devicePublicKey)
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
