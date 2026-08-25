import Foundation
import CryptoKit

/// Backup credentials (SRS FR-3, U5; docs/UI.md §3.1) — `seal.backup.v1`.
///
/// Today the identity IS the one WebAuthn credential created at registration.
/// Lose it and the identity is gone forever: there is no server, no account
/// recovery, and by design nobody — not us, not Apple — holds anything that
/// could bring it back. FR-3 is the one legitimate escape hatch: a SECOND
/// credential (another hardware key, or a passkey on a family helper's phone)
/// that the root identity has explicitly endorsed, so a lost or dead key
/// costs you the phone's message history but not the identity itself.
///
/// # What a backup credential is
///
/// A root-signed statement: "the credential with this ID and this public key
/// may act for me." Mechanically it is the SAME shape as the device
/// endorsement (`seal.endorse.v2`) and the device revocation
/// (`seal.revoke.v1`): a WebAuthn assertion from the root credential whose
/// challenge is a domain-separated hash committing to exactly the thing being
/// authorised. Verification is therefore the same discipline as everywhere
/// else in Seal — the directory is untrusted, and every client recomputes the
/// commitment itself (SDS §7).
///
///     commitment = SHA256("seal.backup.v1" ‖ credentialID ‖ publicKey)
///
/// Both halves are in the commitment on purpose. Committing to the credential
/// ID alone would let a tampered directory keep the ID and swap the public
/// key, which is a total takeover: the attacker's key would then be able to
/// endorse devices in your name. Committing to the public key alone would let
/// the directory re-point the ID, which breaks sign-in in a confusing way.
/// Binding both is the same reasoning that made `seal.endorse.v2` commit to
/// the signing key AND the KEM key (the MITM fix in HANDOFF).
///
/// # What a backup credential can do
///
/// Sign in, and — because sign-in endorses the phone it is run on — endorse a
/// device key. That pair IS the recovery: tap the backup key on a new phone
/// and the identity, the friendships, and the directory entry all come back.
/// Peers accept the resulting device endorsement because
/// `IdentityManager.verifiedDevices` verifies against the AUTHORITY SET —
/// the root credential plus every non-revoked backup — rather than the root
/// alone. That widening is the whole reason this type exists; see the long
/// note there for the compatibility consequence.
///
/// # What a backup credential deliberately CANNOT do
///
/// - **It cannot revoke anything.** Revocation authority stays with the root
///   credential in v1. The asymmetry is deliberate and load-bearing: if a
///   backup key could revoke the root, then STEALING a backup key would be a
///   full account takeover *with eviction of the real owner* — strictly worse
///   than the situation FR-3 is fixing. A backup key carries the identity
///   forward; it never demotes the credential that created it. The honest
///   consequence, which the UI states in these words, is that a main key that
///   was STOLEN rather than lost cannot be evicted: delete the identity and
///   start fresh. Symmetric co-root revocation needs a quorum design and is
///   explicitly a v2 problem, not something to improvise here.
/// - **It cannot recover message history.** Per-message keys are ratcheted
///   forward and destroyed after use (SDS §2), and the sender chains that
///   would re-derive them were wrapped to device KEM keys that died with the
///   lost phone. No key held anywhere can bring those bytes back. The UI says
///   so plainly rather than letting "backup" imply a backup of messages.
struct BackupCredential: Codable, Hashable, Identifiable {
    /// Raw WebAuthn credential ID of the backup authenticator. Public, not
    /// secret — it is what goes in an assertion's allow-list and in
    /// `excludedCredentials` at registration.
    let credentialID: Data
    /// P-256 public key, raw representation — the key that signs assertions
    /// made by this credential.
    let publicKey: Data
    /// Which authenticator this is, for the UI only. Brass = hardware key,
    /// silver = passkey, exactly as the root tier renders (UI.md §1.1).
    /// NOT part of the commitment: it is a label, and a lie about it would
    /// change nothing a signature depends on.
    let tier: IdentityTier
    /// Human label ("Mom's key", "Backup in the safe"). Metadata only, same
    /// status as `RootIdentity.displayName` — never in any commitment, so
    /// renaming a backup key can never affect verification.
    var label: String
    /// `WebAuthnAssertion` (JSON) from the ROOT credential over
    /// `endorsementCommitment` — "I, this root, authorise that credential."
    let assertion: Data
    /// `WebAuthnAssertion` (JSON) from the BACKUP credential itself over
    /// `acceptanceCommitment` — "I, that credential, belong to this root."
    ///
    /// Without this half the statement is one-sided, and a one-sided
    /// statement is forgeable in a public directory: a credential ID and a
    /// public key are both PUBLIC the moment a backup is published, so any
    /// identity could put another person's backup credential in its own
    /// record, signed by its own root, and it would verify. A tap of that key
    /// would then resolve to the attacker's identity. Requiring a signature
    /// from the credential itself, over a commitment naming the root that
    /// claims it, makes the binding mutual and unforgeable without the
    /// backup key's private half.
    let acceptance: Data
    let createdAt: Date

    var id: String { credentialIDHash }

    /// SHA256 of the credential ID, hex — the same identifier shape sign-in
    /// derives from a tapped credential, which is how a backup tap is
    /// resolved back to the identity that endorsed it.
    var credentialIDHash: String { Data(SHA256.hash(data: credentialID)).hexString }

    // MARK: - Commitments

    /// Challenge the ROOT credential signs to authorise a backup credential.
    static func endorsementCommitment(credentialID: Data, publicKey: Data) -> Data {
        Data(SHA256.hash(data: Data("seal.backup.v1".utf8) + credentialID + publicKey))
    }

    /// Challenge the BACKUP credential signs to accept being a backup for a
    /// specific identity. `rootIDHash` is in the commitment so the acceptance
    /// cannot be lifted out of one identity's record and replayed in
    /// another's — the credential agreed to back up THIS root, not any root.
    ///
    /// Unambiguous by construction: the hash is
    /// domain ‖ 64-hex-char root ID ‖ credentialID ‖ 64-byte public key, and
    /// the only variable-length part sits between two fixed-length ones, so
    /// no two different (rootIDHash, credentialID, publicKey) triples share an
    /// input. `verified` additionally asserts the 64-byte key length rather
    /// than leaning on the parse that happens to precede it.
    static func acceptanceCommitment(rootIDHash: String, credentialID: Data, publicKey: Data) -> Data {
        Data(SHA256.hash(data: Data("seal.backup.accept.v1".utf8)
                         + Data(rootIDHash.utf8) + credentialID + publicKey))
    }

    /// Challenge the ROOT credential signs to kill a backup credential.
    ///
    /// Domain-separated from `seal.revoke.v1` (devices) even though both are
    /// stored in the same `revocations` list and both commit to a public key.
    /// Today the two could not be confused — device keys are 65-byte x963 and
    /// credential keys are 64-byte raw — but that is a coincidence of
    /// encoding, not an invariant anyone is maintaining. If a later change
    /// made the encodings agree, a single shared domain would silently allow
    /// a statement signed about one to be replayed as a statement about the
    /// other. A distinct domain costs nothing and removes the question.
    static func revocationCommitment(publicKey: Data) -> Data {
        Data(SHA256.hash(data: Data("seal.backup.revoke.v1".utf8) + publicKey))
    }

    // MARK: - Verification

    /// The backups in `backups` that actually verify under `root` and are not
    /// revoked. Everything else is dropped: the directory is untrusted, so a
    /// forged or altered entry must fail closed rather than widen the set of
    /// keys allowed to act for this identity (SDS §7).
    ///
    /// `revokedPublicKeys` comes from `IdentityManager.revokedBackupPublicKeys`
    /// over the SAME record's revocation list, so a revoked backup disappears
    /// from every consumer at once instead of each caller remembering to
    /// filter.
    static func verified(_ backups: [BackupCredential],
                         root: RootIdentity,
                         revokedPublicKeys: Set<Data>) -> [BackupCredential] {
        guard let rootPub = try? P256.Signing.PublicKey(rawRepresentation: root.publicKey) else { return [] }
        return backups.filter { backup in
            guard !revokedPublicKeys.contains(backup.publicKey),
                  // Fixed 64-byte raw P-256 key, asserted rather than assumed:
                  // it is what makes both commitments unambiguous, and a key
                  // that doesn't parse could never verify anything later
                  // anyway.
                  backup.publicKey.count == 64,
                  let backupPub = try? P256.Signing.PublicKey(rawRepresentation: backup.publicKey),
                  let endorsement = try? JSONDecoder().decode(WebAuthnAssertion.self, from: backup.assertion),
                  let acceptance = try? JSONDecoder().decode(WebAuthnAssertion.self, from: backup.acceptance)
            else { return false }

            // Half one: the ROOT authorised this credential.
            guard endorsement.verify(with: rootPub),
                  CeremonyManager.clientDataChallengeMatches(
                    endorsement.clientDataJSON,
                    expected: endorsementCommitment(credentialID: backup.credentialID,
                                                    publicKey: backup.publicKey))
            else { return false }

            // Half two: the CREDENTIAL accepted this root. Both halves are
            // required — see the note on `acceptance`. Verified with the
            // backup's own key, and the commitment names the root, so neither
            // half can be transplanted into another identity's record.
            return acceptance.verify(with: backupPub)
                && CeremonyManager.clientDataChallengeMatches(
                    acceptance.clientDataJSON,
                    expected: acceptanceCommitment(rootIDHash: root.credentialIDHash,
                                                   credentialID: backup.credentialID,
                                                   publicKey: backup.publicKey))
        }
    }
}
