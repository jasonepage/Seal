// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import CryptoKit

//  RecordEvent.swift
//  Seal
//
//  THE RECORD (docs/RECORD.md).
//
//  A signed record of what happened: who this person met in person, what
//  changed hands, and everything that happened to their sealed envelopes.
//  The record is of EVENTS, not content. It can show that four envelopes
//  were sealed on a Sunday night and that a custodian tapped a key on a
//  Tuesday, and prove those lines have not changed, without being able to
//  read a single envelope.
//
//  THIS FILE ADDS NO NEW SOURCE OF TRUTH. `RecordEvent` is a PROJECTION over
//  the stores that already exist: friendships in FriendStore, handovers in
//  ReceiptStore, and the signed estate log in EstateLogStore. It is computed
//  on demand and never persisted. Two stores that can disagree are worse than
//  one, because then nobody knows which to believe.
//
//  Estate events are already signed and hash linked in their own log
//  (Estate/EstateLog.swift) and carry their own RFC 3161 tokens; this
//  projection renders them, it does not re-sign them.

struct RecordEvent: Identifiable, Hashable {

    enum Kind: String {
        case metInPerson
        case metReciprocal          // their phone ran the ceremony, ours took their signed word
        case handover               // both parties signed one commitment
        // The estate log, rendered.
        case estateCreated
        case custodiansKeyed        // an epoch: shares issued to custodians
        case envelopesSealed        // a vault statement
        case heartbeat
        case silenceObserved
        case claimOpened
        case objection
        case objectionWithdrawn
        case cancellation
        case keyTapped              // a custodian authorised the release
        case released
        case keyConfirmed           // a custodian tapped to say they still have their key (not a release tap)
    }

    /// What Seal can honestly say about WHEN this happened.
    ///
    /// Phase 1 only ever produces `.deviceClaimed`. The other two exist now so
    /// that adding timestamps later is a new producer rather than a change to
    /// every consumer, and so the UI switch is already exhaustive.
    enum TimeProof: String {
        /// The acting device's own clock. Signed, but not independently timed.
        case deviceClaimed
        /// A timestamp authority signed this event's digest (RECORD.md §4).
        case timestamped
        /// Queued for timestamping and not yet confirmed. Never rendered as
        /// though a token exists: "I could not reach the authority" and "the
        /// authority vouched for this" have opposite consequences, and one grey
        /// state covering both is a lie in whichever direction it resolves.
        case pendingTimestamp
    }

    let kind: Kind
    let occurredAt: Date
    /// nil when the event is not about one specific other person, such as an
    /// introduction seen from the introducer's side, or a card sent to a group.
    let counterpartHash: String?
    /// Snapshot, the way CustodyReceipt snapshots names: a record has to read
    /// correctly years later even if somebody renamed themselves. The HASH is
    /// the identity, the name is a convenience.
    let counterpartName: String?
    /// One line, safe to render anywhere. NEVER a card's value: a truncated
    /// address in a list row is an invitation to misread it, which is the same
    /// rule `ChatEngine.summary` already follows.
    let summary: String
    /// Where this came from in its own store: a friend's root hash, a wireID,
    /// a receiptID, an introduction commitment.
    let sourceRef: String
    let digest: Data
    /// Not `let`: this is the one thing about an event that changes after
    /// the fact, when a timestamp token arrives. It is deliberately not a
    /// digest field, so gaining a token does not change the event's id.
    var timeProof: TimeProof
    var id: String { digest.hexString }

    // MARK: - Canonical encoding

    /// Domain-separated and length-delimited, the same discipline
    /// `CustodyReceipt.commitment` uses. The `seal.record.v1` prefix means a
    /// record digest can never be replayed as a friend ceremony
    /// (`seal.friend.v1`), a receipt, or a reciprocal handshake. Length
    /// prefixes mean no two different events can collide by shuffling bytes
    /// between fields, which matters the moment these digests get signed by a
    /// timestamp authority in phase 2.
    ///
    /// Whole seconds, stored as an integer, for the reason CustodyReceipt gives:
    /// an integer round-trips exactly and cannot carry a hostile magnitude into
    /// a trapping conversion.
    /// Whole seconds, and NON-TRAPPING. `Int64(someDouble)` traps on a
    /// non-finite or out-of-range value, and CustodyReceipt already documents
    /// why that matters: a hostile or corrupt magnitude arriving from stored
    /// data would crash the app rather than render a bad row. A record viewer
    /// that dies on one line is worse than one that shows a wrong date.
    static func epochSeconds(_ date: Date) -> Int64 {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite else { return 0 }
        return Int64(min(max(seconds, -1e12), 1e12))
    }

    static func digest(kind: Kind,
                       occurredAt: Date,
                       counterpartHash: String?,
                       sourceRef: String,
                       contentDigestHex: String?) -> Data {
        var out = Data("seal.record.v1".utf8)
        let fields = [kind.rawValue,
                      String(epochSeconds(occurredAt)),
                      counterpartHash ?? "",
                      sourceRef,
                      contentDigestHex ?? ""]
        for field in fields {
            let bytes = Data(field.utf8)
            var length = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
            out.append(bytes)
        }
        return Data(SHA256.hash(data: out))
    }

    init(kind: Kind,
         occurredAt: Date,
         counterpartHash: String?,
         counterpartName: String?,
         summary: String,
         sourceRef: String,
         contentDigestHex: String? = nil,
         timeProof: TimeProof = .deviceClaimed) {
        self.kind = kind
        self.occurredAt = occurredAt
        self.counterpartHash = counterpartHash
        self.counterpartName = counterpartName
        self.summary = summary
        self.sourceRef = sourceRef
        self.timeProof = timeProof
        self.digest = Self.digest(kind: kind,
                                  occurredAt: occurredAt,
                                  counterpartHash: counterpartHash,
                                  sourceRef: sourceRef,
                                  contentDigestHex: contentDigestHex)
    }
}

// MARK: - The projection

enum RecordBuilder {

    /// Every event this phone can account for, newest first.
    ///
    /// `counterpart` filters to one person's timeline. Estate events are
    /// about the owner's own estate and have no single counterpart except
    /// where a custodian acted, in which case that custodian is the
    /// counterpart.
    static func events(myRoot: RootIdentity,
                       friendStore: FriendStore,
                       receipts: [CustodyReceipt],
                       estateEvents: [EstateEvent] = [],
                       timestamps: [String: TimestampRecord] = [:],
                       timestampsEnabled: Bool = false,
                       counterpart: String? = nil) -> [RecordEvent] {

        // Names resolved once. `uniquingKeysWith` rather than the trapping
        // initialiser: FriendStore.add already de-duplicates, and a crash in a
        // record viewer over a duplicate row would be a poor trade.
        let names = Dictionary(friendStore.friends.map {
            ($0.identity.credentialIDHash, $0.identity.displayName)
        }, uniquingKeysWith: { first, _ in first })

        func name(for hash: String?) -> String? {
            guard let hash else { return nil }
            if hash == myRoot.credentialIDHash { return myRoot.displayName }
            return names[hash]
        }

        var out: [RecordEvent] = []

        // 1. Meetings.
        for friend in friendStore.friends {
            let f = friend.friendship
            let hash = friend.identity.credentialIDHash
            let kind: RecordEvent.Kind = f.autoReciprocated == true ? .metReciprocal : .metInPerson
            let summary = kind == .metReciprocal
                ? "Met in person. Their phone ran the ceremony and this one took their signed word for it."
                : "Met in person. They tapped their key on this phone."
            out.append(RecordEvent(kind: kind,
                                   occurredAt: f.forgedAt,
                                   counterpartHash: hash,
                                   counterpartName: friend.identity.displayName,
                                   summary: summary,
                                   sourceRef: hash))
        }

        // 2. Handovers. The only event type where BOTH people signed the same
        //    commitment, which makes it the strongest thing in here.
        for receipt in receipts {
            let mine = receipt.giverHash == myRoot.credentialIDHash
            let partner = mine ? receipt.receiverHash : receipt.giverHash
            let partnerName = mine ? receipt.receiverName : receipt.giverName
            out.append(RecordEvent(
                kind: .handover,
                occurredAt: receipt.signedAt,
                counterpartHash: partner,
                counterpartName: partnerName,
                summary: (mine ? "You handed over: " : "You received: ") + receipt.itemDescription,
                sourceRef: receipt.receiptID,
                contentDigestHex: receipt.photoSHA256?.hexString))
        }

        // 3. The estate log. Already signed, already linked; rendered here so
        //    the whole record reads as one thing. A line carries its own
        //    token, so its time proof comes from the event, not the store.
        for e in estateEvents {
            let mine = e.actorHash == myRoot.credentialIDHash
            let who = mine ? "You" : (name(for: e.actorHash) ?? "A custodian")
            let kind: RecordEvent.Kind
            let summary: String
            switch e.kind {
            case .estateCreated:
                kind = .estateCreated; summary = "\(who) started sealed envelopes."
            case .epochPublished:
                let n = e.body(EpochBody.self)
                kind = .custodiansKeyed
                summary = "\(who) issued key shares to \(n?.custodianHashes.count ?? 0) custodians, any \(n?.threshold ?? 0) to open."
            case .policyChanged:
                kind = .custodiansKeyed; summary = "\(who) changed the release rule."
            case .vaultUpdated:
                kind = .envelopesSealed; summary = "\(who) sealed the envelopes."
            case .heartbeat:
                kind = .heartbeat; summary = "\(who) checked in."
            case .silenceObserved:
                kind = .silenceObserved; summary = "\(who) noted the owner had been silent past the limit."
            case .releaseClaimed:
                kind = .claimOpened; summary = "\(who) opened a claim to release the envelopes."
            case .objection:
                kind = .objection; summary = "\(who) objected to the release."
            case .objectionWithdrawn:
                kind = .objectionWithdrawn; summary = "\(who) withdrew an objection."
            case .cancellation:
                kind = .cancellation; summary = "\(who) stopped the release."
            case .authorization:
                kind = .keyTapped; summary = "\(who) tapped a key to authorise the release."
            case .released:
                kind = .released; summary = "\(who) combined the keys. The envelopes are released."
            case .custodyConfirmed:
                kind = .keyConfirmed; summary = "\(who) tapped their key to confirm they still have it. Not a release tap."
            }
            var event = RecordEvent(kind: kind,
                                    occurredAt: e.occurredAt,
                                    counterpartHash: mine ? nil : e.actorHash,
                                    counterpartName: mine ? nil : name(for: e.actorHash),
                                    summary: summary,
                                    sourceRef: e.id,
                                    contentDigestHex: e.digest.hexString)
            event.timeProof = e.timestampToken == nil ? .deviceClaimed : .timestamped
            out.append(event)
        }

        if let counterpart {
            out = out.filter { $0.counterpartHash == counterpart }
        }
        // Resolve what Seal can honestly say about each non-estate event's
        // time. Done here rather than in the initialiser because a token can
        // arrive long after the event, and because the digest must not depend
        // on it. Estate lines already carry their answer.
        let stampable: Set<RecordEvent.Kind> = [.metInPerson, .metReciprocal, .handover]
        for index in out.indices where stampable.contains(out[index].kind) {
            out[index].timeProof = TimestampStore.proof(forDigest: out[index].digest.hexString,
                                                        in: timestamps,
                                                        enabled: timestampsEnabled)
        }
        return out.sorted { $0.occurredAt > $1.occurredAt }
    }
}
