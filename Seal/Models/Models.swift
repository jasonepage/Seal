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
    /// Backup credentials this root has endorsed (FR-3, `seal.backup.v1` —
    /// see BackupCredential.swift), as published in the directory and already
    /// signature-checked and revocation-filtered by `SyncEngine.fetchIdentity`.
    ///
    /// It lives ON the identity rather than beside it so that the AUTHORITY
    /// SET travels wherever the identity does. Every existing consumer of
    /// `IdentityManager.verifiedDevices` — ChatEngine's receive path, the perk
    /// verifier, the receipts view — then accepts a device endorsement signed
    /// by a backup key without a single call site changing, and ChatEngine's
    /// directory cache carries the backups along with the root it caches.
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
struct DeviceEndorsement: Codable, Hashable {
    let devicePublicKey: Data           // Secure Enclave P-256 signing key
    let kemBundlePublicKeys: Data       // X25519 + ML-KEM-768 public keys, SE-signed
    let assertion: Data                 // WebAuthn assertion committing to devicePublicKey
    let createdAt: Date
    var revokedAt: Date?
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
    /// The signed remote vouch that created this friendship, if one did
    /// (Seal/Introductions/Introduction.swift, docs/INTRODUCTIONS.md).
    ///
    /// **Non-nil is what MAKES a friendship LINKED.** There is deliberately no
    /// separate tier field: a tier and its evidence stored as two values can
    /// drift into disagreeing, and the safe direction — "no proof, no linked
    /// tier" — is the only one this shape can express. Every friendship
    /// already in the keychain decodes with nil, which is correct: they all
    /// came from a ceremony.
    ///
    /// A linked friendship is NEVER brass and never reads "Verified". It says
    /// exactly what it is: someone this phone met in person vouched for the
    /// connection. See `isInPerson`.
    var introduction: IntroductionProof? = nil

    /// True when this edge came from a physical ceremony rather than a remote
    /// vouch — the gate on introducing, on brass styling, and on ForgeRank
    /// weight (docs/TRUST.md §5.1).
    ///
    /// `autoReciprocated` edges COUNT as in-person. They are weaker as proof
    /// TO THIS DEVICE (the peer's phone witnessed the tap; ours holds their
    /// signed word for it — ForgeHandshake.swift), but they are still the
    /// record of a meeting that physically happened, not a remote vouch.
    /// Excluding them would forbid introducing to exactly the person this
    /// feature exists for: whoever taps THEIR key on somebody else's phone
    /// ends up holding nothing but auto-reciprocal edges, and Mom introducing
    /// her son to her sister is the entire use case.
    var isInPerson: Bool { introduction == nil }
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

// MARK: - Founder perks (PerkGrant / PerkClaim, SDS §10)

/// Perk editions. Founder is an EDITION of a tier, never a third tier —
/// ring color stays tier-determined everywhere.
enum PerkKind: String, Codable, Hashable {
    case founder                            // numbered 1–100, hard-capped in PerkAuthority
    case campusFounder = "campus-founder"   // unnumbered campus-ambassador edition

    func displayLabel(number: Int?) -> String {
        switch self {
        case .founder: number.map { "Founder № \($0)" } ?? "Founder"
        case .campusFounder: "Campus founder"
        }
    }
}

/// Founder-key-signed grant minted offline (tools/mint_perks.py) and placed
/// in the public DB at record name `perk.<codeHashHex>`. The signature commits
/// to the code hash, so a grant can't be replayed under a different code.
/// Unix-second timestamps keep the signed message byte-identical between the
/// Python minter and Swift verification.
struct PerkGrant: Codable, Hashable {
    let kind: PerkKind
    let number: Int?                    // required 1–100 for .founder, nil otherwise
    let codeHashHex: String             // SHA256(normalized claim code), lowercase hex
    let issuedAtUnix: Int64
    let signature: Data                 // founder P-256 ECDSA (DER) over PerkAuthority.grantMessage
}

/// Device-key-signed claim binding a verified grant to a root identity.
/// Written once as record `pclaim.<codeHashHex>` (first creator wins) and
/// appended to the claimant's Identity record so friends' clients can verify.
struct PerkClaim: Codable, Hashable {
    let codeHashHex: String
    let rootID: String                  // claimant's credentialIDHash
    let devicePublicKey: Data           // the endorsed device key that signed
    let claimedAtUnix: Int64
    let signature: Data                 // device-key ECDSA (DER) over PerkAuthority.claimMessage
}

/// What travels in Identity.perks: the grant + the claim, verified together
/// (founder signature, code-hash match, claim chains to an endorsed device).
struct PerkAttestation: Codable, Hashable {
    let grant: PerkGrant
    let claim: PerkClaim
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
