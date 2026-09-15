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
    func isTombstoned(credentialIDHash hash: String) async throws -> Bool {
        if DeletedIdentityLedger.contains(hash) { return true }
        let id = CKRecord.ID(recordName: Self.tombstoneName(hash))
        do { _ = try await publicDB.record(for: id); return true }
        catch let error as CKError where error.code == .unknownItem { return false }
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
        status = .error("Couldn't publish this device's key, others won't be able to read your messages. It'll retry.")
        WebAuthnDiag.log.error("publishIdentity: gave up after 3 attempts")
        return .failed
    }

    /// Fetch a (claimed) identity from the directory. The caller must still
    /// verify its endorsement chain, the server is untrusted for integrity.
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

    /// Append a (root-key-signed) device revocation to our directory record.
    func publishRevocation(_ revocation: DeviceRevocation, for credentialIDHash: String) async throws {
        let recordID = CKRecord.ID(recordName: credentialIDHash)
        let record = try await publicDB.record(for: recordID)
        var revocations: [DeviceRevocation] = []
        if let existing = record["revocations"] as? Data,
           let decoded = try? JSONDecoder().decode([DeviceRevocation].self, from: existing) {
            revocations = decoded
        }
        revocations.append(revocation)
        record["revocations"] = try JSONEncoder().encode(revocations)
        try await publicDB.save(record)
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
    func deleteIdentity(credentialIDHash: String) async throws {
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
        record["deviceEndorsements"] = Data()
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
        try? await publicDB.save(record)
        // Say whether the flip actually landed. When it did not (a record
        // another account created), the marker still kills the identity,
        // and the directory scan now honours markers directly.
        let flipped = (try? await publicDB.record(for: recordID))
            .map { $0["tier"] as? String == Self.deletedTier } ?? false
        WebAuthnDiag.log.info("deleteIdentity: tombstoned \(credentialIDHash, privacy: .public) (marker written; live record flipped: \(flipped, privacy: .public))")
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
    func fetchDeviceList(credentialIDHash: String) async throws -> ([DeviceEndorsement], [DeviceRevocation]) {
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
        return (endorsements, revocations)
    }

    // Moderation (App Store 1.2): reports are emailed to the developer from
    // ChatView (mailto), no CloudKit record / backend needed. Block is local
    // (ChatEngine). Action on a valid report = tombstone the identity (deleteIdentity).

    // MARK: - Message transport (deterministic record names, no queries)
    //
    // KeyEnvelope: "kenv.<groupID>[.e<epoch>].<senderHash>.<recipientHash>"
    // Message:     "msg.<groupID>[.e<epoch>].<senderHash>.<chainIndex>"
    // Epoch 0 keeps the legacy (no-epoch) names for compatibility; rotation
    // (FR-13) bumps the epoch, giving every sender fresh chains that removed
    // members never receive envelopes for.

    private static func envelopeName(_ g: String, _ e: UInt64, _ s: String, _ r: String) -> String {
        e == 0 ? "kenv.\(g).\(s).\(r)" : "kenv.\(g).e\(e).\(s).\(r)"
    }
    private static func messageName(_ g: String, _ e: UInt64, _ s: String, _ i: UInt64) -> String {
        e == 0 ? "msg.\(g).\(s).\(i)" : "msg.\(g).e\(e).\(s).\(i)"
    }

    func saveKeyEnvelope(groupID: String, epoch: UInt64, senderHash: String, recipientHash: String, envelope: Data) async throws {
        let id = CKRecord.ID(recordName: Self.envelopeName(groupID, epoch, senderHash, recipientHash))
        // Fetch-then-update so we OVERWRITE an existing envelope instead of
        // failing on its change tag. The envelope for (group, epoch, sender,
        // recipient) must carry the sender's CURRENT chain key. If the sender
        // re-keyed, a new session after a sign-out/reinstall wiped the local
        // send chain, a plain create would collide with the old record and
        // leave the recipient holding an envelope wrapped to stale keys
        // ("Couldn't unlock messages"). Replacing it is the fix.
        let record = (try? await publicDB.record(for: id))
            ?? CKRecord(recordType: "KeyEnvelope", recordID: id)
        record["envelope"] = envelope
        try await publicDB.save(record)
    }

    func fetchKeyEnvelope(groupID: String, epoch: UInt64, senderHash: String, recipientHash: String) async throws -> Data? {
        let id = CKRecord.ID(recordName: Self.envelopeName(groupID, epoch, senderHash, recipientHash))
        do {
            let record = try await publicDB.record(for: id)
            return record["envelope"] as? Data
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    struct WireMessage {
        let ciphertext: Data
        let senderDevicePublicKey: Data
        let signature: Data
        let sentAt: Date
    }

    func saveMessage(groupID: String, epoch: UInt64, senderHash: String, chainIndex: UInt64,
                     message: WireMessage, recipients: [String]) async throws {
        let record = CKRecord(
            recordType: "Message",
            recordID: CKRecord.ID(recordName: Self.messageName(groupID, epoch, senderHash, chainIndex)))
        record["ciphertext"] = message.ciphertext
        record["devicePub"] = message.senderDevicePublicKey
        record["signature"] = message.signature
        record["sentAt"] = message.sentAt
        // Drives the push subscription. CloudKit can't type an empty list
        // (Note to self has no recipients), so only set it when non-empty.
        if !recipients.isEmpty {
            record["recipients"] = recipients
        }
        try await publicDB.save(record)
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
            try? await publicDB.deleteSubscription(withID: id)
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
            try? await publicDB.deleteSubscription(withID: old)
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

    func fetchMessage(groupID: String, epoch: UInt64, senderHash: String, chainIndex: UInt64) async throws -> WireMessage? {
        let id = CKRecord.ID(recordName: Self.messageName(groupID, epoch, senderHash, chainIndex))
        do {
            let record = try await publicDB.record(for: id)
            guard let ct = record["ciphertext"] as? Data,
                  let dp = record["devicePub"] as? Data,
                  let sig = record["signature"] as? Data,
                  let at = record["sentAt"] as? Date else { return nil }
            return WireMessage(ciphertext: ct, senderDevicePublicKey: dp, signature: sig, sentAt: at)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    private static func friendly(_ error: Error) -> String {
        guard let ck = error as? CKError else { return error.localizedDescription }
        switch ck.code {
        case .notAuthenticated: return "Sign in to iCloud in Settings to go online."
        case .networkUnavailable, .networkFailure: return "No connection, will retry."
        case .quotaExceeded: return "iCloud storage is full."
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
