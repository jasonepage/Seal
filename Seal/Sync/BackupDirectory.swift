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
        case identityUnavailable
        case credentialClaimConflict
        case unprovenIdentityRecord

        var errorDescription: String? {
            switch self {
            case .schemaNotDeployed:
                "Backup keys aren't switched on in this environment yet. (The Identity record needs its backupEndorsements field — see the ops checklist in HANDOFF.)"
            case .credentialNoLongerValid:
                "That key is no longer a backup for this identity — it was revoked, or its endorsement doesn't check out."
            case .identityUnavailable:
                "Couldn't reach your identity in the directory to record the backup key. Check your connection and try again."
            case .credentialClaimConflict:
                "Two different identities claim this key, so Seal can't tell which one is yours — and it won't guess. Nothing has been signed in to. This should never happen by accident; check with whoever set the backup key up."
            case .unprovenIdentityRecord:
                "The directory entry for this key was never signed by the key itself, so Seal won't trust it. Nothing has been signed in to."
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
        } catch let error as CKError where error.code == .invalidArguments {
            // ONLY the schema-gap signal degrades. A directory whose schema
            // predates `backupEndorsements` rejects the field in desiredKeys,
            // and registration exclusion plus security-key sign-in both depend
            // on this scan, so falling back to the legacy key set keeps them
            // working — that is exactly the state the app was in before FR-3.
            //
            // Every OTHER error rethrows. Swallowing a transient network
            // failure here would quietly drop backup credentials out of the
            // allow-list and surface as "No identity in the directory matches
            // that key. Register instead?" — an invitation to abandon the
            // identity, shown to someone mid-recovery because of a blip.
            WebAuthnDiag.log.error("directory scan rejected backupEndorsements (schema not deployed?), retrying without it: \(error.localizedDescription, privacy: .public)")
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
        if await isTombstoned(credentialIDHash: hash) {
            throw CeremonyManager.CeremonyError.identityDeleted
        }

        // WHO CLAIMS THIS CREDENTIAL? Ask before resolving anything.
        //
        // Before FR-3 the only credential anyone ever tapped was a root, and a
        // root's record name was already occupied by its owner (public-DB
        // first-creator-wins), so a direct fetch was safe. A BACKUP credential
        // changed that: its ID becomes public the moment it is published, and
        // `SHA256(backupCredentialID)` is a record name NOBODY EVER CREATES.
        // An attacker can create an Identity record at exactly that name
        // carrying the backup's own public key. The recovering user's tap
        // would then verify perfectly — against their own real key — while
        // resolving to the attacker's identity, and their phone would adopt a
        // record the attacker can rewrite at will. That is a hijack of the
        // exact moment this feature exists to serve.
        //
        // So: if more than one identity claims the tapped credential, refuse.
        // Failing closed costs a contested recovery an error message; guessing
        // costs it the identity. (The claims list is unverified — it is a
        // conflict DETECTOR, not an authority. Authority still comes from the
        // signature checks below.)
        let claims = try? await fetchDirectoryCredentials()
        if let claims {
            let owners = Set(claims.filter { $0.credentialIDHash == hash }.map(\.ownerHash))
            if owners.count > 1 {
                WebAuthnDiag.log.error("signIn: \(owners.count, privacy: .public) identities claim the tapped credential — refusing")
                throw BackupKeyError.credentialClaimConflict
            }
        }

        // Root credential: the record name IS the hash, so this is a direct
        // fetch and the common case costs nothing new.
        if let (root, _) = try await fetchIdentity(credentialIDHash: hash) {
            guard let pub = try? P256.Signing.PublicKey(rawRepresentation: root.publicKey) else {
                throw CeremonyManager.CeremonyError.identityNotFound
            }
            // Second lock on the same door, for when the scan was unavailable:
            // a real identity record contains at least one device endorsement
            // signed by the key it publishes — that is what registration
            // does. A squatted record cannot contain one without the private
            // key it is impersonating.
            guard await recordProvesKeyPossession(root: root) else {
                WebAuthnDiag.log.error("signIn: record \(hash, privacy: .public) has no endorsement signed by the key it publishes — refusing")
                throw BackupKeyError.unprovenIdentityRecord
            }
            return SignInCredential(root: root, publicKey: pub, backup: nil)
        }

        // Not a root credential. A backup's hash is not a record name — the
        // backup lives inside its owner's record — so this is the one place
        // that needs the directory scan to find who it belongs to.
        guard let directory = claims else {
            throw CeremonyManager.CeremonyError.directoryUnavailable
        }
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

    /// True when this identity's record carries at least one device
    /// endorsement whose assertion verifies under the record's OWN published
    /// public key — proof that whoever built the record held that private key.
    ///
    /// Deliberately checked against the RAW endorsement list, revoked entries
    /// included: the question is "did the holder of this key ever sign here",
    /// not "is that device still valid". Filtering by revocation would deadlock
    /// an identity that revoked every device — it could never sign in again to
    /// endorse a new one.
    private func recordProvesKeyPossession(root: RootIdentity) async -> Bool {
        guard let rootPub = try? P256.Signing.PublicKey(rawRepresentation: root.publicKey),
              let (endorsements, _) = try? await fetchDeviceList(credentialIDHash: root.credentialIDHash)
        else { return false }
        return endorsements.contains { e in
            guard let assertion = try? JSONDecoder().decode(WebAuthnAssertion.self, from: e.assertion),
                  assertion.verify(with: rootPub) else { return false }
            let commitment = Data(SHA256.hash(data:
                Data("seal.endorse.v2".utf8) + e.devicePublicKey + e.kemBundlePublicKeys))
            return CeremonyManager.clientDataChallengeMatches(assertion.clientDataJSON, expected: commitment)
        }
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
