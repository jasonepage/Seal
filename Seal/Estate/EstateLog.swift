// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import CryptoKit

//  EstateLog.swift
//  Seal
//
//  THE SIGNED, HASH-LINKED ESTATE RECORD.
//
//  Everything that happens to an estate after it is created is an
//  `EstateEvent`: the owner's heartbeats, custodians' observations, a claim,
//  objections, cancellations, key taps, the release. Each event is signed by
//  the actor's Secure Enclave device key (endorsed by their root credential,
//  verified through the pinned root key) and names the digest of the latest
//  event its writer had seen. That makes the record a hash-linked DAG rather
//  than one strict chain, because the owner and several custodians write to
//  it concurrently and CloudKit gives no ordering. A verifier checks every
//  signature and every link; what it cannot check is that no event was
//  HIDDEN, which is why the events that matter also carry RFC 3161 tokens.
//
//  WHAT IS NEVER IN THE LOG: an envelope's title, its recipient, or the
//  number of envelopes. The `vaultUpdated` event carries a single commitment
//  over the set of blob ids, nothing more.
//
//  Digests use the same domain-separated, length-framed discipline as
//  RecordEvent and CustodyReceipt.

struct EstateEvent: Codable, Hashable, Identifiable {

    enum Kind: String, Codable, CaseIterable {
        /// Owner. Payload: EstateCreatedBody.
        case estateCreated
        /// Owner. Payload: EpochBody (commitments, threshold, custodian hashes).
        case epochPublished
        /// Owner. Payload: PolicyBody.
        case policyChanged
        /// Owner. Payload: VaultBody (one commitment over blob ids).
        case vaultUpdated
        /// Owner. Empty payload. "I am here."
        case heartbeat
        /// Custodian. Payload: ObservationBody.
        case silenceObserved
        /// Custodian. Payload: ClaimBody.
        case releaseClaimed
        /// Custodian. Payload: ObjectionBody.
        case objection
        /// Custodian. Payload: ObjectionBody with withdrawn = true.
        case objectionWithdrawn
        /// Owner. Payload: CancellationBody.
        case cancellation
        /// Custodian. Payload: AuthorizationBody (the WebAuthn assertion).
        case authorization
        /// Claimant. Payload: ReleasedBody (Estate Key wrapped to recipients).
        case released
        /// Custodian. Payload: CustodyConfirmedBody. "I still have my key."
        /// A custody receipt, NOT an authorization: ReleaseFeed ignores it
        /// and its challenge lives in a different domain
        /// (CustodyConfirmation.swift). Added 2026-09-16.
        case custodyConfirmed
    }

    let id: String
    let estateID: String
    let kind: Kind
    let actorHash: String
    /// x963 public key of the signing device.
    let actorDevicePublicKey: Data
    /// The actor's own clock, whole seconds. Provable only via the token.
    let occurredAtEpoch: Int64
    /// Digest of the latest event the writer had seen, or empty for the
    /// first event of the estate.
    let previousDigest: Data
    /// Canonical JSON of the kind's body. Empty for heartbeats.
    let payload: Data
    /// DER ECDSA over `digest`, by `actorDevicePublicKey`.
    let signature: Data
    /// RFC 3161 token over `digest`. Not part of the digest.
    var timestampToken: Data?

    var occurredAt: Date { Date(timeIntervalSince1970: TimeInterval(occurredAtEpoch)) }

    static let domain = "seal.estate.event.v1"

    static func digest(id: String, estateID: String, kind: Kind, actorHash: String,
                       actorDevicePublicKey: Data, occurredAtEpoch: Int64,
                       previousDigest: Data, payload: Data) -> Data {
        var input = Data(domain.utf8)
        func field(_ data: Data) {
            var length = UInt32(data.count).bigEndian
            withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
            input.append(data)
        }
        field(Data(id.utf8))
        field(Data(estateID.utf8))
        field(Data(kind.rawValue.utf8))
        field(Data(actorHash.utf8))
        field(actorDevicePublicKey)
        field(Data(String(occurredAtEpoch).utf8))
        field(previousDigest)
        field(payload)
        return Data(SHA256.hash(data: input))
    }

    var digest: Data {
        Self.digest(id: id, estateID: estateID, kind: kind, actorHash: actorHash,
                    actorDevicePublicKey: actorDevicePublicKey, occurredAtEpoch: occurredAtEpoch,
                    previousDigest: previousDigest, payload: payload)
    }

    /// Signature check only. Whether the device is endorsed by the claimed
    /// root is `EstateLogVerifier`'s job, because it needs the directory.
    func signatureIsValid() -> Bool {
        guard let pub = try? P256.Signing.PublicKey(x963Representation: actorDevicePublicKey),
              let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
        return pub.isValidSignature(sig, for: digest)
    }

    func body<T: Decodable>(_ type: T.Type) -> T? {
        try? JSONDecoder().decode(type, from: payload)
    }

    static func encodeBody<T: Encodable>(_ body: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(body)
    }
}

// MARK: - Bodies

struct EstateCreatedBody: Codable, Hashable {
    let policy: ReleasePolicy
    let createdAtEpoch: Int64
}

struct EpochBody: Codable, Hashable {
    let epoch: UInt64
    let threshold: Int
    /// Custodian root hashes in share index order (index i+1 is custodians[i]).
    let custodianHashes: [String]
    /// Their root public keys, same order, as the owner pinned them at the
    /// ceremony. Custodians who never met each other learn each other's keys
    /// from THIS signed statement and pin them, so the directory cannot put
    /// a stranger between a custodian and the claimant.
    let custodianPublicKeys: [Data]
    /// SHA-256 of each share's encoded form, same order.
    let shareCommitments: [Data]
    let estateKeyCommitment: Data
    /// SHA-256 of the canonical JSON of the EpochKeyMaterial blob, so the
    /// blob a custodian downloads can be checked against the signed record.
    let materialDigest: Data
}

struct PolicyBody: Codable, Hashable {
    let policy: ReleasePolicy
}

struct VaultBody: Codable, Hashable {
    /// SHA-256 over the sorted, newline-joined blob ids. One number; not the
    /// list. A recipient learns their own blob ids from their key table.
    let blobCommitment: Data
    /// The key table blob ids. Random names, one per recipient, so the
    /// number of recipients is visible and nothing else is. A recipient
    /// trial-opens each one.
    let tableIDs: [String]
}

struct ObservationBody: Codable, Hashable {
    /// The newest heartbeat digest this custodian could find, or nil.
    let lastHeartbeatDigest: Data?
    let lastHeartbeatAtEpoch: Int64?
}

struct ClaimBody: Codable, Hashable {
    let claimID: String
    let epoch: UInt64
    /// What the claimant saw: the newest heartbeat, for the record.
    let lastHeartbeatAtEpoch: Int64?
    let reason: String
}

struct ObjectionBody: Codable, Hashable {
    let claimID: String
    let withdrawn: Bool
    let note: String
}

struct CancellationBody: Codable, Hashable {
    /// nil cancels whatever claim is open.
    let claimID: String?
}

struct AuthorizationBody: Codable, Hashable {
    let claimID: String
    let epoch: UInt64
    /// The record head the custodian was shown when they tapped.
    let recordHeadDigest: Data
    /// The custodian's ROOT credential assertion over
    /// `ReleaseChallenge.challenge(...)`. The physical tap.
    let assertion: WebAuthnAssertion
    /// This custodian's Shamir share, re-wrapped to the CLAIMANT's endorsed
    /// devices (AAD: `ReleaseChallenge.shareAAD`). The tap is the proof; the
    /// share is the contribution. M taps put M shares on the claiming phone.
    let shareForClaimant: [HybridWrap.Envelope]
}

struct ReleasedBody: Codable, Hashable {
    let claimID: String
    let epoch: UInt64
    /// Which shares were used, by index.
    let shareIndexes: [UInt8]
    /// THE ESTATE KEY, IN THE CLEAR. This is the moment the seal breaks and
    /// the record shows it. It is safe to publish because the Estate Key on
    /// its own opens nothing: every key table is also wrapped to its
    /// recipient's own devices, and every blob is under a content key that
    /// lives inside a table. Publishing it here is what lets each recipient
    /// open their own table on their own phone without the claimant ever
    /// learning who the recipients are.
    let estateKey: Data
}

// MARK: - The release challenge

enum ReleaseChallenge {
    /// The challenge a custodian's key signs to authorise a release. Binds
    /// estate, epoch, claim and the record head, so a tap for one claim can
    /// never be replayed for another, and so the custodian is signing over
    /// the exact history they were shown.
    static func challenge(estateID: String, epoch: UInt64, claimID: String, recordHeadDigest: Data) -> Data {
        var input = Data("seal.release.authorize.v1".utf8)
        func field(_ data: Data) {
            var length = UInt32(data.count).bigEndian
            withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
            input.append(data)
        }
        field(Data(estateID.utf8))
        field(Data(String(epoch).utf8))
        field(Data(claimID.utf8))
        field(recordHeadDigest)
        return Data(SHA256.hash(data: input))
    }

    /// AAD for a share re-wrapped to the claimant inside an authorization.
    static func shareAAD(estateID: String, epoch: UInt64, claimID: String) -> Data {
        Data("seal.release.share.v1|\(estateID)|\(epoch)|\(claimID)".utf8)
    }
}

// MARK: - Building events

enum EstateEventBuilder {

    enum BuildError: Error { case noDeviceKey }

    /// Signs a new event with this phone's device key. `previousDigest` is
    /// the head the caller has seen (EstateLogStore.headDigest).
    static func make(kind: EstateEvent.Kind,
                     estateID: String,
                     actorHash: String,
                     deviceKey: SecureEnclave.P256.Signing.PrivateKey,
                     previousDigest: Data,
                     payload: Data,
                     now: Date) throws -> EstateEvent {
        let id = UUID().uuidString
        let devicePub = deviceKey.publicKey.x963Representation
        let at = RecordEvent.epochSeconds(now)
        let digest = EstateEvent.digest(id: id, estateID: estateID, kind: kind, actorHash: actorHash,
                                        actorDevicePublicKey: devicePub, occurredAtEpoch: at,
                                        previousDigest: previousDigest, payload: payload)
        let signature = try deviceKey.signature(for: digest)
        return EstateEvent(id: id, estateID: estateID, kind: kind, actorHash: actorHash,
                           actorDevicePublicKey: devicePub, occurredAtEpoch: at,
                           previousDigest: previousDigest, payload: payload,
                           signature: signature.derRepresentation, timestampToken: nil)
    }

    /// Same, with a software key. Used by the self-tests and by nothing else.
    static func makeWithSoftwareKey(kind: EstateEvent.Kind,
                                    estateID: String,
                                    actorHash: String,
                                    deviceKey: P256.Signing.PrivateKey,
                                    previousDigest: Data,
                                    payload: Data,
                                    now: Date) throws -> EstateEvent {
        let id = UUID().uuidString
        let devicePub = deviceKey.publicKey.x963Representation
        let at = RecordEvent.epochSeconds(now)
        let digest = EstateEvent.digest(id: id, estateID: estateID, kind: kind, actorHash: actorHash,
                                        actorDevicePublicKey: devicePub, occurredAtEpoch: at,
                                        previousDigest: previousDigest, payload: payload)
        let signature = try deviceKey.signature(for: digest)
        return EstateEvent(id: id, estateID: estateID, kind: kind, actorHash: actorHash,
                           actorDevicePublicKey: devicePub, occurredAtEpoch: at,
                           previousDigest: previousDigest, payload: payload,
                           signature: signature.derRepresentation, timestampToken: nil)
    }
}

// MARK: - Verification against the directory

/// Which events to believe. The directory is untrusted for integrity, so an
/// event counts only when its signing device is endorsed by the root it
/// claims, that root's key matches the pin, and the actor is allowed to
/// write that kind of event for this estate.
enum EstateLogVerifier {

    struct Directory {
        /// Root hash to (identity, live endorsements), as fetched through
        /// `SyncEngine.fetchIdentity` (which already enforces pins).
        var identities: [String: (RootIdentity, [DeviceEndorsement])]
    }

    static let ownerKinds: Set<EstateEvent.Kind> = [.estateCreated, .epochPublished, .policyChanged, .vaultUpdated, .heartbeat, .cancellation]
    static let custodianKinds: Set<EstateEvent.Kind> = [.silenceObserved, .releaseClaimed, .objection, .objectionWithdrawn, .authorization, .released, .custodyConfirmed]

    /// Returns the events whose signature chains verify and whose actor
    /// role is permitted, in the order given. Events by unknown actors are
    /// dropped: an estate's custodians are named in its epoch events by the
    /// owner, so "unknown" means "not a custodian".
    static func admitted(_ events: [EstateEvent],
                         ownerHash: String,
                         custodianHashes: Set<String>,
                         directory: Directory) -> [EstateEvent] {
        events.filter { event in
            guard event.signatureIsValid() else { return false }
            if event.actorHash == ownerHash {
                guard ownerKinds.contains(event.kind) else { return false }
            } else if custodianHashes.contains(event.actorHash) {
                guard custodianKinds.contains(event.kind) else { return false }
            } else {
                return false
            }
            guard let entry = directory.identities[event.actorHash] else { return false }
            let trusted = IdentityManager.verifiedDevices(root: entry.0, endorsements: entry.1)
            return trusted.contains { $0.devicePublicKey == event.actorDevicePublicKey }
        }
    }

    /// Every event's `previousDigest` must name an event in the set (or be
    /// empty). Returns the ids that dangle, for the record screen to show.
    static func danglingLinks(_ events: [EstateEvent]) -> [String] {
        let digests = Set(events.map(\.digest))
        return events.filter { !$0.previousDigest.isEmpty && !digests.contains($0.previousDigest) }.map(\.id)
    }
}

// MARK: - Local store

/// The local copy of an estate's log, per owner identity, keyed by estate id.
/// A custodian holds one per estate they guard; the owner holds their own.
enum EstateLogStore {
    private static func key(_ ownerHash: String) -> String { "seal.estatelog.\(ownerHash)" }

    static func load(ownerHash: String) -> [String: [EstateEvent]] {
        guard let data = KeychainStore.load(key(ownerHash)),
              let decoded = try? JSONDecoder().decode([String: [EstateEvent]].self, from: data)
        else { return [:] }
        return decoded
    }

    static func save(_ logs: [String: [EstateEvent]], ownerHash: String) {
        if let data = try? JSONEncoder().encode(logs) {
            KeychainStore.save(data, for: key(ownerHash))
        }
    }

    /// Merge by event id, keeping a token if either side has one.
    static func merged(_ existing: [EstateEvent], _ incoming: [EstateEvent]) -> [EstateEvent] {
        var byID: [String: EstateEvent] = [:]
        for e in existing { byID[e.id] = e }
        for e in incoming {
            if var have = byID[e.id] {
                if have.timestampToken == nil, let token = e.timestampToken {
                    have.timestampToken = token
                    byID[e.id] = have
                }
            } else {
                byID[e.id] = e
            }
        }
        return byID.values.sorted { ($0.occurredAtEpoch, $0.id) < ($1.occurredAtEpoch, $1.id) }
    }

    /// The digest a new event should link to: the newest event by the
    /// actor's clock, which is the best any writer can do without a server.
    static func headDigest(_ events: [EstateEvent]) -> Data {
        events.max { ($0.occurredAtEpoch, $0.id) < ($1.occurredAtEpoch, $1.id) }?.digest ?? Data()
    }

    static func wipe(ownerHash: String) {
        KeychainStore.delete(key(ownerHash))
    }
}
