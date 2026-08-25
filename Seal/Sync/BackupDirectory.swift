import Foundation
import CloudKit
import CryptoKit
import os

/// Directory half of backup credentials (FR-3, `seal.backup.v1` — see
/// Seal/Identity/BackupCredential.swift for the trust argument).
///
/// # Where a backup credential is stored
///
/// In a NEW field, `backupEndorsements`, on the EXISTING `Identity` record.
/// No new record type, and deliberately not squeezed into `deviceEndorsements`
/// alongside real devices: that array is iterated by `HybridKEM.wrapToAll` and
/// by the verified-endorsement set, and a WebAuthn credential is not a device
/// with a KEM key. Every consumer would need a filter, and one missed filter
/// is either a send failure or a verification hole — the exact class of bug
/// behind the 6/26 desync. A field is cheap; a silently overloaded array is
/// not.
///
/// **This field must exist in the CloudKit schema before any of it works.**
/// Exercise it in the Development environment, then Deploy Schema to
/// Production, per the standing rule in HANDOFF. Everything here is written to
/// fail safely until then: reads treat an absent field as "no backups", the
/// directory scan falls back to the legacy key set, and account deletion never
/// writes the field unless it already exists. The one thing that genuinely
/// cannot work before the deploy is ADDING a backup key, which reports the
/// schema gap in plain language instead of a raw CloudKit error.
extension SyncEngine {

    // MARK: - Errors

    enum BackupKeyError: LocalizedError {
        case schemaNotDeployed
        case credentialNoLongerValid
        case alreadyRegistered
        case identityUnavailable

        var errorDescription: String? {
            switch self {
            case .schemaNotDeployed:
                "Backup keys aren't switched on in this environment yet. (The Identity record needs its backupEndorsements field — see the ops checklist in HANDOFF.)"
            case .credentialNoLongerValid:
                "That key is no longer a backup for this identity — it was revoked, or its endorsement doesn't check out."
            case .alreadyRegistered:
                "That key is already registered here."
            case .identityUnavailable:
                "Couldn't reach your identity in the directory to record the backup key. Check your connection and try again."
            }
        }
    }

    // MARK: - Directory scan

    /// One credential published in the directory: either an identity's ROOT
    /// credential or one of its backup credentials.
    struct DirectoryCredential {
        let credentialID: Data
        /// `credentialIDHash` of the identity this credential belongs to —
        /// for a root credential that is its own hash, for a backup it is the
        /// hash of the root that endorsed it. This is what turns a tapped
        /// backup key back into the identity it recovers.
        let ownerHash: String
        let isBackup: Bool

        var credentialIDHash: String { Data(SHA256.hash(data: credentialID)).hexString }
    }

    /// Every credential in the directory, root and backup alike.
    ///
    /// Backups are read out of each record's `backupEndorsements` blob rather
    /// than from a separate index record, so there is exactly one place a
    /// backup credential lives and no second write to fall out of step with
    /// the first. Cost: the scan carries those blobs, each holding a WebAuthn
    /// assertion. That lands on the same ~1k-identity ceiling `fetchAllCredentialIDs`
    /// already documents (SDS §7) — revisit both together, not separately.
    ///
    /// Signatures are NOT checked here. This list feeds `excludedCredentials`
    /// and an assertion allow-list, neither of which grants anything: a forged
    /// entry could at most make an authenticator decline to mint a second
    /// identity, or offer a credential that then fails verification. Anything
    /// that actually confers authority goes through `fetchIdentity`, which
    /// verifies.
    func fetchDirectoryCredentials() async throws -> [DirectoryCredential] {
        do {
            return try await scanDirectory(includingBackups: true)
        } catch {
            // A directory whose schema predates `backupEndorsements` may
            // reject the field in desiredKeys. Registration exclusion and
            // security-key sign-in both depend on this scan, so degrade to the
            // legacy key set rather than taking them down with us — the cost
            // is that a backup key can't be resolved until the field is
            // deployed, which is exactly the state the app was in before FR-3.
            WebAuthnDiag.log.error("directory scan with backupEndorsements failed, retrying without it: \(error.localizedDescription, privacy: .public)")
            return try await scanDirectory(includingBackups: false)
        }
    }

    private func scanDirectory(includingBackups: Bool) async throws -> [DirectoryCredential] {
        let keys = includingBackups
            ? ["credentialID", "tier", "backupEndorsements"]
            : ["credentialID", "tier"]
        let query = CKQuery(recordType: "Identity", predicate: NSPredicate(value: true))
        var found: [DirectoryCredential] = []

        func absorb(_ results: [(CKRecord.ID, Result<CKRecord, any Error>)]) {
            for (recordID, result) in results {
                guard let record = try? result.get(),
                      (record["tier"] as? String) != Self.deletedTier else { continue }  // skip tombstones
                let owner = recordID.recordName
                if let id = record["credentialID"] as? Data {
                    found.append(DirectoryCredential(credentialID: id, ownerHash: owner, isBackup: false))
                }
                guard includingBackups,
                      let data = record["backupEndorsements"] as? Data,
                      let backups = try? JSONDecoder().decode([BackupCredential].self, from: data)
                else { continue }
                for backup in backups {
                    found.append(DirectoryCredential(credentialID: backup.credentialID,
                                                     ownerHash: owner, isBackup: true))
                }
            }
        }

        var (results, cursor) = try await publicDB.records(
            matching: query, desiredKeys: keys, resultsLimit: 200)
        while true {
            absorb(results)
            guard let next = cursor else { break }
            (results, cursor) = try await publicDB.records(
                continuingMatchFrom: next, desiredKeys: keys, resultsLimit: 200)
        }
        return found
    }

    // MARK: - Sign-in resolution

    /// The identity a tapped credential signs in as, plus the public key that
    /// tap must verify against.
    struct SignInCredential {
        let root: RootIdentity
        /// The key the sign-in assertion is checked with: the root's own key,
        /// or the backup credential's. Verifying a backup's assertion against
        /// the ROOT key would fail every time — different keys, different
        /// signatures — so the caller must use this one, not `root.publicKey`.
        let publicKey: P256.Signing.PublicKey
        /// Non-nil when the person signed in with a backup credential.
        let backup: BackupCredential?
    }

    /// Resolve a tapped credential to an identity. Sign-in accepts ANY
    /// non-revoked credential on an identity (FR-3): the root credential, or
    /// any backup it endorsed.
    ///
    /// Tombstones are checked on the identity that would be recovered, so a
    /// deleted identity can't be resurrected through a backup key any more
    /// than through its root key.
    func resolveSignInCredential(credentialIDHash hash: String) async throws -> SignInCredential {
        // Root credential: record name IS the hash, so this is a direct fetch
        // and the common case costs nothing new.
        if await isTombstoned(credentialIDHash: hash) {
            throw CeremonyManager.CeremonyError.identityDeleted
        }
        if let (root, _) = try await fetchIdentity(credentialIDHash: hash) {
            guard let pub = try? P256.Signing.PublicKey(rawRepresentation: root.publicKey) else {
                throw CeremonyManager.CeremonyError.identityNotFound
            }
            return SignInCredential(root: root, publicKey: pub, backup: nil)
        }

        // Not a root credential. A backup's hash is not a record name — the
        // backup lives inside its owner's record — so this is the one place
        // that needs the directory scan to find who it belongs to.
        let directory = try await fetchDirectoryCredentials()
        guard let entry = directory.first(where: { $0.isBackup && $0.credentialIDHash == hash }) else {
            throw CeremonyManager.CeremonyError.identityNotFound
        }
        if await isTombstoned(credentialIDHash: entry.ownerHash) {
            throw CeremonyManager.CeremonyError.identityDeleted
        }
        guard let (root, _) = try await fetchIdentity(credentialIDHash: entry.ownerHash) else {
            throw CeremonyManager.CeremonyError.identityNotFound
        }
        // fetchIdentity has already dropped backups that fail their root
        // signature or carry a valid revocation. Finding the scan's entry
        // missing here therefore means precisely "revoked or unverifiable",
        // which is worth saying out loud instead of reporting a generic
        // "no identity matches that key".
        guard let backup = root.backupCredentials?.first(where: { $0.credentialIDHash == hash }),
              let pub = try? P256.Signing.PublicKey(rawRepresentation: backup.publicKey) else {
            throw BackupKeyError.credentialNoLongerValid
        }
        WebAuthnDiag.log.info("signIn: resolved a BACKUP credential to identity \(root.credentialIDHash, privacy: .public)")
        return SignInCredential(root: root, publicKey: pub, backup: backup)
    }

    // MARK: - Publish / read

    /// Append a root-endorsed backup credential to our Identity record.
    ///
    /// Read-merge-write with the same retry discipline as `publishIdentity`:
    /// this identity's other devices publish to the same record name, so the
    /// change tag can go stale under us. The merge is idempotent (dedupe by
    /// credential ID), so replaying it is safe.
    func publishBackupCredential(_ backup: BackupCredential, for credentialIDHash: String) async throws {
        if await isTombstoned(credentialIDHash: credentialIDHash) {
            throw CeremonyManager.CeremonyError.identityDeleted
        }
        let recordID = CKRecord.ID(recordName: credentialIDHash)
        for attempt in 1...3 {
            do {
                guard let record = try? await publicDB.record(for: recordID) else {
                    // No identity record to attach to. Publishing a fresh one
                    // here would be wrong — it would have no endorsements and
                    // could stomp a record we simply failed to read.
                    throw BackupKeyError.identityUnavailable
                }
                var backups: [BackupCredential] = []
                if let existing = record["backupEndorsements"] as? Data,
                   let decoded = try? JSONDecoder().decode([BackupCredential].self, from: existing) {
                    backups = decoded
                }
                backups.removeAll { $0.credentialID == backup.credentialID }
                backups.append(backup)
                record["backupEndorsements"] = try JSONEncoder().encode(backups)
                try await publicDB.save(record)
                WebAuthnDiag.log.info("publishBackupCredential: published backup key for \(credentialIDHash, privacy: .public) (\(backups.count, privacy: .public) total)")
                return
            } catch let error as CKError where error.code == .serverRecordChanged {
                try? await Task.sleep(for: .milliseconds(200 << attempt))
                continue
            } catch let error as CKError where error.code == .invalidArguments {
                // Overwhelmingly the "unknown field" case: the schema hasn't
                // been deployed to this environment yet. Say that, rather than
                // handing the user a CloudKit sentence about arguments.
                WebAuthnDiag.log.error("publishBackupCredential: invalidArguments — backupEndorsements field likely missing from this environment's schema")
                throw BackupKeyError.schemaNotDeployed
            }
        }
        throw BackupKeyError.identityUnavailable
    }

    /// Backup credentials on an identity, verified and revocation-filtered —
    /// the list the keys panel renders. Reuses `fetchIdentity` so the UI can
    /// never show a backup that verification wouldn't honour.
    func fetchBackupCredentials(credentialIDHash: String) async throws -> [BackupCredential] {
        guard let (root, _) = try await fetchIdentity(credentialIDHash: credentialIDHash) else { return [] }
        return root.backupCredentials ?? []
    }
}
