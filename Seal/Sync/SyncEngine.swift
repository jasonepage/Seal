// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import CloudKit
import os   // Logger interpolation resolves at the call site

/// CloudKit transport (SDS §1, §4): public DB for the identity directory,
/// one custom zone per group shared via CKShare. Transport-level share
/// membership is NOT trusted, cryptographic membership is the signed
/// MembershipLog + key epochs.
@Observable
final class SyncEngine {
    static let containerID = "iCloud.io.github.jasonepage.Seal"

    /// Tombstone marker stored in the EXISTING `tier` field (no new schema
    /// field, works in Production). It's not a valid IdentityTier raw value,
    /// so any client that reads it fails to decode the identity and treats it
    /// as gone. Visible directly in the console's existing `tier` column.
    static let deletedTier = "deleted"

    enum CloudStatus: Equatable {
        case idle, publishing, published
        case error(String)
    }

    private(set) var status: CloudStatus = .idle

    /// Back to idle so a newly registered identity publishes itself.
    func resetStatus() { status = .idle }

    // Internal, not private: the FR-3 backup-key directory calls live in
    // Seal/Sync/BackupDirectory.swift as an extension on this type, and a
    // second CKContainer handle there would be a silent way for the two to
    // disagree about which database they are talking to.
    var publicDB: CKDatabase {
        CKContainer(identifier: Self.containerID).publicCloudDatabase
    }

    // MARK: - Tombstones (permanent deletion)

    /// Deletion marker lives in its OWN record, separate from the (revivable)
    /// Identity record. The `tier="deleted"` flag on the Identity record alone
    /// is not enough: the app republishes that record on sign-in, on every
    /// device refresh, and via HomeView's launch publish, and if the
    /// record was removed outright (e.g. deleted in the CloudKit console),
    /// publishIdentity just re-creates a fresh LIVE one. A write-once tombstone
    /// record can't be revived by republishing the identity, because the
    /// publish path never touches this record name.
    private static func tombstoneName(_ hash: String) -> String { "tomb.\(hash)" }

    /// True if this identity has been permanently deleted. Checked at sign-in
    /// AND before any publish, so a deleted identity can't be brought back.
    ///
    /// FAILS CLOSED. This used to return false on any error other than
    /// "no such record", so a network blip at sign-in let a deleted identity
    /// through to the live-record path, and a blip at publish time revived
    /// it. Every caller needs the network anyway (a sign-in fetches the
    /// record next, a publish writes it), so an unreachable directory is an
    /// error here, not a "probably fine". The local graveyard is consulted
    /// first and needs no network at all.
    ///
    /// SIGNED MARKERS ONLY (TombstoneProof.swift). A marker counts when its
    /// proof verifies under the pinned key, or the live record's key. An
    /// unsigned or forged one is ignored, so a stranger cannot lock anybody
    /// out. A live record flipped to the deleted tier still counts, since
    /// only its creator could flip it.
    func isTombstoned(credentialIDHash hash: String) async throws -> Bool {
        if DeletedIdentityLedger.contains(hash) { return true }
        let id = CKRecord.ID(recordName: Self.tombstoneName(hash))
        let marker: CKRecord
        do { marker = try await publicDB.record(for: id) }
        catch let error as CKError where error.code == .unknownItem { return false }
        var knownKey = KeyPinStore.pinnedKey(for: hash)
        if knownKey == nil {
            do {
                let live = try await publicDB.record(for: CKRecord.ID(recordName: hash))
                if live["tier"] as? String == Self.deletedTier { return true }
                knownKey = live["publicKey"] as? Data
            } catch let error as CKError where error.code == .unknownItem {
                // No live record: nothing for the marker to hurt.
            }
        }
        let counts = TombstoneProof.markerCounts(hash: hash, proofData: marker[TombstoneProof.field] as? Data,
                                                 knownKey: knownKey)
        if !counts {
            WebAuthnDiag.log.error("isTombstoned: ignoring an unsigned or forged delete marker for \(hash, privacy: .public)")
        }
        return counts
    }

    // MARK: - Identity directory (FR-4)

    /// Publish (or refresh) our Identity record in the public database so
    /// friends' clients can fetch and verify it. Record name = credentialIDHash,
    /// so lookups are direct fetches, no queries needed.
    enum PublishOutcome {
        case published      // our endorsement is confirmed in the directory
        case refused        // permanent: tombstoned. Never retry.
        case failed         // transient: offline, contention. Retry later.
    }

    /// Why this reports three outcomes rather than a Bool: a caller that
    /// self-heals (HomeView's launch publish) has to retry a `failed`,
    /// but must NOT retry a `refused`, a tombstoned identity can never
    /// publish, and retrying it on every launch, foreground and silent push
    /// would hammer CloudKit forever for a result that cannot change.
    ///
    /// Getting this right matters because an endorsement that never lands is
    /// invisible to peers, so every message this device signs is dropped by
    /// everyone as "signed by a device not among the sender's endorsed
    /// devices", and receivers skip slots they can't verify, so those
    /// messages are lost for good. Silent failure here is the most expensive
    /// failure in the app.
    @discardableResult
    func publishIdentity(_ root: RootIdentity, endorsement: DeviceEndorsement) async -> PublishOutcome {
        status = .publishing
        // Never resurrect a permanently-deleted identity. The write-once
        // tombstone record is authoritative and survives the Identity record
        // being overwritten OR removed outright, so this closes the revival
        // paths the `tier` flag alone missed (sign-in republish, other-device
        // refresh, ensureSelfPublished, console deletion).
        do {
            if try await isTombstoned(credentialIDHash: root.credentialIDHash) {
                status = .error("This identity was deleted and can't be republished.")
                WebAuthnDiag.log.info("publishIdentity: refused to revive tombstoned identity")
                return .refused
            }
        } catch {
            // Could not check the graveyard. Publishing anyway is how a
            // deleted identity comes back, so do not. Transient: retry later.
            status = .error("Couldn't reach the directory. Seal tries again later.")
            WebAuthnDiag.log.error("publishIdentity: tombstone check failed, not publishing: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
        let recordID = CKRecord.ID(recordName: root.credentialIDHash)

        // Read-merge-write against a shared record is a race: this identity's
        // OTHER devices (and the peer signing in at the same moment during a
        // forge) publish to the SAME record name, so the change tag we read
        // can be stale by the time we save. CloudKit then rejects the write
        // with .serverRecordChanged. That used to end the attempt with nothing
        // published and nothing retrying. Re-read and re-merge instead, the
        // merge is idempotent (dedupe by device key), so replaying it is safe.
        for attempt in 1...3 {
            do {
                let record: CKRecord
                if let existing = try? await publicDB.record(for: recordID) {
                    // Belt-and-suspenders: also honor the legacy tier flag
                    // (covers identities deleted before the tombstone record).
                    if existing["tier"] as? String == Self.deletedTier {
                        status = .error("This identity was deleted and can't be republished.")
                        WebAuthnDiag.log.info("publishIdentity: refused to revive tombstoned identity (tier flag)")
                        return .refused
                    }
                    record = existing
                } else {
                    record = CKRecord(recordType: "Identity", recordID: recordID)
                }
                record["publicKey"] = root.publicKey
                record["tier"] = root.tier.rawValue
                record["displayName"] = root.displayName
                if let credID = root.rawCredentialID {
                    record["credentialID"] = credID
                }
                // Merge, don't overwrite: sign-in on a new device APPENDS its
                // endorsement; existing devices stay valid (FR-18 groundwork).
                var endorsements: [DeviceEndorsement] = []
                if let existing = record["deviceEndorsements"] as? Data,
                   let decoded = try? JSONDecoder().decode([DeviceEndorsement].self, from: existing) {
                    endorsements = decoded
                }
                endorsements.removeAll { $0.devicePublicKey == endorsement.devicePublicKey }
                endorsements.append(endorsement)
                record["deviceEndorsements"] = try JSONEncoder().encode(endorsements)
                // TODO: revocations list, backup-key endorsements, head-hash
                //       chain for peer-to-peer key transparency (SDS §2)

                try await publicDB.save(record)

                // Round-trip check: prove the directory actually works, and
                // that OUR endorsement survived somebody else's concurrent
                // merge. A save that "succeeded" but left us out is the same
                // failure as not publishing at all, so treat it as a retry.
                // Read back and confirm OUR endorsement survived: a save that
                // "succeeded" but got clobbered by somebody else's concurrent
                // merge is the same outcome as never publishing.
                // A read that FAILS is not evidence of either, the save
                // already succeeded, so treat an unreadable read-back as
                // published rather than raising a false alarm about keys.
                guard let saved = try? await publicDB.record(for: recordID) else {
                    WebAuthnDiag.log.info("publishIdentity: saved, but read-back failed, assuming published")
                    status = .published
                    return .published
                }
                let landed = (saved["deviceEndorsements"] as? Data)
                    .flatMap { try? JSONDecoder().decode([DeviceEndorsement].self, from: $0) } ?? []
                guard landed.contains(where: { $0.devicePublicKey == endorsement.devicePublicKey }) else {
                    WebAuthnDiag.log.error("publishIdentity: endorsement absent after save, concurrent merge dropped it (attempt \(attempt, privacy: .public))")
                    try? await Task.sleep(for: .milliseconds(200 << attempt))
                    continue
                }
                status = .published
                return .published
            } catch let error as CKError where error.code == .serverRecordChanged {
                WebAuthnDiag.log.info("publishIdentity: record changed under us, re-merging (attempt \(attempt, privacy: .public))")
                // Back off before re-reading. Retrying instantly tends to lose
                // to the same writer three times in a row; a little jittered
                // space lets the winner's save settle first.
                try? await Task.sleep(for: .milliseconds(200 << attempt))
                continue
            } catch {
                status = .error(Self.friendly(error))
                return .failed
            }
        }
        status = .error("Couldn't publish this device's key, so others cannot read what you send. Seal tries again.")
        WebAuthnDiag.log.error("publishIdentity: gave up after 3 attempts")
        return .failed
    }

    /// Fetch a (claimed) identity from the directory. The caller must still
    /// verify its endorsement chain, the server is untrusted for integrity.
    /// WHY `fetchIdentity` said no.
    ///
    /// That function returns nil for five different reasons and callers had
    /// no way to tell them apart, so every one of them reached the person as
    /// "Check your connection and try again." A genuine network failure
    /// THROWS out of `record(for:)` and never returns nil at all, so the one
    /// thing that message told somebody to check was the one thing it could
    /// not be. This says which it actually was.
    ///
    /// One extra fetch, on a path that is already failing.
    func identityAbsence(credentialIDHash: String) async -> String {
        let recordID = CKRecord.ID(recordName: credentialIDHash)
        let record: CKRecord
        do {
            record = try await publicDB.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            // By far the most common, and GOTCHAS names the reason twice:
            // TestFlight and the App Store use PRODUCTION CloudKit while
            // Xcode builds use DEVELOPMENT. They are separate worlds with
            // separate records, so a person who registered on one build is
            // simply not there on the other.
            return "no identity is published under that name here. A phone that has not signed in on this build has no record yet, and an Xcode build and a TestFlight build keep separate directories."
        } catch {
            return "the directory could not be reached (\(error.localizedDescription))."
        }
        if record["tier"] as? String == Self.deletedTier {
            return "that identity was permanently deleted. Remove the person and meet them again once they have registered a new identity."
        }
        if record["publicKey"] as? Data == nil {
            return "the directory entry has no public key in it, so nothing can be encrypted to that person."
        }
        if let publicKey = record["publicKey"] as? Data {
            do { try KeyPinStore.enforce(hash: credentialIDHash, publicKey: publicKey) }
            catch {
                return "the key published under that name is NOT the key this phone pinned when you met. Seal refuses it. Do not work around this: remove the person and meet them again in person."
            }
        }
        if (record["deviceEndorsements"] as? Data) == nil {
            return "that identity has published no device, so there is nothing to encrypt to. They open Seal once on a phone and sign in, and the entry repairs itself."
        }
        return "the directory entry is incomplete or could not be read. They open Seal once and sign in to republish it."
    }

    func fetchIdentity(credentialIDHash: String) async throws -> (RootIdentity, [DeviceEndorsement])? {
        let recordID = CKRecord.ID(recordName: credentialIDHash)
        let record: CKRecord
        do {
            record = try await publicDB.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
        // Tombstoned (deleted) identities read as "not found": sign-in refuses
        // and the caller can't revive them (FR-19).
        if record["tier"] as? String == Self.deletedTier { return nil }
        guard let publicKey = record["publicKey"] as? Data else { return nil }
        // Security fix 1: a pinned root key must match what the directory
        // serves, every single fetch. A mismatch THROWS rather than returning
        // nil, so callers that distinguish "not found" from "refused" can say
        // so, and callers that `try?` fail closed either way. See
        // KeyPinStore.swift for why this is the fix that matters most.
        try KeyPinStore.enforce(hash: credentialIDHash, publicKey: publicKey)
        guard
            let tierRaw = record["tier"] as? String,
            let tier = IdentityTier(rawValue: tierRaw),
            let displayName = record["displayName"] as? String,
            let endorsementData = record["deviceEndorsements"] as? Data,
            let endorsements = try? JSONDecoder().decode([DeviceEndorsement].self, from: endorsementData)
        else { return nil }

        var root = RootIdentity(
            credentialIDHash: credentialIDHash,
            publicKey: publicKey,
            tier: tier,
            displayName: displayName,
            rawCredentialID: record["credentialID"] as? Data
        )

        // One revocation list, two kinds of subject: device keys (FR-19,
        // `seal.revoke.v1`) and backup credentials (FR-3,
        // `seal.backup.revoke.v1`). They are told apart by the domain string
        // inside the root-signed commitment, never by position or by shape.
        var revocations: [DeviceRevocation] = []
        if let data = record["revocations"] as? Data,
           let decoded = try? JSONDecoder().decode([DeviceRevocation].self, from: data) {
            revocations = decoded
        }
        revocations += try await fetchSideRevocations(credentialIDHash: credentialIDHash)

        // Backup credentials (FR-3). THIS is the single point where a backup
        // is checked against the root signature and the revocation list, so
        // every consumer downstream, the authority set in verifiedDevices,
        // sign-in resolution, the profile list, inherits one filtered answer
        // instead of each re-deriving it. An absent field means "no backups"
        // (an identity that has none, or a directory where the field is not
        // deployed yet) and is never an error.
        if let data = record["backupEndorsements"] as? Data,
           let decoded = try? JSONDecoder().decode([BackupCredential].self, from: data) {
            let revokedBackups = IdentityManager.revokedBackupPublicKeys(root: root, revocations: revocations)
            let live = BackupCredential.verified(decoded, root: root, revokedPublicKeys: revokedBackups)
            root.backupCredentials = live.isEmpty ? nil : live
        }

        // Filter out revoked devices before anyone trusts them (FR-19).
        var live = endorsements
        let revokedDevices = IdentityManager.revokedDevicePublicKeys(root: root, revocations: revocations)
        live.removeAll { revokedDevices.contains($0.devicePublicKey) }
        return (root, live)
    }

    /// Every credential ID in the directory, fed to `excludedCredentials` at
    /// registration so an authenticator that already holds a Seal identity
    /// refuses to mint a second one (1 key ≈ 1 account; SDS §7: deterrence,
    /// not an invariant, FIDO2 reset or a modified client evades it).
    /// NOTE: requires the `recordName QUERYABLE` index on Identity in the
    /// CloudKit schema (console → Indexes → Identity), dev + Production.
    /// Scale ceiling is documented in SDS §7, revisit past ~1k identities.
    /// Now a thin projection of `fetchDirectoryCredentials()` (FR-3, see
    /// Seal/Sync/BackupDirectory.swift), so BACKUP credential IDs land in this
    /// list too. Both callers need that:
    ///   - registration's `excludedCredentials`, otherwise a key already
    ///     serving as somebody's backup could mint a second identity, which is
    ///     exactly the hole 1-key-1-identity exists to deter (SDS §7);
    ///   - security-key sign-in's allow-list, a non-discoverable backup key
    ///     recognises its own credential only when its ID is on the list, so
    ///     leaving it off would make the recovery key silently un-tappable.
    func fetchAllCredentialIDs() async throws -> [Data] {
        try await fetchDirectoryCredentials().map(\.credentialID)
    }

    // MARK: - Revocations (FR-19, FR-3)
    //
    // THE CREATOR-ONLY RULE. A public database record can be modified only
    // by the iCloud account that created it. `publishRevocation` used to
    // append to the Identity record itself, so on any phone signed into a
    // different iCloud account than the one that first published the
    // identity, the save failed with "WRITE operation not permitted" and
    // the revocation never landed. Same shape as the delete problem, and
    // the same cure: a record this account creates, and therefore owns.
    //
    // WHERE IT GOES. A `GroupInvite` record (existing type, no schema
    // change) with a RANDOM name, `recipient` = "revoke.<identity hash>"
    // (already QUERYABLE) and `payload` = the DeviceRevocation JSON.
    //   - Random, not "revoke.<hash>.<device>": a predictable name can be
    //     created first by anybody, and a squatted name would block the
    //     real revocation forever. A random name cannot be squatted.
    //   - Found by query on `recipient`, the index the invite path already
    //     requires. The invite push predicate is `recipient == <hash>`, and
    //     "revoke.<hash>" never equals a hash, so no alert fires.
    //
    // WHY THIS IS STILL SAFE. Anybody can create such a record. That buys
    // them nothing: every revocation, from the Identity record or from a
    // side record, goes through `IdentityManager.revokedDevicePublicKeys`
    // (or the backup twin), which drops anything not signed by the ROOT
    // credential over `seal.revoke.v1` + the device key. Junk is ignored.
    // The unsigned `revokedAt` field stays gone (security fix 3).

    static func revocationAddress(_ credentialIDHash: String) -> String { "revoke.\(credentialIDHash)" }

    /// Publish a root-signed revocation. The side record always; the
    /// Identity record's own list too when this account is its creator.
    func publishRevocation(_ revocation: DeviceRevocation, for credentialIDHash: String) async throws {
        // 1. Authoritative, and works from any iCloud account.
        let sideID = CKRecord.ID(recordName: "rvk.\(credentialIDHash).\(UUID().uuidString)")
        let side = CKRecord(recordType: "GroupInvite", recordID: sideID)
        side["recipient"] = Self.revocationAddress(credentialIDHash)
        side["payload"] = try JSONEncoder().encode(revocation)
        try await publicDB.save(side)

        // 2. Best effort: the legacy list on the Identity record. Older
        //    builds read only this, and a direct fetch has no query index
        //    lag. Skipped quietly when another account owns the record.
        let recordID = CKRecord.ID(recordName: credentialIDHash)
        for attempt in 1...3 {
            do {
                let record = try await publicDB.record(for: recordID)
                var revocations: [DeviceRevocation] = []
                if let existing = record["revocations"] as? Data,
                   let decoded = try? JSONDecoder().decode([DeviceRevocation].self, from: existing) {
                    revocations = decoded
                }
                guard !revocations.contains(where: { $0.devicePublicKey == revocation.devicePublicKey
                                                     && $0.assertion == revocation.assertion }) else { return }
                revocations.append(revocation)
                record["revocations"] = try JSONEncoder().encode(revocations)
                try await publicDB.save(record)
                return
            } catch let error as CKError where error.code == .serverRecordChanged {
                try? await Task.sleep(for: .milliseconds(200 << attempt))
                continue
            } catch {
                WebAuthnDiag.log.info("publishRevocation: side record saved; identity record not updated (\(error.localizedDescription, privacy: .public))")
                return
            }
        }
    }

    /// Revocations published as side records, unverified. Every page is
    /// read, because a stranger could pad the query with junk to push the
    /// real one off the first page. Capped so junk cannot make this run
    /// forever; the cap is far above anything a real identity writes.
    /// Throws when the directory cannot be read: a revocation we failed to
    /// fetch must not read as "nothing revoked".
    func fetchSideRevocations(credentialIDHash: String) async throws -> [DeviceRevocation] {
        let query = CKQuery(recordType: "GroupInvite",
                            predicate: NSPredicate(format: "recipient == %@", Self.revocationAddress(credentialIDHash)))
        var out: [DeviceRevocation] = []
        func absorb(_ results: [(CKRecord.ID, Result<CKRecord, any Error>)]) {
            for (_, result) in results {
                guard let record = try? result.get(), let data = record["payload"] as? Data,
                      let revocation = try? JSONDecoder().decode(DeviceRevocation.self, from: data) else { continue }
                out.append(revocation)
            }
        }
        var (results, cursor) = try await publicDB.records(matching: query, desiredKeys: ["payload"], resultsLimit: 200)
        var pages = 1
        while true {
            absorb(results)
            guard let next = cursor else { break }
            guard pages < 20 else {
                WebAuthnDiag.log.error("fetchSideRevocations: more than 20 pages for \(credentialIDHash, privacy: .public), stopping")
                break
            }
            (results, cursor) = try await publicDB.records(continuingMatchFrom: next, desiredKeys: ["payload"], resultsLimit: 200)
            pages += 1
        }
        return out
    }

    /// Account deletion (App Review 5.1.1(v)): remove our Identity record
    /// from the public directory. Friends' clients can no longer fetch or
    /// verify us; leftover Message/KeyEnvelope records are ciphertext that
    /// becomes permanently unreadable once local keys are wiped.
    /// Permanently retire an identity. We do NOT just delete the row: in this
    /// zero-server design the identity is the key/passkey, which survives the
    /// delete, so a bare deletion is silently re-created by the next sign-in's
    /// republish (and is readable anyway during CloudKit's propagation window).
    /// Instead we write a durable tombstone, `tier` set to a deleted sentinel,
    /// endorsements scrubbed, and keep the record as a gravestone that
    /// fetchIdentity, the sign-in allow-list, and publishIdentity all refuse to
    /// revive (FR-19). Uses only existing fields, so no schema change.
    /// `proof` is the owner's tap over the delete challenge. Without it the
    /// marker is ignored by every other phone (TombstoneProof.swift); the
    /// only callers are ProfileView's delete and the retire ceremony, and
    /// both pass one.
    func deleteIdentity(credentialIDHash: String, proof: TombstoneProof) async throws {
        // 1. Authoritative deletion = a write-once marker record that THIS
        //    account creates and therefore OWNS. Creating a brand-new record
        //    always succeeds (you're the creator of what you create), so delete
        //    works from ANY iCloud account, even when the Identity record was
        //    first published by a DIFFERENT account and the public-DB
        //    creator-only-write rule ("WRITE operation not permitted") won't let
        //    us touch it. If the marker already exists, the identity is already
        //    dead, that's success too. Once present, isTombstoned() is true
        //    forever, so sign-in and every publish refuse to revive it.
        let tombID = CKRecord.ID(recordName: Self.tombstoneName(credentialIDHash))
        do {
            let tomb = CKRecord(recordType: "Identity", recordID: tombID)
            tomb["tier"] = Self.deletedTier
            tomb[TombstoneProof.field] = try JSONEncoder().encode(proof)
            try await publicDB.save(tomb)
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Marker already present (this or another account deleted before).
        }
        // The marker is on the server. Remember it here too, so THIS phone
        // never offers, excludes against, or signs into this identity again
        // while CloudKit's query index catches up (DeletedIdentityLedger).
        DeletedIdentityLedger.add(credentialIDHash)

        // 2. BEST-EFFORT: also flip the live Identity record to the deleted
        //    sentinel + scrub endorsements, so the fast path (fetchIdentity's
        //    tier check) sees it gone without the extra tombstone fetch. Only
        //    the record's creator may modify it, so this is skipped silently
        //    when another account owns it, the marker in step 1 is what
        //    actually enforces deletion, so we must NOT fail the whole delete
        //    over a write we may not be permitted to make.
        let recordID = CKRecord.ID(recordName: credentialIDHash)
        let record = (try? await publicDB.record(for: recordID))
            ?? CKRecord(recordType: "Identity", recordID: recordID)
        record["tier"] = Self.deletedTier
        // The device endorsements STAY (changed 2026-09-16). They are signed
        // public data, and they are what lets a key holder's phone keep
        // checking the owner's past record entries, including the
        // "I deleted my account" one, after the account is gone
        // (`fetchIdentityForHistory`). Nothing can be sent to them anyway:
        // `fetchIdentity` returns nil for the deleted tier.
        // Scrub backup credentials as well, so a deleted identity can't be
        // reached through one (FR-3). Guarded on the field already being
        // present: writing a field the Production schema doesn't have yet
        // would make the whole save fail, and account deletion is an App
        // Review 5.1.1(v) requirement that must not depend on a schema deploy.
        // The write-once tombstone marker above is authoritative regardless, 
        // sign-in through a backup resolves to this root and checks it.
        if record["backupEndorsements"] != nil {
            record["backupEndorsements"] = Data()
        }
        _ = try? await publicDB.save(record)
        // Say whether the flip actually landed. When it did not (a record
        // another account created), the marker still kills the identity,
        // and the directory scan now honours markers directly.
        let flipped = (try? await publicDB.record(for: recordID))
            .map { $0["tier"] as? String == Self.deletedTier } ?? false
        WebAuthnDiag.log.info("deleteIdentity: tombstoned \(credentialIDHash, privacy: .public) (marker written; live record flipped: \(flipped, privacy: .public))")
    }

    /// A DELETED identity, for checking what it signed while it was alive.
    ///
    /// `fetchIdentity` returns nil for a deleted identity, which is right
    /// for anything that sends or signs in. But a key holder still has to
    /// verify the owner's old record entries, or the record freezes the day
    /// the owner leaves. So this reads the flipped record anyway, and only
    /// when this phone PINNED the owner's key when they met: the pin is the
    /// trust, the record only supplies the device list the key signed.
    /// Returns nil for a live identity (use `fetchIdentity`), an unpinned
    /// one, a mismatched key, or a record deleted before endorsements were
    /// kept (those can only be checked from what the phone already saved).
    func fetchIdentityForHistory(credentialIDHash: String) async throws -> (RootIdentity, [DeviceEndorsement])? {
        let record: CKRecord
        do {
            record = try await publicDB.record(for: CKRecord.ID(recordName: credentialIDHash))
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
        guard record["tier"] as? String == Self.deletedTier,
              let pinned = KeyPinStore.pinnedKey(for: credentialIDHash),
              let publicKey = record["publicKey"] as? Data, publicKey == pinned,
              let data = record["deviceEndorsements"] as? Data, !data.isEmpty,
              let endorsements = try? JSONDecoder().decode([DeviceEndorsement].self, from: data)
        else { return nil }
        // The tier string is the deleted sentinel, not a real tier. Nothing
        // on the verification path reads it.
        let root = RootIdentity(credentialIDHash: credentialIDHash, publicKey: publicKey, tier: .verified,
                                displayName: record["displayName"] as? String ?? "",
                                rawCredentialID: record["credentialID"] as? Data)
        var revocations: [DeviceRevocation] = []
        if let data = record["revocations"] as? Data,
           let decoded = try? JSONDecoder().decode([DeviceRevocation].self, from: data) {
            revocations = decoded
        }
        revocations += try await fetchSideRevocations(credentialIDHash: credentialIDHash)
        let revoked = IdentityManager.revokedDevicePublicKeys(root: root, revocations: revocations)
        return (root, endorsements.filter { !revoked.contains($0.devicePublicKey) })
    }

    /// Remove one of this account's estate blobs. Only the iCloud account
    /// that saved it may; anything else fails and the caller reports it.
    /// A blob that is already gone counts as removed.
    func deleteEstateBlob(name: String) async throws {
        do { _ = try await publicDB.deleteRecord(withID: CKRecord.ID(recordName: name)) }
        catch let error as CKError where error.code == .unknownItem { return }
    }

    /// The public key the directory publishes under a hash, or nil when no
    /// record exists there. No pin check, no tier check, no verification:
    /// this is for the retire ceremony, which only needs to know what key a
    /// tap must match before it is allowed to tombstone that name.
    func publishedPublicKey(credentialIDHash: String) async throws -> Data? {
        do {
            let record = try await publicDB.record(for: CKRecord.ID(recordName: credentialIDHash))
            return record["publicKey"] as? Data
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    /// Raw device list (including revoked) for the profile UI.
    /// `includingSideRevocations` is false only for the sign-in possession
    /// check, which ignores revocations and should not gain a query.
    func fetchDeviceList(credentialIDHash: String,
                         includingSideRevocations: Bool = true) async throws -> ([DeviceEndorsement], [DeviceRevocation]) {
        let record = try await publicDB.record(for: CKRecord.ID(recordName: credentialIDHash))
        var endorsements: [DeviceEndorsement] = []
        var revocations: [DeviceRevocation] = []
        if let data = record["deviceEndorsements"] as? Data,
           let decoded = try? JSONDecoder().decode([DeviceEndorsement].self, from: data) {
            endorsements = decoded
        }
        if let data = record["revocations"] as? Data,
           let decoded = try? JSONDecoder().decode([DeviceRevocation].self, from: data) {
            revocations = decoded
        }
        if includingSideRevocations {
            revocations += try await fetchSideRevocations(credentialIDHash: credentialIDHash)
        }
        return (endorsements, revocations)
    }

    // MARK: - Push (CKQuerySubscription → APNs)

    /// RETIRE the messenger's push. The `Message` record type went with the
    /// messenger in phase 7 and nothing writes one any more, but the
    /// subscription is stored SERVER SIDE per iCloud account, so every phone
    /// that ran an older build still carries `seal.msgsub.<hash>` and its
    /// alert, "New sealed message", for a feature that no longer exists.
    /// Deleting the subscription is the only way to take it off those
    /// phones. Safe to call every launch: a missing subscription is not an
    /// error worth reporting.
    func retireMessengerSubscriptions(for myHash: String) async {
        for id in ["seal.msgsub.\(myHash)", "seal.msgsub.v2.\(myHash)"] {
            _ = try? await publicDB.deleteSubscription(withID: id)
        }
    }

    /// Fires when an owner names this phone in their estate, as a key holder
    /// or as a recipient. Without it the invite sits unseen until the person
    /// happens to open the app, which for a key holder could be never.
    ///
    /// The record type is still "GroupInvite" because that is the deployed
    /// CloudKit schema and a rename is a migration, not an edit. What it
    /// carries is an EstateInvite (EstateDirectory.publishEstateInvite).
    /// The ALERT, though, was still the messenger's: "You've been added to
    /// a new group", shown to somebody who had just been handed a key and
    /// told this app was about a will. v3 retires v2 and v1, because an
    /// existing subscription is never reconfigured in place.
    ///
    /// The text cannot say which part they hold. The role is inside the
    /// encrypted payload, and a CloudKit alert body is a fixed string
    /// chosen before anybody is invited. So it says the true general thing
    /// and sends them to the app, where the role card does say it.
    func ensureInviteSubscription(for myHash: String) async {
        let subID = "seal.invsub.v3.\(myHash)"
        if (try? await publicDB.subscription(for: subID)) != nil { return }
        for old in ["seal.invsub.\(myHash)", "seal.invsub.v2.\(myHash)"] {
            _ = try? await publicDB.deleteSubscription(withID: old)
        }
        let subscription = CKQuerySubscription(
            recordType: "GroupInvite",
            predicate: NSPredicate(format: "recipient == %@", myHash),
            subscriptionID: subID,
            options: .firesOnRecordCreation)
        let info = CKSubscription.NotificationInfo()
        info.title = "Seal"
        info.alertBody = "Someone has given you a part in their Seal. Open the app to see."
        info.soundName = "default"
        info.shouldBadge = true
        info.shouldSendContentAvailable = true      // pre-process the invite in the background
        subscription.notificationInfo = info
        do { _ = try await publicDB.save(subscription) }
        catch { status = .error("Push setup failed: \(error.localizedDescription)") }
    }

    // MARK: - Media (encrypted blobs as CKAssets)

    /// Store an already-encrypted media blob. The content key never comes
    /// near this function, it travels inside the E2EE message payload.
    func saveMediaAsset(_ encrypted: Data) async throws -> String {
        let name = "media.\(UUID().uuidString)"
        try await saveMediaAsset(encrypted, name: name)
        return name
    }

    /// Caller-supplied record name, lets the offline outbox reserve the name
    /// up front and retry the exact same record later.
    func saveMediaAsset(_ encrypted: Data, name: String) async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try encrypted.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let record = CKRecord(recordType: "MediaAsset", recordID: CKRecord.ID(recordName: name))
        record["blob"] = CKAsset(fileURL: tempURL)
        try await publicDB.save(record)
    }

    func fetchMediaAsset(_ name: String) async throws -> Data? {
        do {
            let record = try await publicDB.record(for: CKRecord.ID(recordName: name))
            guard let asset = record["blob"] as? CKAsset, let url = asset.fileURL else { return nil }
            return try Data(contentsOf: url)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    // MARK: - Group invites

    func saveGroupInvite(recipientHash: String, payload: Data) async throws {
        let record = CKRecord(recordType: "GroupInvite",
                              recordID: CKRecord.ID(recordName: "ginv.\(UUID().uuidString)"))
        record["recipient"] = recipientHash
        record["payload"] = payload
        try await publicDB.save(record)
    }

    // MARK: - Custody receipts (CustodyReceipt.swift)

    /// Deliver the receiver's copy. Reuses the GroupInvite record type and its
    /// already-queryable `recipient` field, **no schema change**, exactly as
    /// ForgeHandshake does. Both fields are ciphertext: the public database is
    /// world-readable, and a receipt can name an expensive object and carry a
    /// photo key, so nothing here may be published in the clear.
    func publishReceipt(receiptID: String,
                        recipientHash: String,
                        envelope: Data,
                        ciphertext: Data) async throws {
        let id = CKRecord.ID(recordName: "rcpt.\(recipientHash).\(receiptID)")
        let record = (try? await publicDB.record(for: id))
            ?? CKRecord(recordType: "GroupInvite", recordID: id)
        record["recipient"] = recipientHash
        record["payload"] = try JSONEncoder().encode(
            ReceiptEnvelope(receiptID: receiptID, envelope: envelope, ciphertext: ciphertext))
        try await publicDB.save(record)
    }

    /// Wire wrapper, so the whole thing round-trips through the single existing
    /// `payload` Bytes field. Group invites and forge handshakes share this
    /// query and simply fail to decode as this, and vice versa.
    struct ReceiptEnvelope: Codable {
        let receiptID: String
        let envelope: Data      // content key wrapped to the receiver's KEM keys
        let ciphertext: Data    // AES-GCM sealed CustodyReceipt JSON
    }

    func fetchReceipts(recipientHash: String) async throws -> [ReceiptEnvelope] {
        try await fetchGroupInvites(recipientHash: recipientHash).compactMap {
            try? JSONDecoder().decode(ReceiptEnvelope.self, from: $0)
        }
    }

    /// Deterministic name so re-forging the same pair REPLACES the handshake
    /// rather than littering the directory with duplicates.
    private static func handshakeName(sender: String, recipient: String) -> String {
        "forge.\(recipient).\(sender)"
    }

    /// Publish the reciprocal half of a forge ceremony (ForgeHandshake.swift).
    /// Reuses the GroupInvite record type deliberately, **no schema change**,
    /// and its `recipient` field is already queryable, which is what lets the
    /// other person find this without knowing our hash in advance. They
    /// genuinely don't know it: their phone took no part in the ceremony.
    func publishForgeHandshake(_ handshake: ForgeHandshake) async throws {
        let id = CKRecord.ID(recordName: Self.handshakeName(sender: handshake.senderHash,
                                                            recipient: handshake.recipientHash))
        // Fetch-then-update: a plain create would fail on the change tag if
        // this pair ever forged before (same bug class as the KeyEnvelope fix).
        let record = (try? await publicDB.record(for: id))
            ?? CKRecord(recordType: "GroupInvite", recordID: id)
        record["recipient"] = handshake.recipientHash
        record["payload"] = try JSONEncoder().encode(handshake)
        try await publicDB.save(record)
    }

    func fetchGroupInvites(recipientHash: String) async throws -> [Data] {
        let query = CKQuery(recordType: "GroupInvite",
                            predicate: NSPredicate(format: "recipient == %@", recipientHash))
        let (results, _) = try await publicDB.records(matching: query)
        var payloads: [Data] = []
        for (_, result) in results {
            if let record = try? result.get(), let data = record["payload"] as? Data {
                payloads.append(data)
            }
        }
        return payloads
    }

    /// One sentence a person can act on, or at least understand, for the
    /// iCloud errors that reach a screen. Public so the seal button and the
    /// claim buttons can use it too; they used to show the raw CloudKit
    /// description, which on 2026-09-16 put a CKRecordID and the words
    /// "production schema" in front of a tester.
    static func friendly(_ error: Error) -> String {
        let raw = error.localizedDescription
        // The schema was never deployed to Production. This is the
        // developer's job, and no amount of retrying on the phone fixes it,
        // so say that instead of dumping a record name.
        if raw.contains("production schema") || raw.contains("Cannot create new type") {
            return "Seal's storage on Apple's servers is not set up for this version yet. That is on the developer, not on you or your phone. Nothing was lost, and sealing works as soon as it is fixed."
        }
        guard let ck = error as? CKError else { return raw }
        switch ck.code {
        case .notAuthenticated: return "Sign in to iCloud in Settings to go online."
        case .networkUnavailable, .networkFailure: return "No connection. Seal tries again."
        case .quotaExceeded: return "iCloud storage is full."
        case .serverRejectedRequest, .invalidArguments: return "Apple's server refused the request. \(ck.localizedDescription)"
        default: return "iCloud error \(ck.code.rawValue): \(ck.localizedDescription)"
        }
    }
}

/// Validates every inbound record's signature chain before it reaches
/// the model layer (SDS §3). Unverifiable records are dropped, never shown.
struct VerificationGate {
    let identity: IdentityManager

    func admit(recordPayload: Data, signature: Data, deviceKey: Data,
               claimedRoot: RootIdentity, endorsements: [DeviceEndorsement]) -> Bool {
        identity.verify(signature: signature, over: recordPayload, deviceKey: deviceKey,
                        claimedRoot: claimedRoot, endorsements: endorsements)
    }
}
