// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import CryptoKit

//  Capsule.swift
//  Seal
//
//  THE CAPSULE: the archive of record (docs/CAPSULE.md).
//
//  CloudKit dies with the Apple developer account. The thing that has to
//  outlive the company is a file on each custodian's own disk carrying
//  everything a stranger with a laptop needs to check the record and, once
//  released, to open the envelopes: the encrypted envelopes, the encrypted
//  key tables, the wrapped shares, every public key involved, the full
//  signed record with its timestamp tokens, and the format version.
//
//  It is plain JSON with hex and base64 fields so that no Swift, no Apple
//  device and no Seal is needed to read it. `tools/verify_capsule.py` is the
//  independent verifier; the format is specified for a stranger in
//  docs/CAPSULE.md. Bump `version` for any incompatible change and keep the
//  verifier reading the old one.

struct SealCapsule: Codable {
    static let format = "seal.capsule"
    static let version = 1

    struct Assertion: Codable {
        let credentialIDHex: String
        let clientDataJSONBase64: String
        let authenticatorDataHex: String
        let signatureHex: String

        init(_ a: WebAuthnAssertion) {
            credentialIDHex = a.credentialID.hexString
            clientDataJSONBase64 = a.clientDataJSON.base64EncodedString()
            authenticatorDataHex = a.authenticatorData.hexString
            signatureHex = a.signature.hexString
        }
    }

    struct Endorsement: Codable {
        let devicePublicKeyHex: String
        let kemBundleHex: String
        let assertion: Assertion
        let createdAtEpoch: Int64
    }

    struct Identity: Codable {
        let rootHash: String
        let publicKeyHex: String
        let displayName: String
        let tier: String
        /// Endorsements as the exporting phone verified them, with root-signed
        /// revocations already applied. The verifier re-checks every one.
        let deviceEndorsements: [Endorsement]
    }

    struct Event: Codable {
        let id: String
        let estateID: String
        let kind: String
        let actorHash: String
        let actorDevicePublicKeyHex: String
        let occurredAtEpoch: Int64
        let previousDigestHex: String
        let payloadBase64: String
        let signatureHex: String
        let timestampTokenBase64: String?
        /// Redundant: the verifier recomputes it. Here so a reader can find
        /// an event by digest without code.
        let digestHex: String
    }

    let format: String
    let version: Int
    let relyingPartyID: String
    let exportedAtEpoch: Int64
    let exportedBy: String
    let estateID: String
    let ownerHash: String
    let identities: [String: Identity]
    let events: [Event]
    /// Epoch number to the epoch material blob, base64 of the exact bytes the
    /// owner published, so `materialDigest` in the epoch event can be checked.
    let epochBlobsBase64: [String: String]
    /// Table id to the table wrap blob, base64 of the exact bytes published.
    let tableBlobsBase64: [String: String]
    /// Blob id to encrypted content, base64. Present only when the exporter
    /// chose to include media; the key tables reference these by id.
    let contentBlobsBase64: [String: String]
    /// What the exporting phone understood the state to be. Informational.
    let stateAtExport: String
}

enum CapsuleBuilder {

    enum BuildError: LocalizedError {
        case unknownEstate
        var errorDescription: String? { "This phone does not hold that estate." }
    }

    static func build(estateID: String,
                      engine: EstateEngine,
                      sync: SyncEngine,
                      includeContent: Bool) async throws -> Data {
        let mine = engine.ownerHash
        let events: [EstateEvent]
        let ownerHash: String
        let custodianHashes: [String]
        if let estate = engine.estate, estate.id == estateID {
            events = engine.ownerEvents
            ownerHash = estate.ownerHash
            custodianHashes = estate.custodians.map(\.rootHash)
        } else if let g = engine.guarded.first(where: { $0.estateID == estateID }) {
            events = engine.guardedEvents[estateID] ?? []
            ownerHash = g.ownerHash
            custodianHashes = g.epoch?.custodianHashes ?? []
        } else {
            throw BuildError.unknownEstate
        }

        // Identities: owner, custodians, and every actor that appears.
        var wanted = Set([ownerHash] + custodianHashes + events.map(\.actorHash))
        wanted.insert(mine)
        var identities: [String: SealCapsule.Identity] = [:]
        for hash in wanted {
            guard let found = try? await sync.fetchIdentity(credentialIDHash: hash) else { continue }
            let (root, endorsements) = found
            let live = IdentityManager.verifiedDevices(root: root, endorsements: endorsements)
            identities[hash] = SealCapsule.Identity(
                rootHash: hash,
                publicKeyHex: root.publicKey.hexString,
                displayName: root.displayName,
                tier: root.tier.rawValue,
                deviceEndorsements: live.compactMap { e in
                    guard let a = try? JSONDecoder().decode(WebAuthnAssertion.self, from: e.assertion) else { return nil }
                    return SealCapsule.Endorsement(devicePublicKeyHex: e.devicePublicKey.hexString,
                                               kemBundleHex: e.kemBundlePublicKeys.hexString,
                                               assertion: SealCapsule.Assertion(a),
                                               createdAtEpoch: RecordEvent.epochSeconds(e.createdAt))
                })
        }

        // Blobs.
        var epochBlobs: [String: String] = [:]
        var tableBlobs: [String: String] = [:]
        var contentBlobs: [String: String] = [:]
        for e in events where e.kind == .epochPublished {
            if let body = e.body(EpochBody.self),
               let data = try? await sync.fetchEstateBlob(name: EstateNames.epochBlob(estateID, body.epoch)) {
                epochBlobs[String(body.epoch)] = data.base64EncodedString()
            }
        }
        if let vault = events.filter({ $0.kind == .vaultUpdated })
            .max(by: { ($0.occurredAtEpoch, $0.id) < ($1.occurredAtEpoch, $1.id) })?.body(VaultBody.self) {
            for tableID in vault.tableIDs {
                if let data = try? await sync.fetchEstateBlob(name: EstateNames.tableBlob(estateID, tableID)) {
                    tableBlobs[tableID] = data.base64EncodedString()
                }
            }
        }
        if includeContent, let estate = engine.estate, estate.id == estateID {
            // The owner knows every blob id. A custodian does not (by design)
            // and exports the record without content.
            for blobID in estate.envelopes.flatMap(\.blobIDs) {
                if let data = try? await sync.fetchEstateBlob(name: EstateNames.contentBlob(estateID, blobID)) {
                    contentBlobs[blobID] = data.base64EncodedString()
                }
            }
        }

        let snapshot = engine.estate?.id == estateID ? engine.ownerSnapshot : engine.guardedSnapshots[estateID]
        let state = snapshot.map { ReleaseMachine.state($0, now: engine.now).rawValue } ?? "unknown"

        let capsule = SealCapsule(
            format: SealCapsule.format,
            version: SealCapsule.version,
            relyingPartyID: CeremonyManager.relyingPartyID,
            exportedAtEpoch: RecordEvent.epochSeconds(engine.now),
            exportedBy: mine,
            estateID: estateID,
            ownerHash: ownerHash,
            identities: identities,
            events: events.map { e in
                SealCapsule.Event(id: e.id, estateID: e.estateID, kind: e.kind.rawValue, actorHash: e.actorHash,
                              actorDevicePublicKeyHex: e.actorDevicePublicKey.hexString,
                              occurredAtEpoch: e.occurredAtEpoch,
                              previousDigestHex: e.previousDigest.hexString,
                              payloadBase64: e.payload.base64EncodedString(),
                              signatureHex: e.signature.hexString,
                              timestampTokenBase64: e.timestampToken?.base64EncodedString(),
                              digestHex: e.digest.hexString)
            },
            epochBlobsBase64: epochBlobs,
            tableBlobsBase64: tableBlobs,
            contentBlobsBase64: contentBlobs,
            stateAtExport: state)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(capsule)
    }
}
