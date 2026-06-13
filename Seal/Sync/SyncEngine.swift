import Foundation
import CloudKit

/// CloudKit transport (SDS §1, §4): public DB for the identity directory,
/// one custom zone per group shared via CKShare. Transport-level share
/// membership is NOT trusted — cryptographic membership is the signed
/// MembershipLog + key epochs.
@Observable
final class SyncEngine {
    static let containerID = "iCloud.io.github.jasonepage.Seal"

    enum CloudStatus: Equatable {
        case idle, publishing, published
        case error(String)
    }

    private(set) var status: CloudStatus = .idle

    /// Back to idle so a newly registered identity publishes itself.
    func resetStatus() { status = .idle }

    private var publicDB: CKDatabase {
        CKContainer(identifier: Self.containerID).publicCloudDatabase
    }

    // MARK: - Identity directory (FR-4)

    /// Publish (or refresh) our Identity record in the public database so
    /// friends' clients can fetch and verify it. Record name = credentialIDHash,
    /// so lookups are direct fetches — no queries needed.
    func publishIdentity(_ root: RootIdentity, endorsement: DeviceEndorsement) async {
        status = .publishing
        do {
            let recordID = CKRecord.ID(recordName: root.credentialIDHash)
            let record: CKRecord
            if let existing = try? await publicDB.record(for: recordID) {
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
            // TODO: revocations list, backup-key endorsements, head-hash chain
            //       for peer-to-peer key transparency (SDS §2)

            try await publicDB.save(record)

            // Round-trip check: prove the directory actually works.
            _ = try await publicDB.record(for: recordID)
            status = .published
        } catch {
            status = .error(Self.friendly(error))
        }
    }

    /// Fetch a (claimed) identity from the directory. The caller must still
    /// verify its endorsement chain — the server is untrusted for integrity.
    func fetchIdentity(credentialIDHash: String) async throws -> (RootIdentity, [DeviceEndorsement])? {
        let recordID = CKRecord.ID(recordName: credentialIDHash)
        let record: CKRecord
        do {
            record = try await publicDB.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
        guard
            let publicKey = record["publicKey"] as? Data,
            let tierRaw = record["tier"] as? String,
            let tier = IdentityTier(rawValue: tierRaw),
            let displayName = record["displayName"] as? String,
            let endorsementData = record["deviceEndorsements"] as? Data,
            let endorsements = try? JSONDecoder().decode([DeviceEndorsement].self, from: endorsementData)
        else { return nil }

        let root = RootIdentity(
            credentialIDHash: credentialIDHash,
            publicKey: publicKey,
            tier: tier,
            displayName: displayName,
            rawCredentialID: record["credentialID"] as? Data
        )

        // Filter out revoked devices before anyone trusts them (FR-19).
        var live = endorsements
        if let revocationData = record["revocations"] as? Data,
           let revocations = try? JSONDecoder().decode([DeviceRevocation].self, from: revocationData) {
            let revoked = IdentityManager.revokedDevicePublicKeys(root: root, revocations: revocations)
            live.removeAll { revoked.contains($0.devicePublicKey) }
        }
        return (root, live)
    }

    /// Every credential ID in the directory — fed to `excludedCredentials` at
    /// registration so an authenticator that already holds a Seal identity
    /// refuses to mint a second one (1 key ≈ 1 account; SDS §7: deterrence,
    /// not an invariant — FIDO2 reset or a modified client evades it).
    /// NOTE: requires the `recordName QUERYABLE` index on Identity in the
    /// CloudKit schema (console → Indexes → Identity), dev + Production.
    /// Scale ceiling is documented in SDS §7 — revisit past ~1k identities.
    func fetchAllCredentialIDs() async throws -> [Data] {
        let query = CKQuery(recordType: "Identity", predicate: NSPredicate(value: true))
        var ids: [Data] = []
        var (results, cursor) = try await publicDB.records(
            matching: query, desiredKeys: ["credentialID"], resultsLimit: 200)
        while true {
            for (_, result) in results {
                if let record = try? result.get(), let id = record["credentialID"] as? Data {
                    ids.append(id)
                }
            }
            guard let next = cursor else { break }
            (results, cursor) = try await publicDB.records(
                continuingMatchFrom: next, desiredKeys: ["credentialID"], resultsLimit: 200)
        }
        return ids
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
    func deleteIdentity(credentialIDHash: String) async throws {
        do {
            try await publicDB.deleteRecord(withID: CKRecord.ID(recordName: credentialIDHash))
        } catch let error as CKError where error.code == .unknownItem {
            // Already gone — deletion is idempotent.
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

    // MARK: - Founder perks (SDS §10 — deterministic names, no queries)
    //
    // PerkGrant: "perk.<SHA256(code)>"   — minted offline, world-readable.
    // PerkClaim: "pclaim.<SHA256(code)>" — created by the claimant; CloudKit
    // record creation is atomic, so the FIRST creator wins and (creator-only
    // write) nobody can stomp an existing claim. Honest residual: Apple could
    // HIDE a claim record (denial), but cannot forge one — clients only honor
    // claims whose signature chain verifies (PerkAuthority).

    /// Fetch a (claimed) grant. Caller MUST verify the founder signature —
    /// the server is untrusted for integrity.
    func fetchPerkGrant(codeHashHex: String) async throws -> PerkGrant? {
        let id = CKRecord.ID(recordName: PerkAuthority.grantRecordName(codeHashHex: codeHashHex))
        do {
            let record = try await publicDB.record(for: id)
            guard let data = record["grant"] as? Data else { return nil }
            return try? JSONDecoder().decode(PerkGrant.self, from: data)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    /// First-create-wins claim. Returns nil on success; on "already claimed"
    /// returns the existing claim (so redemption can tell "you already
    /// redeemed this" from "someone else got here first"). The race window is
    /// two simultaneous redeemers of the SAME code — the loser gets a clean
    /// error here, never a silent half-claim.
    func createPerkClaim(_ claim: PerkClaim) async throws -> PerkClaim? {
        let id = CKRecord.ID(recordName: PerkAuthority.claimRecordName(codeHashHex: claim.codeHashHex))
        let record = CKRecord(recordType: "PerkClaim", recordID: id)
        record["claim"] = try JSONEncoder().encode(claim)
        do {
            try await publicDB.save(record)
            return nil
        } catch let error as CKError where error.code == .serverRecordChanged {
            return try await fetchPerkClaim(codeHashHex: claim.codeHashHex)
        }
    }

    func fetchPerkClaim(codeHashHex: String) async throws -> PerkClaim? {
        let id = CKRecord.ID(recordName: PerkAuthority.claimRecordName(codeHashHex: codeHashHex))
        do {
            let record = try await publicDB.record(for: id)
            guard let data = record["claim"] as? Data else { return nil }
            return try? JSONDecoder().decode(PerkClaim.self, from: data)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    /// Append a perk attestation to our Identity record so friends' clients
    /// can fetch and verify it (same merge-don't-overwrite pattern as
    /// endorsements).
    func publishPerk(_ attestation: PerkAttestation, for credentialIDHash: String) async throws {
        let record = try await publicDB.record(for: CKRecord.ID(recordName: credentialIDHash))
        var perks: [PerkAttestation] = []
        if let existing = record["perks"] as? Data,
           let decoded = try? JSONDecoder().decode([PerkAttestation].self, from: existing) {
            perks = decoded
        }
        perks.removeAll { $0.grant.codeHashHex == attestation.grant.codeHashHex }
        perks.append(attestation)
        record["perks"] = try JSONEncoder().encode(perks)
        try await publicDB.save(record)
    }

    /// Raw (unverified) perk attestations from an Identity record. Callers
    /// MUST run PerkAuthority.verifiedPerks before display.
    func fetchPerks(credentialIDHash: String) async throws -> [PerkAttestation] {
        let record: CKRecord
        do {
            record = try await publicDB.record(for: CKRecord.ID(recordName: credentialIDHash))
        } catch let error as CKError where error.code == .unknownItem {
            return []
        }
        guard let data = record["perks"] as? Data,
              let decoded = try? JSONDecoder().decode([PerkAttestation].self, from: data)
        else { return [] }
        return decoded
    }

    // MARK: - Message transport (deterministic record names — no queries)
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
        let record = CKRecord(
            recordType: "KeyEnvelope",
            recordID: CKRecord.ID(recordName: Self.envelopeName(groupID, epoch, senderHash, recipientHash)))
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

    /// One subscription per identity: fire when a Message names me a recipient.
    /// The alert is static — content is ciphertext; there is nothing to preview.
    func ensureMessageSubscription(for myHash: String) async {
        // v2 = badge + content-available + title. Bumped because an existing
        // subscription is never reconfigured in place; the version forces a
        // fresh one and we retire v1 so the two don't double-fire.
        let subID = "seal.msgsub.v2.\(myHash)"
        if (try? await publicDB.subscription(for: subID)) != nil { return }
        try? await publicDB.deleteSubscription(withID: "seal.msgsub.\(myHash)")  // retire v1
        let subscription = CKQuerySubscription(
            recordType: "Message",
            predicate: NSPredicate(format: "recipients CONTAINS %@", myHash),
            subscriptionID: subID,
            options: .firesOnRecordCreation)
        let info = CKSubscription.NotificationInfo()
        info.title = "Seal"
        info.alertBody = "New sealed message"
        info.soundName = "default"
        info.shouldBadge = true                     // app-icon badge: "something's waiting"
        // Also wake the app in the background to pre-fetch, so the message is
        // decrypted and waiting the instant they open it. Requires the
        // "remote-notification" background mode (UIBackgroundModes) — without
        // that capability the alert still fires; only the silent wake no-ops.
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        do { _ = try await publicDB.save(subscription) }
        catch { status = .error("Push setup failed: \(error.localizedDescription)") }
    }

    /// Same pattern for group invites: without this, an invite sits unseen
    /// until the recipient happens to foreground the app. The push handler
    /// path (messageArrived → refreshAll → checkInvites) already processes it.
    func ensureInviteSubscription(for myHash: String) async {
        let subID = "seal.invsub.v2.\(myHash)"
        if (try? await publicDB.subscription(for: subID)) != nil { return }
        try? await publicDB.deleteSubscription(withID: "seal.invsub.\(myHash)")  // retire v1
        let subscription = CKQuerySubscription(
            recordType: "GroupInvite",
            predicate: NSPredicate(format: "recipient == %@", myHash),
            subscriptionID: subID,
            options: .firesOnRecordCreation)
        let info = CKSubscription.NotificationInfo()
        info.title = "Seal"
        info.alertBody = "You've been invited to a new colony"
        info.soundName = "default"
        info.shouldBadge = true
        info.shouldSendContentAvailable = true      // pre-process the invite in the background
        subscription.notificationInfo = info
        do { _ = try await publicDB.save(subscription) }
        catch { status = .error("Push setup failed: \(error.localizedDescription)") }
    }

    // MARK: - Media (encrypted blobs as CKAssets)

    /// Store an already-encrypted media blob. The content key never comes
    /// near this function — it travels inside the E2EE message payload.
    func saveMediaAsset(_ encrypted: Data) async throws -> String {
        let name = "media.\(UUID().uuidString)"
        try await saveMediaAsset(encrypted, name: name)
        return name
    }

    /// Caller-supplied record name — lets the offline outbox reserve the name
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
        case .networkUnavailable, .networkFailure: return "No connection — will retry."
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
