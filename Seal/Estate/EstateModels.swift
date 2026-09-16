// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
    static let allowedCustodyConfirmMonths = [6, 12, 24]
    static let defaultCustodyConfirmMonths = 12

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
    /// How often each key holder's phone asks them to tap their key and
    /// say they still have it (CustodyConfirmation.swift). Travels in the
    /// policy so the key holders' phones know the interval. Not part of
    /// the release rule; nothing in ReleaseMachine reads it.
    var custodyConfirmMonths: Int = defaultCustodyConfirmMonths

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
        custodianCount == 1
            ? "Your one key holder, after \(silenceDays) days of silence, \(warningDays) days of warnings and \(graceDays) days of grace."
            : "Any \(threshold) of your \(custodianCount) key holders, after \(silenceDays) days of silence, \(warningDays) days of warnings and \(graceDays) days of grace."
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
    /// `video` was added 2026-09-16. A build older than that cannot decode
    /// an envelope or a payload that carries one; every phone must run a
    /// current build, as with every other format change.
    enum Kind: String, Codable { case photo, voice, video }
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
    /// One short video message, up to about a minute. Sealed like a photo.
    var videoNote: MediaItem? = nil
    /// "Open no earlier than." A letter for a child's eighteenth birthday.
    /// It does NOT open anything: the envelope still needs the release
    /// (silence, warnings, grace, M taps). After the release, the
    /// recipient's phone keeps the envelope closed until this date. There
    /// is no trusted clock, so this is the recipient's phone honouring a
    /// request, not a lock; RELEASE.md section 9 says so and so does the
    /// editor. Travels in the payload so it is sealed with the letter.
    var openNoEarlierThan: Date? = nil
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

    /// WHO IT IS FOR, BEFORE THEY EXIST IN SEAL. A name typed by the owner,
    /// on an envelope that has not been bound to a real identity yet.
    ///
    /// The whole point: a new customer used to be able to write NOTHING
    /// until they had physically stood next to somebody who also had Seal
    /// installed and run a two minute ceremony. The recipient picker on a
    /// fresh install said "Nobody to write to yet." That is the hardest
    /// possible thing to ask for first, in exchange for nothing yet, and it
    /// is where people leave.
    ///
    /// So an envelope can be addressed to "Emma" and written tonight. It
    /// stays a draft, it is skipped by every step of the seal, and it binds
    /// to a real identity the day they meet. Meeting in person stops being
    /// the price of entry and becomes the thing that unlocks something they
    /// already wrote and now care about.
    ///
    /// Nothing about the isolation promise moves. An unbound envelope is
    /// never published, never wrapped, never in a key table (PRODUCT.md
    /// section 8 still holds: a recipient is a Seal identity met in person).
    var draftRecipientName: String? = nil

    /// "What to do first": the owner's ordered steps for this person. Sealed
    /// with the letter and the secrets under the same content key. See
    /// FirstSteps.swift. Empty for envelopes written before it existed.
    var firstSteps: [FirstStep] = []

    /// When the owner last said each secret is still right, keyed by
    /// `SealedCard.confirmationKey`. Owner's working copy only, never in
    /// the payload, so confirming never forces a re-seal (SecretReview.swift).
    var secretConfirmations: [String: Date] = [:]

    /// Unbound envelopes carry a made-up recipientHash with this prefix, so
    /// each one is still its own recipient for grouping and reveal order,
    /// and so no real identity hash can ever collide with one.
    static let unboundPrefix = "unbound."

    /// False while this is addressed to a typed name rather than a person.
    var isAddressed: Bool { !recipientHash.hasPrefix(Self.unboundPrefix) }

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
        /// Added 2026-09-16. A payload sealed before then has no key for
        /// these and decodes as empty (see the Decodable extension below).
        var firstSteps: [FirstStep] = []
        var videoNote: MediaItem? = nil
        /// Whole seconds since 1970, or nil. See Envelope.openNoEarlierThan.
        var openNoEarlierThanEpoch: Int64? = nil

        var openNoEarlierThan: Date? {
            openNoEarlierThanEpoch.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        }

        /// True while the recipient's phone should keep this closed.
        func isHeld(now: Date) -> Bool {
            guard let date = openNoEarlierThan else { return false }
            return now < date
        }
    }

    var payload: Payload {
        Payload(title: title, letter: letter, secrets: secrets, photos: photos, voiceNote: voiceNote,
                revealOrder: revealOrder, writtenAtEpoch: RecordEvent.epochSeconds(updatedAt),
                firstSteps: usableFirstSteps, videoNote: videoNote,
                openNoEarlierThanEpoch: openNoEarlierThan.map { RecordEvent.epochSeconds($0) })
    }

    /// Every media item in the envelope: photos, then the voice message,
    /// then the video. The engine encrypts, uploads and removes exactly
    /// this list, so adding a kind means adding it here and nowhere else.
    var allMedia: [MediaItem] {
        photos + [voiceNote, videoNote].compactMap { $0 }
    }

    var blobIDs: [String] {
        [payloadBlobID].compactMap { $0 } + allMedia.map(\.blobID)
    }

    static func new(recipientHash: String, title: String, now: Date, revealOrder: Int) -> Envelope {
        Envelope(id: UUID().uuidString, recipientHash: recipientHash, title: title, letter: "",
                 photos: [], voiceNote: nil, secrets: [], revealOrder: revealOrder,
                 createdAt: now, updatedAt: now, contentKey: EstateCrypto.randomKey(),
                 payloadBlobID: nil, sealed: false)
    }

    /// An envelope for somebody who is not in Seal yet. The content key is
    /// minted now like any other, so binding it later changes who can read
    /// it and nothing else about it.
    static func unbound(name: String, title: String, now: Date) -> Envelope {
        var envelope = new(recipientHash: Self.unboundPrefix + UUID().uuidString,
                           title: title, now: now, revealOrder: 1)
        envelope.draftRecipientName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return envelope
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
    /// Per custodian hash: a digest of each endorsed device KEM bundle the
    /// share was wrapped to at the last seal. `publishedCustodianHashes` is
    /// the set of PEOPLE. This is the set of PHONES, and it is the only
    /// thing that can notice a key holder who replaced theirs: device KEM
    /// keys are ThisDeviceOnly, so a new phone signs in, gets endorsed,
    /// and has no way to unwrap a share made for the old one. A stored
    /// property with a default, so estates saved before it existed decode.
    var publishedCustodianDevices: [String: [String]] = [:]
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

    /// Envelopes bound to a real identity. Everything the seal touches uses
    /// this, never `envelopes`.
    var addressedEnvelopes: [Envelope] { envelopes.filter(\.isAddressed) }

    /// Written, but for somebody who is not in Seal yet.
    var unaddressedEnvelopes: [Envelope] { envelopes.filter { !$0.isAddressed } }

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

    /// The digests recorded in `publishedCustodianDevices`: SHA-256 of each
    /// bundle, hex, sorted, so two fetches of the same directory record
    /// compare equal whatever order the endorsements came back in.
    static func deviceDigests(_ kemBundles: [Data]) -> [String] {
        kemBundles.map { Data(SHA256.hash(data: $0)).map { String(format: "%02x", $0) }.joined() }.sorted()
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

    /// `addressedEnvelopes`, not `envelopes`: an envelope written to a typed
    /// name is skipped by every step of the seal, so counting it here would
    /// leave the Seal button lit with nothing for it to do.
    var hasUnsealedChanges: Bool {
        needsNewEpoch || publishedPolicy != policy || addressedEnvelopes.contains { !$0.sealed }
    }
}

// MARK: - Decoding older shapes

extension ReleasePolicy {
    private enum Keys: String, CodingKey {
        case silenceDays, warningDays, graceDays, threshold, objectionBehavior, custodyConfirmMonths
    }

    /// `custodyConfirmMonths` was added 2026-09-16; a policy in an older
    /// estate, event or capsule has no key for it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        silenceDays = try c.decode(Int.self, forKey: .silenceDays)
        warningDays = try c.decode(Int.self, forKey: .warningDays)
        graceDays = try c.decode(Int.self, forKey: .graceDays)
        threshold = try c.decode(Int.self, forKey: .threshold)
        objectionBehavior = try c.decode(ObjectionBehavior.self, forKey: .objectionBehavior)
        custodyConfirmMonths = try c.decodeIfPresent(Int.self, forKey: .custodyConfirmMonths) ?? ReleasePolicy.defaultCustodyConfirmMonths
    }
}

//  A DEFAULT VALUE ON A STORED PROPERTY DOES NOT MAKE A MISSING KEY DECODE.
//  Swift's synthesized `init(from:)` calls `decode`, not `decodeIfPresent`,
//  for every non-optional property, so `var x: [T] = []` still throws
//  keyNotFound when the JSON has no "x". The estate in the keychain and the
//  payload blobs in CloudKit were written by older builds without the newer
//  keys, so these three types decode by hand: every key added after the
//  first release is read with `decodeIfPresent`. Encoding stays synthesized.
//  These live in extensions so the memberwise initialisers survive.

extension Envelope.Payload {
    private enum Keys: String, CodingKey {
        case title, letter, secrets, photos, voiceNote, revealOrder, writtenAtEpoch, firstSteps, videoNote
        case openNoEarlierThanEpoch
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        title = try c.decode(String.self, forKey: .title)
        letter = try c.decode(String.self, forKey: .letter)
        secrets = try c.decode([SealedCard].self, forKey: .secrets)
        photos = try c.decode([MediaItem].self, forKey: .photos)
        voiceNote = try c.decodeIfPresent(MediaItem.self, forKey: .voiceNote)
        revealOrder = try c.decode(Int.self, forKey: .revealOrder)
        writtenAtEpoch = try c.decode(Int64.self, forKey: .writtenAtEpoch)
        firstSteps = try c.decodeIfPresent([FirstStep].self, forKey: .firstSteps) ?? []
        videoNote = try c.decodeIfPresent(MediaItem.self, forKey: .videoNote)
        openNoEarlierThanEpoch = try c.decodeIfPresent(Int64.self, forKey: .openNoEarlierThanEpoch)
    }
}

extension Envelope {
    private enum Keys: String, CodingKey {
        case id, recipientHash, title, letter, photos, voiceNote, secrets, revealOrder
        case createdAt, updatedAt, contentKey, payloadBlobID, sealed, draftRecipientName, firstSteps
        case secretConfirmations, videoNote, openNoEarlierThan
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        recipientHash = try c.decode(String.self, forKey: .recipientHash)
        title = try c.decode(String.self, forKey: .title)
        letter = try c.decode(String.self, forKey: .letter)
        photos = try c.decode([MediaItem].self, forKey: .photos)
        voiceNote = try c.decodeIfPresent(MediaItem.self, forKey: .voiceNote)
        secrets = try c.decode([SealedCard].self, forKey: .secrets)
        revealOrder = try c.decode(Int.self, forKey: .revealOrder)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        contentKey = try c.decode(Data.self, forKey: .contentKey)
        payloadBlobID = try c.decodeIfPresent(String.self, forKey: .payloadBlobID)
        sealed = try c.decode(Bool.self, forKey: .sealed)
        draftRecipientName = try c.decodeIfPresent(String.self, forKey: .draftRecipientName)
        firstSteps = try c.decodeIfPresent([FirstStep].self, forKey: .firstSteps) ?? []
        secretConfirmations = try c.decodeIfPresent([String: Date].self, forKey: .secretConfirmations) ?? [:]
        videoNote = try c.decodeIfPresent(MediaItem.self, forKey: .videoNote)
        openNoEarlierThan = try c.decodeIfPresent(Date.self, forKey: .openNoEarlierThan)
    }
}

extension Estate {
    private enum Keys: String, CodingKey {
        case id, ownerHash, epoch, policy, custodians, recipients, envelopes, createdAt, tableKeys, epochPublished
        case publishedCustodianHashes, publishedThreshold, publishedCustodianDevices, publishedTableIDs, publishedPolicy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        ownerHash = try c.decode(String.self, forKey: .ownerHash)
        epoch = try c.decode(UInt64.self, forKey: .epoch)
        policy = try c.decode(ReleasePolicy.self, forKey: .policy)
        custodians = try c.decode([Custodian].self, forKey: .custodians)
        recipients = try c.decode([Recipient].self, forKey: .recipients)
        envelopes = try c.decode([Envelope].self, forKey: .envelopes)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        tableKeys = try c.decode([String: TableKeyRecord].self, forKey: .tableKeys)
        epochPublished = try c.decode(Bool.self, forKey: .epochPublished)
        publishedCustodianHashes = try c.decodeIfPresent([String].self, forKey: .publishedCustodianHashes) ?? []
        publishedThreshold = try c.decodeIfPresent(Int.self, forKey: .publishedThreshold) ?? 0
        publishedCustodianDevices = try c.decodeIfPresent([String: [String]].self, forKey: .publishedCustodianDevices) ?? [:]
        publishedTableIDs = try c.decodeIfPresent([String].self, forKey: .publishedTableIDs) ?? []
        publishedPolicy = try c.decodeIfPresent(ReleasePolicy.self, forKey: .publishedPolicy)
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

    /// `ownerHash` here is the engine's `storeHash`, not always the
    /// identity hash: the urgent set files under a prefixed key.
    static func save(_ estate: Estate, ownerHash: String) {
        if let data = try? JSONEncoder().encode(estate) {
            KeychainStore.save(data, for: key(ownerHash))
        }
    }

    static func wipe(ownerHash: String) {
        KeychainStore.delete(key(ownerHash))
        EstateLogStore.wipe(ownerHash: ownerHash)
        CustodianVault.wipe(ownerHash: ownerHash)
    }
}
