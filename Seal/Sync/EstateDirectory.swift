// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import CloudKit
import os

//  EstateDirectory.swift
//  Seal
//
//  CLOUDKIT TRANSPORT FOR ESTATES (conversion brief, phase 6).
//
//  CloudKit is transport, not the archive of record. The archive of record
//  is the capsule on each custodian's disk (docs/CAPSULE.md). What lives
//  here is enough for the phones to find each other's events and blobs.
//
//  ONE new record type, and two reused ones, because every new field is a
//  schema deployment that only Nathan can do (docs/CLOUDKIT_DEPLOY.md):
//
//    EstateEvent   NEW. name `eev.<estateID>.<eventID>`
//                  estate (String, QUERYABLE), kind (String), actor (String),
//                  payload (Bytes: the EstateEvent JSON, signature and all).
//                  Events are immutable; only `timestampToken` is added later.
//    MediaAsset    reused for every encrypted blob: epoch material, table
//                  wraps, envelope payloads, photos, voice notes.
//    GroupInvite   reused for "you are a custodian / recipient of this
//                  estate", encrypted to the addressee's devices, found
//                  through the existing `recipient` query and subscription.
//
//  Everything in the public database is world readable. Nothing here is in
//  the clear except an event's kind and actor, which the signed record
//  carries anyway.

/// Deterministic record names.
enum EstateNames {
    static func event(_ estateID: String, _ eventID: String) -> String { "eev.\(estateID).\(eventID)" }
    static func epochBlob(_ estateID: String, _ epoch: UInt64) -> String { "est.\(estateID).epoch.\(epoch)" }
    static func tableBlob(_ estateID: String, _ tableID: String) -> String { "est.\(estateID).table.\(tableID)" }
    static func contentBlob(_ estateID: String, _ blobID: String) -> String { "est.\(estateID).blob.\(blobID)" }
    static func invite(_ recipientHash: String, _ estateID: String) -> String { "estinv.\(recipientHash).\(estateID)" }
}

/// "You have a part in this estate." Sent by the owner, encrypted to the
/// addressee's devices. A recipient invite says nothing to anyone else about
/// which envelopes exist.
struct EstateInvite: Codable, Hashable {
    enum Role: String, Codable { case custodian, recipient }
    let estateID: String
    let ownerHash: String
    let ownerName: String
    let role: Role
}

/// The wire form: the invite JSON wrapped to the addressee.
struct EstateInviteEnvelope: Codable {
    let estateInvite: [HybridWrap.Envelope]
}

extension SyncEngine {

    private static let estateLog = Logger(subsystem: "io.github.jasonepage.Seal", category: "estate.sync")

    static let inviteAAD = Data("seal.estate.invite.v1".utf8)

    // MARK: - Events

    /// Create only. An event that already exists is left alone: they are
    /// immutable and a retry after a lost response must not fail.
    func publishEstateEvent(_ event: EstateEvent) async throws {
        let id = CKRecord.ID(recordName: EstateNames.event(event.estateID, event.id))
        if (try? await publicDB.record(for: id)) != nil { return }
        let record = CKRecord(recordType: "EstateEvent", recordID: id)
        record["estate"] = event.estateID
        record["kind"] = event.kind.rawValue
        record["actor"] = event.actorHash
        record["payload"] = try JSONEncoder().encode(event)
        do {
            try await publicDB.save(record)
        } catch let error as CKError where error.code == .serverRecordChanged {
            return   // somebody (our other device) saved the same event first
        }
    }

    /// Attach a timestamp token to an already published event. The token is
    /// outside the digest and outside the signature, so this is the one
    /// field that may change after publication.
    func attachEstateTimestamp(estateID: String, eventID: String, token: Data) async throws {
        let id = CKRecord.ID(recordName: EstateNames.event(estateID, eventID))
        let record = try await publicDB.record(for: id)
        guard let data = record["payload"] as? Data,
              var event = try? JSONDecoder().decode(EstateEvent.self, from: data) else { return }
        guard event.timestampToken == nil else { return }
        event.timestampToken = token
        record["payload"] = try JSONEncoder().encode(event)
        try await publicDB.save(record)
    }

    /// Every event for one estate. Follows the query cursor so a long record
    /// is not silently cut at CloudKit's page size. Events that fail to
    /// decode are skipped; signature checking is the verifier's job.
    func fetchEstateEvents(estateID: String) async throws -> [EstateEvent] {
        let query = CKQuery(recordType: "EstateEvent", predicate: NSPredicate(format: "estate == %@", estateID))
        var out: [EstateEvent] = []
        var (results, cursor) = try await publicDB.records(matching: query, resultsLimit: 200)
        while true {
            for (_, result) in results {
                if let record = try? result.get(), let data = record["payload"] as? Data,
                   let event = try? JSONDecoder().decode(EstateEvent.self, from: data),
                   event.estateID == estateID {
                    out.append(event)
                }
            }
            guard let next = cursor else { break }
            (results, cursor) = try await publicDB.records(continuingMatchFrom: next, resultsLimit: 200)
        }
        return out
    }

    /// Wake the phones that guard an estate when an event lands on it.
    ///
    /// SILENT ON PURPOSE (v2). v1 carried an alert, a sound and a badge, and
    /// it fired on EVERY EstateEvent. The owner writes a heartbeat event on
    /// every launch and every foreground (EstateEngine.heartbeat), with no
    /// rate limit, because opening the app IS the check-in. So v1 pushed
    /// "Something changed on an estate you guard." to every key holder and
    /// every recipient several times a day, for years, to say that somebody
    /// was alive. That is the fastest way to teach a key holder to turn Seal
    /// off, and a key holder with notifications off is the one person this
    /// product cannot afford to lose.
    ///
    /// Filtering heartbeats out of the predicate was the other option. It
    /// needs `kind` QUERYABLE in both CloudKit environments, and an index
    /// that is missing fails silently (docs/GOTCHAS.md, twice). So instead
    /// this wakes the app with content-available and nothing else, the app
    /// refreshes, and CustodianNotices posts a LOCAL notification only when
    /// the release state actually moved, with text that names the person and
    /// says what happened. A fixed CloudKit alert string could never do that.
    ///
    /// The cost, stated plainly: iOS throttles silent pushes and drops them
    /// when the phone is in low power mode, so a claim may go unheard until
    /// the phone next opens Seal. The release timeline runs in weeks, not
    /// minutes, and every foreground refreshes, so that is a delay rather
    /// than a miss. UIBackgroundModes already lists remote-notification.
    func ensureEstateSubscription(estateID: String) async {
        let subID = "seal.estsub.v2.\(estateID)"
        if (try? await publicDB.subscription(for: subID)) != nil { return }
        _ = try? await publicDB.deleteSubscription(withID: "seal.estsub.v1.\(estateID)")
        let subscription = CKQuerySubscription(
            recordType: "EstateEvent",
            predicate: NSPredicate(format: "estate == %@", estateID),
            subscriptionID: subID,
            options: .firesOnRecordCreation)
        let info = CKSubscription.NotificationInfo()
        // No title, no alertBody, no sound, no badge. Setting only
        // shouldSendContentAvailable is what makes APNs treat this as a
        // background wake rather than something the person sees.
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        do { _ = try await publicDB.save(subscription) }
        catch { Self.estateLog.error("estate subscription failed: \(error.localizedDescription, privacy: .public)") }
    }

    // MARK: - Blobs

    /// Fetch-then-update, so epoch material and table wraps can be replaced
    /// on rotation. Content blobs are written once and never replaced, but
    /// the same call handles a retry.
    func saveEstateBlob(_ data: Data, name: String) async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let id = CKRecord.ID(recordName: name)
        let record = (try? await publicDB.record(for: id)) ?? CKRecord(recordType: "MediaAsset", recordID: id)
        record["blob"] = CKAsset(fileURL: tempURL)
        try await publicDB.save(record)
    }

    func fetchEstateBlob(name: String) async throws -> Data? {
        try await fetchMediaAsset(name)
    }

    // MARK: - Invites

    func publishEstateInvite(_ invite: EstateInvite, to addresseeHash: String, addresseeBundles: [Data]) async throws {
        let plaintext = try EstateEvent.encodeBody(invite)
        let wraps = try HybridWrap.wrapToAll(plaintext, to: addresseeBundles, aad: Self.inviteAAD)
        let id = CKRecord.ID(recordName: EstateNames.invite(addresseeHash, invite.estateID))
        let record = (try? await publicDB.record(for: id)) ?? CKRecord(recordType: "GroupInvite", recordID: id)
        record["recipient"] = addresseeHash
        record["payload"] = try JSONEncoder().encode(EstateInviteEnvelope(estateInvite: wraps))
        try await publicDB.save(record)
    }

    /// Every estate invite addressed to me that my KEM keys can open.
    func fetchEstateInvites(myHash: String, mine: KEMPrivateBundle) async throws -> [EstateInvite] {
        try await fetchGroupInvites(recipientHash: myHash).compactMap { data in
            guard let envelope = try? JSONDecoder().decode(EstateInviteEnvelope.self, from: data),
                  let plaintext = try? HybridWrap.openAny(envelope.estateInvite, with: mine, aad: Self.inviteAAD)
            else { return nil }
            return try? JSONDecoder().decode(EstateInvite.self, from: plaintext)
        }
    }
}
