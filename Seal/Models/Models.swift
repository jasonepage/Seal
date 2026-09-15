import Foundation

/// Identity tier per SRS FR-21.
enum IdentityTier: String, Codable {
    case verified   // FIDO2 hardware key
    case passkey    // platform passkey (Face ID)
}

/// A user's root identity: their WebAuthn credential public key.
struct RootIdentity: Codable, Identifiable, Hashable {
    var id: String { credentialIDHash }
    let credentialIDHash: String        // record name in the public DB
    let publicKey: Data                 // P-256, raw representation
    let tier: IdentityTier
    var displayName: String
    /// Raw WebAuthn credential ID, needed to request assertions from this
    /// identity's authenticator (friend ceremony). Public, not secret.
    var rawCredentialID: Data?
    /// Backup credentials this root has endorsed (FR-3, `seal.backup.v1`, 
    /// see BackupCredential.swift), as published in the directory and already
    /// signature-checked and revocation-filtered by `SyncEngine.fetchIdentity`.
    ///
    /// It lives ON the identity rather than beside it so that the AUTHORITY
    /// SET travels wherever the identity does. Every existing consumer of
    /// `IdentityManager.verifiedDevices` (the estate log verifier, the
    /// receipts view) then accepts a device endorsement signed by a backup
    /// key without a single call site changing.
    /// Passing them as a separate argument would have meant five call sites
    /// each remembering to thread them through, and one forgotten thread is a
    /// recovered phone whose messages silently fail to verify.
    ///
    /// Optional with a `nil` default so identities already sitting in the
    /// keychain still decode, and so the memberwise initialiser stays
    /// source-compatible with every existing caller (same reasoning as
    /// `Friendship.autoReciprocated`).
    var backupCredentials: [BackupCredential]? = nil
}

/// The verifiable payload inside Friendship.attestation: enough to recompute
/// the challenge commitment and re-verify the friend's signature at any time.
struct FriendshipAttestation: Codable, Hashable {
    let nonce: Data
    let timestamp: Date
    let assertion: WebAuthnAssertion
}

/// Hardware/passkey-signed certificate binding a device key to a root identity (SDS §2).
///
/// Security fix 3 of 4: this struct used to carry an unsigned `revokedAt`
/// field that `verifiedDevices` treated as authoritative, so anyone able to
/// write an Identity record could un-verify every device on it with no key.
/// The field is GONE from the type. Old JSON that still carries it decodes
/// fine (unknown keys are ignored) and the value is discarded. The only
/// revocation channel is a root-signed `DeviceRevocation`.
struct DeviceEndorsement: Codable, Hashable {
    let devicePublicKey: Data           // Secure Enclave P-256 signing key, x963
    /// KEM public material this device can be wrapped to. For endorsements
    /// created before the estate work this is a raw 32 byte X25519 key. For
    /// v3 endorsements it may be a `KEMBundle` encoding carrying X25519 and
    /// ML-KEM-768 (see Crypto/KEMBundle.swift); `KEMBundle.parse` tells the
    /// two apart by length.
    let kemBundlePublicKeys: Data
    let assertion: Data                 // WebAuthn assertion committing to devicePublicKey
    let createdAt: Date
}

/// Root-key-signed revocation of a device (FR-19). Clients treat the device
/// as invalid; its endorsement is dropped from every verification path.
struct DeviceRevocation: Codable, Hashable {
    let devicePublicKey: Data
    let assertion: Data                 // WebAuthnAssertion committing to the device key
    let revokedAt: Date
}

/// Mutual, in-person friendship attestation (SRS FR-5/FR-6).
struct Friendship: Codable, Identifiable, Hashable {
    var id: String { friendRootID }
    let friendRootID: String
    let attestation: Data               // friend's assertion over our challenge
    let reverseAttestation: Data?       // our assertion held by them; both required for invites
    let forgedAt: Date
    /// True when THIS side of the edge was completed automatically from the
    /// other party's ForgeHandshake instead of by a ceremony on this phone.
    /// Such an edge proves the peer's intent, not their physical presence, so
    /// ForgeRank must weight it below a real forge (docs/TRUST.md §5.1) and the
    /// UI should not present it as a full brass ceremony. Optional with a
    /// default so friendships already in the keychain still decode, and so the
    /// memberwise initialiser stays source-compatible with existing callers.
    var autoReciprocated: Bool? = nil
    /// Every friendship is in person now: the remote "introduction" path was
    /// retired with the messenger, and its proof field with it. Old keychain
    /// entries that carried one still decode (the key is ignored).
    var isInPerson: Bool { true }
}

/// Signed, append-only membership log entry (SDS §4).
struct MembershipRecord: Codable, Hashable {
    enum Action: String, Codable { case add, remove, promote }
    let action: Action
    let subjectRootID: String
    let actorDeviceKey: Data
    let epoch: UInt64
    let signature: Data
    let timestamp: Date
}

struct SealGroup: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var epoch: UInt64
    var membershipLog: [MembershipRecord]
    var verifiedOnly: Bool
    var ephemeralTTL: TimeInterval?     // nil = persistent (FR-12)
}

struct Message: Codable, Identifiable, Hashable {
    let id: UUID
    let groupID: UUID
    let senderRootID: String
    let epoch: UInt64
    let chainIndex: UInt64
    let ciphertext: Data
    let previousMessageHash: Data       // per-sender transcript chain (SDS §2)
    let signature: Data
    let sentAt: Date
    var expiresAt: Date?
}
