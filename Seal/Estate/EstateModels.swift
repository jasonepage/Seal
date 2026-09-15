import Foundation
import CryptoKit

//  EstateModels.swift
//  Seal
//
//  THE DATA MODEL OF THE SEALED-ENVELOPE PRODUCT (conversion brief, section 4).
//
//  One person (the OWNER) writes a small number of ENVELOPES, each addressed
//  to one RECIPIENT. They hand physical security keys to a few CUSTODIANS and
//  set a POLICY for how the envelopes open after they are gone. All of that
//  together is an ESTATE. There is exactly one estate per owner identity.
//
//  What is local to the owner's phone and what is published:
//    - `Estate` (this file) is the owner's private working copy: policy,
//      custodian list, and every envelope in the clear. It lives in the
//      keychain under the owner's identity hash like every other store.
//    - What custodians and recipients see is the ESTATE LOG (EstateLog.swift):
//      signed, hash-linked events, plus encrypted blobs. Nothing in the log
//      says what an envelope is called or who it is for.

// MARK: - Policy

struct ReleasePolicy: Codable, Hashable {

    enum ObjectionBehavior: String, Codable, CaseIterable {
        /// A custodian's objection stops the clock until they withdraw it.
        case pause
        /// A custodian's objection kills the claim outright.
        case veto

        var label: String {
            switch self {
            case .pause: "Pause the countdown"
            case .veto: "Stop the release"
            }
        }
    }

    static let allowedSilenceDays = [30, 90, 180, 365]
    static let defaultSilenceDays = 90
    static let defaultWarningDays = 21
    static let defaultGraceDays = 14

    /// How long the owner can go without opening the app before custodians
    /// may start a claim.
    var silenceDays: Int = defaultSilenceDays
    /// How long the owner is warned, daily, after a claim opens.
    var warningDays: Int = defaultWarningDays
    /// A quiet period after the warnings, before keys can be tapped.
    var graceDays: Int = defaultGraceDays
    /// M custodians out of N must tap.
    var threshold: Int
    var objectionBehavior: ObjectionBehavior = .pause

    enum PolicyError: LocalizedError, Equatable {
        case silenceNotAllowed(Int)
        case warningTooShort
        case graceNegative
        case thresholdOutOfRange(threshold: Int, custodians: Int)

        var errorDescription: String? {
            switch self {
            case .silenceNotAllowed(let d):
                "Silence must be one of \(ReleasePolicy.allowedSilenceDays.map(String.init).joined(separator: ", ")) days, not \(d)."
            case .warningTooShort: "Warnings must run for at least one day."
            case .graceNegative: "The grace period cannot be negative."
            case .thresholdOutOfRange(let m, let n):
                "The rule needs between 1 and \(n) custodians to agree. \(m) is not possible."
            }
        }
    }

    func validate(custodianCount: Int) throws {
        guard Self.allowedSilenceDays.contains(silenceDays) else { throw PolicyError.silenceNotAllowed(silenceDays) }
        guard warningDays >= 1 else { throw PolicyError.warningTooShort }
        guard graceDays >= 0 else { throw PolicyError.graceNegative }
        guard threshold >= 1, threshold <= custodianCount else {
            throw PolicyError.thresholdOutOfRange(threshold: threshold, custodians: custodianCount)
        }
    }

    var silence: TimeInterval { TimeInterval(silenceDays) * 86_400 }
    var warning: TimeInterval { TimeInterval(warningDays) * 86_400 }
    var grace: TimeInterval { TimeInterval(graceDays) * 86_400 }

    /// One line a 60 year old can read back and agree with.
    func summary(custodianCount: Int) -> String {
        "Any \(threshold) of your \(custodianCount) custodians, after \(silenceDays) days of silence, \(warningDays) days of warnings and \(graceDays) days of grace."
    }
}

// MARK: - Custodians and recipients

/// Someone the owner handed a key to. A custodian is a Seal identity met in
/// person, so their root key is pinned and their devices are endorsed.
struct Custodian: Codable, Identifiable, Hashable {
    var id: String { rootHash }
    let rootHash: String
    /// Snapshot at the time of adding, the way CustodyReceipt snapshots names.
    var displayName: String
    let addedAt: Date
    /// The two-sided signed handover of the physical key, if one was
    /// recorded (Receipts/CustodyReceipt.swift). Optional: a custodian can
    /// be added before the key changes hands.
    var handoverReceiptID: String?
}

/// Where an envelope goes. Today a recipient must be a Seal identity, because
/// only an identity has KEM keys to wrap a key table to. See docs/PRODUCT.md
/// for why there is no "whoever opens it" option yet.
struct Recipient: Codable, Identifiable, Hashable {
    var id: String { rootHash }
    let rootHash: String
    var displayName: String
}

// MARK: - Envelopes

struct MediaItem: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case photo, voice }
    var id: String { blobID }
    let blobID: String
    let kind: Kind
    let sha256: Data
    let byteCount: Int
    /// Local file name under the owner's estate media directory. The
    /// encrypted copy in CloudKit is `MediaAsset` record `blobID`.
    let localName: String
}

/// Everything the owner wrote for one person. Kept in the clear on the
/// owner's phone only. Published as one encrypted payload blob (letter and
/// secrets) plus one encrypted blob per media item.
struct Envelope: Codable, Identifiable, Hashable {
    let id: String
    var recipientHash: String
    var title: String
    var letter: String
    var photos: [MediaItem]
    var voiceNote: MediaItem?
    /// The secrets. A `SealedCard` already carries a title, a value and a
    /// note and refuses to be summarised; that is exactly a secret field.
    var secrets: [SealedCard]
    /// Among this recipient's envelopes, lowest opens first.
    var revealOrder: Int
    let createdAt: Date
    var updatedAt: Date
    /// The random 256 bit content key. Generated once, never rotated: the
    /// blobs are encrypted under it and rotation happens above it.
    let contentKey: Data
    /// Set once the payload blob has been published.
    var payloadBlobID: String?
    /// True once every blob for this envelope is in CloudKit and the
    /// recipient's key table lists it.
    var sealed: Bool

    /// The plaintext that goes into the payload blob. Media is referenced by
    /// blob id and hash so the recipient can check what they downloaded.
    struct Payload: Codable, Hashable {
        let title: String
        let letter: String
        let secrets: [SealedCard]
        let photos: [MediaItem]
        let voiceNote: MediaItem?
        let revealOrder: Int
        let writtenAtEpoch: Int64
    }

    var payload: Payload {
        Payload(title: title, letter: letter, secrets: secrets, photos: photos, voiceNote: voiceNote,
                revealOrder: revealOrder, writtenAtEpoch: RecordEvent.epochSeconds(updatedAt))
    }

    var blobIDs: [String] {
        [payloadBlobID].compactMap { $0 } + photos.map(\.blobID) + [voiceNote?.blobID].compactMap { $0 }
    }

    static func new(recipientHash: String, title: String, now: Date, revealOrder: Int) -> Envelope {
        Envelope(id: UUID().uuidString, recipientHash: recipientHash, title: title, letter: "",
                 photos: [], voiceNote: nil, secrets: [], revealOrder: revealOrder,
                 createdAt: now, updatedAt: now, contentKey: EstateCrypto.randomKey(),
                 payloadBlobID: nil, sealed: false)
    }
}

// MARK: - The estate

/// The owner's private working copy. One per owner identity.
struct Estate: Codable, Hashable {
    let id: String
    let ownerHash: String
    var epoch: UInt64
    var policy: ReleasePolicy
    var custodians: [Custodian]
    var recipients: [Recipient]
    var envelopes: [Envelope]
    let createdAt: Date
    /// Per recipient: the random table id and the Key Table Key. Owner only.
    var tableKeys: [String: TableKeyRecord]
    /// True once epoch material for `epoch` has been published to the log.
    var epochPublished: Bool
    /// The custodian set and threshold the published epoch was built for.
    /// A difference from the current values means the next seal rotates.
    var publishedCustodianHashes: [String] = []
    var publishedThreshold: Int = 0
    /// Table ids published in the last vault statement, for the record.
    var publishedTableIDs: [String] = []
    /// The rule as last published, so a change to silence, warning or grace
    /// days is noticed and announced with a policyChanged event.
    var publishedPolicy: ReleasePolicy? = nil

    struct TableKeyRecord: Codable, Hashable {
        let tableID: String
        let tableKey: Data
    }

    static func new(ownerHash: String, now: Date) -> Estate {
        Estate(id: UUID().uuidString, ownerHash: ownerHash, epoch: 0,
               policy: ReleasePolicy(threshold: 1), custodians: [], recipients: [], envelopes: [],
               createdAt: now, tableKeys: [:], epochPublished: false)
    }

    func envelopes(for recipientHash: String) -> [Envelope] {
        envelopes.filter { $0.recipientHash == recipientHash }.sorted { $0.revealOrder < $1.revealOrder }
    }

    /// The Key Table for one recipient, from the owner's copy.
    func keyTable(for recipientHash: String) -> KeyTable {
        KeyTable(recipientHash: recipientHash, entries: envelopes(for: recipientHash).map {
            KeyTableEntry(envelopeID: $0.id, contentKey: $0.contentKey, title: $0.title,
                          revealOrder: $0.revealOrder, blobIDs: $0.blobIDs)
        })
    }

    var isReadyToSeal: Bool {
        !custodians.isEmpty && (try? policy.validate(custodianCount: custodians.count)) != nil
    }

    /// Custodians or threshold changed since the last published epoch, or
    /// nothing has been published yet.
    var needsNewEpoch: Bool {
        !epochPublished
            || publishedCustodianHashes != custodians.map(\.rootHash)
            || publishedThreshold != policy.threshold
    }

    var hasUnsealedChanges: Bool {
        needsNewEpoch || publishedPolicy != policy || envelopes.contains { !$0.sealed }
    }
}

// MARK: - Local store

/// Keychain JSON namespaced by owner hash, like every other store. Wiped by
/// `ContentView.wipeLocalAndEngines`.
enum EstateStore {
    private static func key(_ ownerHash: String) -> String { "seal.estate.\(ownerHash)" }

    static func load(ownerHash: String) -> Estate? {
        guard let data = KeychainStore.load(key(ownerHash)) else { return nil }
        return try? JSONDecoder().decode(Estate.self, from: data)
    }

    static func save(_ estate: Estate) {
        if let data = try? JSONEncoder().encode(estate) {
            KeychainStore.save(data, for: key(estate.ownerHash))
        }
    }

    static func wipe(ownerHash: String) {
        KeychainStore.delete(key(ownerHash))
        EstateLogStore.wipe(ownerHash: ownerHash)
        CustodianVault.wipe(ownerHash: ownerHash)
    }
}
