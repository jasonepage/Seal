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
    /// Raw WebAuthn credential ID — needed to request assertions from this
    /// identity's authenticator (friend ceremony). Public, not secret.
    var rawCredentialID: Data?
}

/// The verifiable payload inside Friendship.attestation: enough to recompute
/// the challenge commitment and re-verify the friend's signature at any time.
struct FriendshipAttestation: Codable, Hashable {
    let nonce: Data
    let timestamp: Date
    let assertion: WebAuthnAssertion
}

/// Hardware/passkey-signed certificate binding a device key to a root identity (SDS §2).
struct DeviceEndorsement: Codable, Hashable {
    let devicePublicKey: Data           // Secure Enclave P-256 signing key
    let kemBundlePublicKeys: Data       // X25519 + ML-KEM-768 public keys, SE-signed
    let assertion: Data                 // WebAuthn assertion committing to devicePublicKey
    let createdAt: Date
    var revokedAt: Date?
}

/// Mutual, in-person friendship attestation (SRS FR-5/FR-6).
struct Friendship: Codable, Identifiable, Hashable {
    var id: String { friendRootID }
    let friendRootID: String
    let attestation: Data               // friend's assertion over our challenge
    let reverseAttestation: Data?       // our assertion held by them; both required for invites
    let forgedAt: Date
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
