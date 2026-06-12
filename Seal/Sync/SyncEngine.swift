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
            record["credentialID"] = root.rawCredentialID
            record["deviceEndorsements"] = try JSONEncoder().encode([endorsement])
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
        return (root, endorsements)
    }

    // MARK: - Message transport (deterministic record names — no queries)
    //
    // KeyEnvelope: "kenv.<groupID>.<senderHash>.<recipientHash>"
    // Message:     "msg.<groupID>.<senderHash>.<chainIndex>"
    // Receivers fetch the next expected index per sender; CKError.unknownItem
    // means "no more messages." E2EE: CloudKit only ever sees ciphertext.

    func saveKeyEnvelope(groupID: String, senderHash: String, recipientHash: String, envelope: Data) async throws {
        let record = CKRecord(
            recordType: "KeyEnvelope",
            recordID: CKRecord.ID(recordName: "kenv.\(groupID).\(senderHash).\(recipientHash)"))
        record["envelope"] = envelope
        try await publicDB.save(record)
    }

    func fetchKeyEnvelope(groupID: String, senderHash: String, recipientHash: String) async throws -> Data? {
        let id = CKRecord.ID(recordName: "kenv.\(groupID).\(senderHash).\(recipientHash)")
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

    func saveMessage(groupID: String, senderHash: String, chainIndex: UInt64, message: WireMessage) async throws {
        let record = CKRecord(
            recordType: "Message",
            recordID: CKRecord.ID(recordName: "msg.\(groupID).\(senderHash).\(chainIndex)"))
        record["ciphertext"] = message.ciphertext
        record["devicePub"] = message.senderDevicePublicKey
        record["signature"] = message.signature
        record["sentAt"] = message.sentAt
        try await publicDB.save(record)
    }

    func fetchMessage(groupID: String, senderHash: String, chainIndex: UInt64) async throws -> WireMessage? {
        let id = CKRecord.ID(recordName: "msg.\(groupID).\(senderHash).\(chainIndex)")
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
