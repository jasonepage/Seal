import Foundation
import CryptoKit

//  RecordEvent.swift
//  Seal
//
//  THE RECORD (docs/RECORD.md).
//
//  Seal is a signed record of what happened between two people who met in
//  person, and the record is of EVENTS, not content. It can show that a sealed
//  card carrying a payment address was sent at a given moment, and prove the
//  exact bytes of that card have not changed, without ever being able to read
//  the address. That is the design, not a workaround.
//
//  THIS FILE ADDS NO NEW SOURCE OF TRUTH.
//  --------------------------------------
//  Four features already record events and each keeps its own store: friendships
//  in FriendStore, introductions in IntroductionStore, sealed cards inside
//  ChatEngine's messages, handovers in ReceiptStore. `RecordEvent` is a
//  PROJECTION over those, computed on demand, exactly the way ForgeLogView
//  already derives its list. Materialising a second copy is how a record system
//  quietly becomes worthless: two stores that can disagree are worse than one
//  store, because now nobody knows which one to believe.
//
//  WHAT PHASE 1 DELIBERATELY DOES NOT DO
//  -------------------------------------
//  No network, no new crypto, no trusted timestamps. Every event here carries
//  `timeProof == .deviceClaimed`, which is the honest description of what Seal
//  can say about time today: the moment came off the acting phone's own clock,
//  and a modified client could have written anything there. The UI says exactly
//  that and does not dress it up. Phase 2 (RECORD.md section 4) adds RFC 3161
//  tokens and the other two states, which is why they already exist in the enum
//  rather than being retrofitted through every switch later.

struct RecordEvent: Identifiable, Hashable {

    enum Kind: String {
        case metInPerson
        case metReciprocal          // their phone ran the ceremony, ours took their signed word
        case metThroughIntroduction // a linked edge: vouched for, not witnessed
        case introductionMade       // we vouched for two other people
        case cardSent
        case cardReceived
        case handover               // both parties signed one commitment
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
    /// The message this line describes has been deleted on its TTL schedule and
    /// only the tombstone remains (RecordStub.swift). Deliberately NOT part of
    /// the digest: an event does not become a different event when its content
    /// goes, and a line whose id changed at the moment it burned would be
    /// useless as evidence.
    let contentBurned: Bool

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
         contentBurned: Bool = false,
         timeProof: TimeProof = .deviceClaimed) {
        self.kind = kind
        self.occurredAt = occurredAt
        self.counterpartHash = counterpartHash
        self.counterpartName = counterpartName
        self.summary = summary
        self.sourceRef = sourceRef
        self.contentBurned = contentBurned
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
    /// `counterpart` filters to one person's timeline. Events with a nil
    /// counterpart (a card into a group, an introduction between two others)
    /// are correctly absent from a person's timeline and present in the whole
    /// record.
    static func events(myRoot: RootIdentity,
                       friendStore: FriendStore,
                       chatEngine: ChatEngine,
                       receipts: [CustodyReceipt],
                       stubs: [RecordStub] = [],
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

        // 1. Meetings. `isInPerson` is derived from the presence of an
        //    introduction proof, so these three cases are exhaustive.
        for friend in friendStore.friends {
            let f = friend.friendship
            let hash = friend.identity.credentialIDHash
            let display = friend.identity.displayName
            let kind: RecordEvent.Kind
            let summary: String
            if let proof = f.introduction {
                kind = .metThroughIntroduction
                let by = name(for: proof.introducerHash) ?? "someone you've met"
                summary = "Connected through an introduction by \(by). Not met in person."
            } else if f.autoReciprocated == true {
                kind = .metReciprocal
                summary = "Met in person. Their phone ran the ceremony and this one took their signed word for it."
            } else {
                kind = .metInPerson
                summary = "Met in person. They tapped their key on this phone."
            }
            out.append(RecordEvent(kind: kind,
                                   occurredAt: f.forgedAt,
                                   counterpartHash: hash,
                                   counterpartName: display,
                                   summary: summary,
                                   sourceRef: hash))
        }

        // 2. Sealed cards. The title travels, the value never does.
        var liveCards = Set<String>()
        for chat in chatEngine.chats {
            let others = chat.memberHashes.filter { $0 != myRoot.credentialIDHash }
            for message in chatEngine.messages(for: chat) {
                guard let card = message.card else { continue }
                let mine = message.senderHash == myRoot.credentialIDHash
                // A 1:1 chat has exactly one counterpart. A group has no single
                // one, so the event belongs to the whole record and not to any
                // person's timeline.
                let partner: String? = mine ? (others.count == 1 ? others[0] : nil)
                                            : message.senderHash
                let ref = message.wireID ?? message.id.uuidString
                liveCards.insert(ref)
                let where_ = partner == nil ? " in \(chat.name)" : ""
                out.append(RecordEvent(
                    kind: mine ? .cardSent : .cardReceived,
                    occurredAt: message.sentAt,
                    counterpartHash: partner,
                    counterpartName: name(for: partner),
                    summary: (mine ? "You sealed a card: " : "Sealed card received: ")
                             + card.title + where_,
                    sourceRef: ref,
                    contentDigestHex: (message.proof?.cardDigest ?? card.digest)?.hexString))
            }
        }

        // 2b. Cards whose content has burned. The live projection wins while
        //     the message exists; the tombstone is what is left afterwards, and
        //     it produces the same digest, so the line keeps its identity
        //     across the burn (RecordStub.swift).
        for stub in stubs where !liveCards.contains(stub.sourceRef) {
            guard let kind = stub.kind else { continue }
            out.append(RecordEvent(
                kind: kind,
                occurredAt: stub.occurredAt,
                counterpartHash: stub.counterpartHash,
                counterpartName: stub.counterpartName ?? name(for: stub.counterpartHash),
                summary: (kind == .cardSent ? "You sealed a card: " : "Sealed card received: ")
                         + stub.title,
                sourceRef: stub.sourceRef,
                contentDigestHex: stub.contentDigestHex,
                contentBurned: true))
        }

        // 3. Handovers. The only event type where BOTH people signed the same
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

        // 4. Introductions this phone made. Emitted once per party so the event
        //    appears on both of their timelines, and the two digests differ
        //    because the counterpart is part of the canonical encoding.
        for entry in chatEngine.introductions.entries
        where entry.isIntroducer(myRoot.credentialIDHash) {
            let s = entry.statement
            for (party, other) in [(s.partyAHash, s.partyBHash), (s.partyBHash, s.partyAHash)] {
                out.append(RecordEvent(
                    kind: .introductionMade,
                    occurredAt: s.createdAt,
                    counterpartHash: party,
                    counterpartName: name(for: party),
                    summary: "You introduced them to \(name(for: other) ?? "someone else you've met").",
                    sourceRef: s.commitmentHex))
            }
        }

        // Blocks are deliberately absent. `ChatEngine.blockedHashes` is a bare
        // Set with no signature and no time, so there is nothing to place on a
        // timeline and nothing to prove. Inventing a moment for it would be the
        // one kind of entry a record must never contain.

        if let counterpart {
            out = out.filter { $0.counterpartHash == counterpart }
        }
        // Resolve what Seal can honestly say about each event's time. Done here
        // rather than in the initialiser because a token can arrive long after
        // the event, and because the digest must not depend on it.
        for index in out.indices {
            out[index].timeProof = TimestampStore.proof(forDigest: out[index].digest.hexString,
                                                        in: timestamps,
                                                        enabled: timestampsEnabled)
        }
        return out.sorted { $0.occurredAt > $1.occurredAt }
    }
}
