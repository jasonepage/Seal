import Foundation
import CryptoKit
import os

//  Introduction.swift
//  Seal
//
//  A MUTUAL FRIEND VOUCHES — REMOTELY. BRASS STILL MEANS MET.
//
//  WHAT THIS IS
//  ------------
//  Friendship in Seal requires an in-person ceremony: the friend taps THEIR
//  root credential on YOUR phone, and your phone verifies that signature
//  against the public directory. That is the product, and nothing here
//  weakens it. Families are scattered, though, and a grandmother two states
//  away is never going to tap a key on her grandson's phone.
//
//  An INTRODUCTION is a third statement, signed by a mutual friend's device
//  key, that binds two identities together and says "I have met both of
//  these people in person, and I vouch for this connection." Both of them
//  accept it, and their phones create a friendship at a NEW, VISIBLY
//  DIFFERENT tier — "linked" internally, silver with a link glyph on screen.
//
//  THE THREE RULES THAT CANNOT BEND
//  --------------------------------
//  1. BRASS MEANS PHYSICALLY MET. A linked friendship is never rendered as
//     brass, never labelled "Verified", and `Friendship.isInPerson` is false
//     for it everywhere. ForgeRank (docs/TRUST.md §5.1) already reserves a
//     fractional weight for exactly this kind of edge.
//  2. INTRODUCTION DOES NOT CHAIN. An introducer must hold IN-PERSON
//     friendships with BOTH parties. This is not enforced by hiding a button:
//     each recipient independently requires that ITS OWN edge with the
//     introducer is in-person before it will accept (`introducerEligibility`).
//     A's device checks A—introducer; B's device checks B—introducer; between
//     the two of them BOTH halves of the rule are checked by the only devices
//     that can actually know. A linked friend who patches their own client to
//     send an introduction gets refused by both recipients.
//  3. BOTH PARTIES MUST ACCEPT, and a decline is SILENT. The introducer is
//     never told "declined", only "not accepted yet" — no family drama by
//     protocol, and it costs nothing because there is no second thing the
//     introducer could do with the information.
//
//  WHAT A LINKED EDGE ACTUALLY PROVES
//  ----------------------------------
//  That a specific hardware-rooted identity, which THIS phone has met in
//  person, signed a statement naming both parties and their published
//  identity keys. It proves the introducer's judgment, and nothing more. A
//  malicious introducer can introduce an impostor they control — the tier and
//  the provenance line are the mitigation, not a claim that it can't happen.
//  See docs/INTRODUCTIONS.md §Threats.
//
//  NO NEW RECORD TYPE. All three statements ride the existing E2EE message
//  pipeline as payload kinds, exactly the way `kind:"reaction"` and
//  `kind:"card"` do (SDS §5, docs/CARDS.md). That is not only convenient: the
//  GroupInvite / ForgeHandshake records live in the WORLD-READABLE public
//  database, and an introduction names two people and the fact that a third
//  vouched for them — precisely the who-met-whom data docs/TRUST.md D3 says
//  stays private. The chat pipeline encrypts it; a public record would not.

// MARK: - Namespace, domains, and the framed commitments

enum Introduction {
    /// Messaging-layer diagnostics, same subsystem as `messaging`/`forge`.
    /// Logs hashes and outcomes only — never key material.
    static let log = Logger(subsystem: "io.github.jasonepage.Seal", category: "introduce")

    /// The three payload kinds (`ChatEngine.MessagePayload.kind`).
    ///
    /// `offerKind` is a BUBBLE kind — it renders a card and fires a push,
    /// like `kind:"card"`. The other two mutate state and render nothing, like
    /// `kind:"reaction"`.
    static let offerKind = "introduce"
    static let acceptKind = "introduce.accept"
    static let confirmKind = "introduce.confirm"

    /// An offer older than this is refused instead of acted on. Generous on
    /// purpose: the flow is resumable and an introducer can be offline for
    /// weeks, so this is replay hygiene, not a deadline. The introducer's card
    /// keeps a "Send again" action, which re-ships the SAME signed statement.
    static let validity: TimeInterval = 30 * 24 * 60 * 60
    /// Tolerance for an introducer's fast clock. A statement dated further
    /// ahead than this is refused — a future timestamp is the one thing that
    /// could park an offer in the acceptable window indefinitely.
    static let futureSkew: TimeInterval = 24 * 60 * 60

    /// Append one LENGTH-FRAMED field: UInt32 big-endian byte count, then the
    /// bytes.
    ///
    /// Framing is not decoration. `seal.endorse.v2` concatenated two
    /// variable-length values without it, so `(D, K)` and `(D‖K[0..<n],
    /// K[n...])` hashed identically — one signature authorising many splits
    /// (see IdentityManager.endorsementCommitment for what that cost). This
    /// commitment carries SIX variable-length values including two 64-character
    /// hashes and two raw public keys; unframed, "introducer X vouches for
    /// A and B" and "introducer X' vouches for A' and B'" could be made to
    /// collide by moving the boundary between adjacent fields, and one
    /// introducer signature would speak for a pairing nobody agreed to.
    /// `CustodyReceipt.commitment` is the model this follows.
    static func field(_ data: Data, into input: inout Data) {
        var length = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
        input.append(data)
    }

    /// `seal.introduce.v1` — what the introducer's DEVICE key signs.
    ///
    ///     SHA256( "seal.introduce.v1"
    ///             ‖ u32(len) ‖ introducerRootHash
    ///             ‖ u32(len) ‖ partyARootHash
    ///             ‖ u32(len) ‖ partyAPublicKey
    ///             ‖ u32(len) ‖ partyBRootHash
    ///             ‖ u32(len) ‖ partyBPublicKey
    ///             ‖ u32(len) ‖ decimal(createdAtEpoch) )
    ///
    /// The domain string is INSIDE the hash and unframed, exactly like
    /// `seal.receipt.v1` and `seal.endorse.v3` — it is a fixed-length constant,
    /// and it is what stops a signature produced here from being replayed as a
    /// receipt, an endorsement or a friend ceremony (the `signReceipt` lesson:
    /// a root-key signing oracle over un-prefixed bytes is a takeover).
    ///
    /// Parties are stored in CANONICAL ORDER (lexicographic by root hash) so
    /// both recipients, and the introducer, derive byte-identical commitments
    /// without any of them having to agree on who is "first". The commitment
    /// hash is therefore a stable id for the whole three-party flow, which is
    /// what makes every step of it idempotent and resumable.
    ///
    /// The timestamp is whole seconds rendered as DECIMAL TEXT, for the reason
    /// `CustodyReceipt.signedAtEpoch` spells out: a `Date` round-trips through
    /// JSON as a Double, and this value is rebuilt into a signed commitment on
    /// the verifier's machine, where an integer must survive exactly and must
    /// not be able to carry a hostile magnitude into a trapping conversion.
    static func commitment(introducerHash: String,
                           partyAHash: String, partyAPublicKey: Data,
                           partyBHash: String, partyBPublicKey: Data,
                           createdAtEpoch: Int64) -> Data {
        var input = Data("seal.introduce.v1".utf8)
        field(Data(introducerHash.utf8), into: &input)
        field(Data(partyAHash.utf8), into: &input)
        field(partyAPublicKey, into: &input)
        field(Data(partyBHash.utf8), into: &input)
        field(partyBPublicKey, into: &input)
        field(Data(String(createdAtEpoch).utf8), into: &input)
        return Data(SHA256.hash(data: input))
    }

    /// `seal.introduce.accept.v1` — what an accepting party's DEVICE key signs.
    ///
    ///     SHA256( "seal.introduce.accept.v1"
    ///             ‖ u32(len) ‖ introductionCommitment
    ///             ‖ u32(len) ‖ accepterRootHash
    ///             ‖ u32(len) ‖ decimal(acceptedAtEpoch) )
    ///
    /// Naming the introduction commitment is what stops an acceptance being
    /// lifted into a DIFFERENT introduction, and naming the accepter is what
    /// stops it being presented as somebody else's. Its own domain string
    /// keeps it distinguishable from the offer it answers.
    static func acceptanceCommitment(introduction: Data,
                                     accepterHash: String,
                                     acceptedAtEpoch: Int64) -> Data {
        var input = Data("seal.introduce.accept.v1".utf8)
        field(introduction, into: &input)
        field(Data(accepterHash.utf8), into: &input)
        field(Data(String(acceptedAtEpoch).utf8), into: &input)
        return Data(SHA256.hash(data: input))
    }

    /// Canonical (A, B) ordering for a pair of parties.
    static func canonical(_ x: (hash: String, publicKey: Data),
                          _ y: (hash: String, publicKey: Data))
        -> (a: (hash: String, publicKey: Data), b: (hash: String, publicKey: Data)) {
        x.hash <= y.hash ? (a: x, b: y) : (a: y, b: x)
    }
}

// MARK: - The statement

/// One introducer's signed vouch for one pair. Self-contained: everything a
/// recipient needs to re-derive the commitment and re-check the signature
/// years later, given only the public directory.
///
/// Display names are deliberately ABSENT. Names are metadata everywhere in
/// Seal — not in any commitment, not in any credential hash (see
/// `IdentityManager.updateDisplayName`) — so carrying them here would create
/// a second, unsigned source of truth for who this is about. Every surface
/// resolves names from the directory or the FriendStore instead.
struct IntroductionStatement: Codable, Hashable {
    let introducerHash: String
    /// The Secure Enclave key that signed, x963. Must chain back to
    /// `introducerHash`'s root through a published, unrevoked endorsement —
    /// the same check every inbound message passes (SDS §2).
    let introducerDevicePublicKey: Data

    /// Canonical order: `partyAHash <= partyBHash`.
    let partyAHash: String
    /// Party A's ROOT public key as the directory publishes it (P-256 raw).
    let partyAPublicKey: Data
    let partyBHash: String
    let partyBPublicKey: Data

    let createdAtEpoch: Int64
    /// DER ECDSA over `commitment`, by `introducerDevicePublicKey`.
    let signature: Data

    var createdAt: Date { Date(timeIntervalSince1970: TimeInterval(createdAtEpoch)) }

    var commitment: Data {
        Introduction.commitment(introducerHash: introducerHash,
                                partyAHash: partyAHash, partyAPublicKey: partyAPublicKey,
                                partyBHash: partyBHash, partyBPublicKey: partyBPublicKey,
                                createdAtEpoch: createdAtEpoch)
    }

    /// Stable id for the whole flow — every store key, every idempotency
    /// check and every log line uses this.
    var commitmentHex: String { commitment.hexString }

    /// First 8 hex, for logs. A `String`, not a `Substring`: os.Logger's
    /// privacy-qualified interpolation only accepts the former.
    var shortID: String { String(commitmentHex.prefix(8)) }

    func involves(_ hash: String) -> Bool { hash == partyAHash || hash == partyBHash }

    /// The party who is NOT `hash`. nil if `hash` isn't one of the two.
    func counterpartHash(for hash: String) -> String? {
        if hash == partyAHash { return partyBHash }
        if hash == partyBHash { return partyAHash }
        return nil
    }

    /// The published root key this statement claims for `hash`.
    func publicKey(for hash: String) -> Data? {
        if hash == partyAHash { return partyAPublicKey }
        if hash == partyBHash { return partyBPublicKey }
        return nil
    }
}

// MARK: - The acceptance

/// A party's device-key signature saying "yes, link me to the other person
/// named in this introduction." Verifiable by anyone with the directory.
struct IntroductionAcceptance: Codable, Hashable {
    /// The introduction commitment this answers.
    let introductionCommitment: Data
    let accepterHash: String
    let accepterDevicePublicKey: Data
    let acceptedAtEpoch: Int64
    let signature: Data

    var acceptedAt: Date { Date(timeIntervalSince1970: TimeInterval(acceptedAtEpoch)) }

    var commitment: Data {
        Introduction.acceptanceCommitment(introduction: introductionCommitment,
                                          accepterHash: accepterHash,
                                          acceptedAtEpoch: acceptedAtEpoch)
    }
}

/// What the introducer ships to each party once BOTH have accepted: the
/// original statement plus both acceptances.
///
/// It carries no signature of its own, and does not need one. Every claim
/// inside is already signed by the party it speaks for, and the recipient
/// re-verifies all three against the directory before anything happens — so a
/// tampered or replayed confirmation is either identical to the real one or
/// fails a signature check. It is also deliberately SELF-CONTAINED: a phone
/// that lost its local state (reinstall, sign-out) can complete the
/// friendship from a confirmation alone, because its OWN acceptance inside it
/// verifies against its own published device keys and cannot be forged.
struct IntroductionConfirmation: Codable, Hashable {
    let statement: IntroductionStatement
    /// Exactly two, one per party. Order is not significant — everything is
    /// looked up by `accepterHash`.
    let acceptances: [IntroductionAcceptance]

    func acceptance(by hash: String) -> IntroductionAcceptance? {
        acceptances.first { $0.accepterHash == hash }
    }
}

/// The provenance stored ON a linked friendship. Non-nil is what MAKES a
/// friendship linked (`Friendship.isInPerson`), so the tier and the evidence
/// for it can never drift apart into two fields that disagree.
struct IntroductionProof: Codable, Hashable {
    let statement: IntroductionStatement
    let acceptances: [IntroductionAcceptance]

    var introducerHash: String { statement.introducerHash }
    var introducedAt: Date { statement.createdAt }
}

// MARK: - An offer as it sits in a chat

/// A received (or sent) introduction, plus the verdict of the checks the
/// engine ran on it. Rides inside `ChatEngine.ChatMessage`, so the card can be
/// rendered as a pure function of stored state with no async work in `body`.
///
/// The verdict is TWO OPTIONAL STRINGS rather than an enum with associated
/// values, deliberately. `ChatMessage` is persisted as one keychain blob
/// (`seal.messages.<hash>`), and a single value that fails to decode takes
/// every chat's history with it — the invariant `MessageProof` states in
/// capitals. An enum gains cases; a case an older build has never heard of
/// throws on decode. Two optionals can only ever decode to "no reason given",
/// which is the safe direction.
struct IntroductionOffer: Codable, Hashable {
    let statement: IntroductionStatement

    /// Non-nil ⇒ a check FAILED. Plain language, shown on the card, no
    /// actions offered. This is a dead end, not a retry.
    var refusal: String?

    /// Non-nil ⇒ a check could not be RUN (the directory was unreachable).
    /// Shown as "checking", retried by `ensureIntroductionsProgressed`.
    ///
    /// Kept strictly apart from `refusal` for the reason `CardVerification`
    /// gives: "this is forged" and "I couldn't reach the directory" have
    /// opposite consequences, and one grey state covering both would be a lie
    /// in whichever direction it resolved.
    var unchecked: String?

    /// The counterpart AS THE DIRECTORY PUBLISHES THEM, resolved when the
    /// offer verified: name, tier, credential ID. Set only on a PARTY's
    /// device — an introducer has two counterparts and reads both out of
    /// their own FriendStore.
    ///
    /// Persisted without `backupCredentials` for the same reason
    /// `IdentityManager.completeRegistration` strips them: a stored copy of an
    /// identity is never re-filtered against revocations, and an authority set
    /// frozen into a message blob would name a revoked backup forever.
    var counterpart: RootIdentity?

    /// Every check passed and this offer can be acted on.
    var isActionable: Bool { refusal == nil && unchecked == nil }

    static func verified(_ statement: IntroductionStatement, counterpart: RootIdentity?) -> IntroductionOffer {
        var stripped = counterpart
        stripped?.backupCredentials = nil
        return IntroductionOffer(statement: statement, refusal: nil, unchecked: nil, counterpart: stripped)
    }

    static func refused(_ statement: IntroductionStatement, _ reason: String) -> IntroductionOffer {
        IntroductionOffer(statement: statement, refusal: reason, unchecked: nil, counterpart: nil)
    }

    static func pending(_ statement: IntroductionStatement, _ reason: String) -> IntroductionOffer {
        IntroductionOffer(statement: statement, refusal: nil, unchecked: reason, counterpart: nil)
    }
}

// MARK: - Verification (pure — the caller supplies the directory)

extension Introduction {

    /// Check an inbound offer. Everything cryptographic happens here; the
    /// caller's only job is to hand over directory entries and its own
    /// identity. Pure and synchronous so it can be reasoned about (and, one
    /// day, tested) without a network.
    ///
    /// `introducer` and `counterpart` are `SyncEngine.fetchIdentity` results —
    /// nil means "the fetch didn't produce one", which is treated as NOT
    /// CHECKED rather than as a refusal.
    ///
    /// The four checks the design calls for, in order of cheapness:
    ///   (c) our own root hash AND public key appear in the commitment exactly
    ///       — the replay-to-a-different-party defence;
    ///   (a) the introducer's device key → endorsement → root chain, the same
    ///       verification inbound messages get;
    ///   (d) the counterpart's key in the statement matches what the directory
    ///       publishes for that root hash — refuse on mismatch, never guess.
    /// Check (b), "the introducer is an in-person friend of MINE", needs the
    /// FriendStore and lives in `introducerEligibility` below.
    static func checkOffer(_ statement: IntroductionStatement,
                           senderHash: String,
                           isOneToOneChat: Bool,
                           myHash: String,
                           myPublicKey: Data,
                           introducer: (RootIdentity, [DeviceEndorsement])?,
                           counterpart: (RootIdentity, [DeviceEndorsement])?,
                           now: Date,
                           identity: IdentityManager) -> IntroductionOffer {

        // The person who SENT this must be the person it claims to be from.
        // Without this, anyone could relay somebody else's introduction into a
        // chat and have it render as though the sender had made it.
        guard statement.introducerHash == senderHash else {
            return .refused(statement, "This introduction says it came from someone other than the person who sent it. Seal won't act on it.")
        }
        // One-to-one only. An introduction carries both parties' identity keys,
        // and docs/TRUST.md D3 keeps who-knows-whom private: broadcasting one
        // into a group would hand every member an edge that isn't theirs.
        guard isOneToOneChat else {
            return .refused(statement, "An introduction can only be sent in a one-to-one chat.")
        }
        guard statement.partyAHash != statement.partyBHash else {
            return .refused(statement, "This introduction names the same person twice.")
        }
        guard statement.introducerHash != statement.partyAHash,
              statement.introducerHash != statement.partyBHash else {
            return .refused(statement, "An introduction can't name its own sender as one of the two people.")
        }
        guard statement.involves(myHash) else {
            return .refused(statement, "This introduction is addressed to someone else.")
        }
        // (c) OUR OWN slot must match this phone's identity exactly — hash AND
        // key. This is what stops an introduction made for one person being
        // replayed at another: the commitment is over our key, so a statement
        // built for somebody else can never name us without a fresh signature.
        guard statement.publicKey(for: myHash) == myPublicKey else {
            return .refused(statement, "This introduction doesn't match this phone's identity key. It was made for a different Seal account.")
        }
        guard let counterpartHash = statement.counterpartHash(for: myHash) else {
            return .refused(statement, "This introduction is addressed to someone else.")
        }

        let age = now.timeIntervalSince(statement.createdAt)
        guard age <= validity else {
            return .refused(statement, "This introduction is more than 30 days old. Ask them to send it again.")
        }
        guard age >= -futureSkew else {
            return .refused(statement, "This introduction is dated in the future, so Seal can't accept it. Check the date and time on their phone.")
        }

        // Directory unreachable is NOT a refusal — it is an unfinished check.
        guard let (introducerRoot, introducerEndorsements) = introducer else {
            return .pending(statement, "Checking this introduction — Seal couldn't reach the directory yet.")
        }
        guard let (counterpartRoot, _) = counterpart else {
            return .pending(statement, "Checking this introduction — Seal couldn't look up the other person yet.")
        }

        // (a) The signature chain: device key → published endorsement → root.
        // Exactly the check every inbound message passes, against the same
        // directory-supplied endorsement set.
        //
        // The record we were handed must be the one the statement NAMES. The
        // only caller today fetches it by that hash, so this is belt and
        // braces — but this function advertises itself as pure and
        // caller-supplied, and the counterpart's hash is pinned five lines
        // down, so the asymmetry would be the hole a second caller falls into.
        guard introducerRoot.credentialIDHash == statement.introducerHash else {
            return .refused(statement, "This introduction doesn't match the identity it claims to come from.")
        }
        guard identity.verify(signature: statement.signature,
                              over: statement.commitment,
                              deviceKey: statement.introducerDevicePublicKey,
                              claimedRoot: introducerRoot,
                              endorsements: introducerEndorsements) else {
            return .refused(statement, "This introduction wasn't signed by \(introducerRoot.displayName)'s phone, so Seal can't trust it.")
        }

        // (d) The counterpart's key must be the one the directory publishes.
        // A mismatch is exactly the shape of an introducer trying to hand you
        // an identity they control under a name you recognise — so it fails
        // closed and says so, rather than picking whichever key looks better.
        guard counterpartRoot.credentialIDHash == counterpartHash,
              counterpartRoot.publicKey == statement.publicKey(for: counterpartHash) else {
            return .refused(statement, "The identity key in this introduction doesn't match what \(counterpartRoot.displayName) publishes in the directory. Seal won't guess which one is right — ask \(introducerRoot.displayName) to make the introduction again.")
        }

        return .verified(statement, counterpart: counterpartRoot)
    }

    /// Check (b): may THIS phone accept an introduction from this introducer?
    ///
    /// Returns nil when it may, or the plain-language reason it may not. This
    /// is where "introduction does not chain" is actually enforced — on the
    /// RECIPIENT, not in the introducer's UI. A linked friend who patches
    /// their client to send introductions is refused here, by both recipients,
    /// independently.
    ///
    /// Called at render time AND again inside `ChatEngine.acceptIntroduction`.
    /// The second call is the one that counts: a check that only a view
    /// performs is a check an attacker skips.
    static func introducerEligibility(_ statement: IntroductionStatement,
                                      friendStore: FriendStore) -> String? {
        guard let friend = friendStore.friends.first(where: { $0.id == statement.introducerHash }) else {
            return "You haven't met this person through Seal on this phone, so Seal can't accept an introduction from them."
        }
        guard friend.friendship.isInPerson else {
            return "\(friend.identity.displayName) is a linked friend — someone vouched for them, you haven't met them in person through Seal. Introductions can only come from someone you've met in person, so this one can't be accepted."
        }
        return nil
    }

    /// Verify one acceptance against the accepter's published identity.
    /// Same chain as everything else: device key → endorsement → root.
    static func verifyAcceptance(_ acceptance: IntroductionAcceptance,
                                 for statement: IntroductionStatement,
                                 accepter: (RootIdentity, [DeviceEndorsement])?,
                                 identity: IdentityManager) -> Bool {
        guard acceptance.introductionCommitment == statement.commitment,
              statement.involves(acceptance.accepterHash),
              let (root, endorsements) = accepter,
              root.credentialIDHash == acceptance.accepterHash else { return false }
        return identity.verify(signature: acceptance.signature,
                               over: acceptance.commitment,
                               deviceKey: acceptance.accepterDevicePublicKey,
                               claimedRoot: root,
                               endorsements: endorsements)
    }
}

// MARK: - Local state

/// Every introduction this identity is part of, in any role, keyed by the
/// commitment hash. Keychain-JSON namespaced per identity — the FriendStore /
/// ReceiptStore pattern.
///
/// This is the piece that makes the three-party flow RESUMABLE. Messages are
/// consumed once (the sender chain ratchets forward and the key is destroyed),
/// so "what do I still owe this flow?" cannot be re-derived from the
/// transcript. It is derived from here instead, on every refresh, and every
/// transition is idempotent: the same acceptance recorded twice is one entry,
/// the same confirmation delivered twice creates one friendship.
@Observable
final class IntroductionStore {

    struct Entry: Codable, Hashable, Identifiable {
        var id: String { commitmentHex }
        let commitmentHex: String
        let statement: IntroductionStatement
        /// accepterHash → their signed acceptance. Includes our own once we
        /// have accepted, so "who is still silent" is one lookup.
        var acceptances: [String: IntroductionAcceptance]
        /// This phone said "Not now". Nothing is ever sent for this — the
        /// introducer sees "not accepted yet" forever, by design (rule 3).
        var declinedAt: Date?
        /// Introducer only: both confirmations have been shipped.
        var confirmationsSentAt: Date?
        /// This introduction can no longer be carried to the end — one of the
        /// two people is no longer a friend of this phone. Latched so a dead
        /// flow stops re-sending to whoever is left on every launch. It is
        /// deliberately NOT `confirmationsSentAt`: a field that says "sent"
        /// when nothing was sent is the kind of lie that gets believed later.
        var abandonedAt: Date?
        /// Party only: the linked friendship exists locally.
        var completedAt: Date?

        var shortID: String { statement.shortID }
        func isIntroducer(_ myHash: String) -> Bool { statement.introducerHash == myHash }
        func myAcceptance(_ myHash: String) -> IntroductionAcceptance? { acceptances[myHash] }
        var bothAccepted: Bool {
            acceptances[statement.partyAHash] != nil && acceptances[statement.partyBHash] != nil
        }
    }

    private(set) var entries: [Entry] = []
    let ownerHash: String
    private var storageKey: String { Self.key(ownerHash) }

    static func key(_ ownerHash: String) -> String { "seal.introductions.\(ownerHash)" }

    init(ownerHash: String) {
        self.ownerHash = ownerHash
        load()
    }

    static func wipe(ownerHash: String) { KeychainStore.delete(key(ownerHash)) }

    func entry(_ commitmentHex: String) -> Entry? {
        entries.first { $0.commitmentHex == commitmentHex }
    }

    func entry(for statement: IntroductionStatement) -> Entry? {
        entry(statement.commitmentHex)
    }

    /// Insert if new; never clobber. The statement is content-addressed by its
    /// own commitment, so an existing entry with this id is BY DEFINITION
    /// about the same statement — re-delivery must not reset acceptances or
    /// un-decline anything.
    @discardableResult
    func record(_ statement: IntroductionStatement) -> Entry {
        if let existing = entry(for: statement) { return existing }
        let fresh = Entry(commitmentHex: statement.commitmentHex,
                          statement: statement,
                          acceptances: [:],
                          declinedAt: nil,
                          confirmationsSentAt: nil,
                          abandonedAt: nil,
                          completedAt: nil)
        entries.append(fresh)
        save()
        return fresh
    }

    func recordAcceptance(_ acceptance: IntroductionAcceptance, for statement: IntroductionStatement) {
        record(statement)
        guard let index = entries.firstIndex(where: { $0.commitmentHex == statement.commitmentHex }),
              entries[index].acceptances[acceptance.accepterHash] != acceptance else { return }
        entries[index].acceptances[acceptance.accepterHash] = acceptance
        save()
    }

    func markDeclined(_ statement: IntroductionStatement) {
        record(statement)
        guard let index = entries.firstIndex(where: { $0.commitmentHex == statement.commitmentHex }),
              entries[index].declinedAt == nil else { return }
        entries[index].declinedAt = .now
        save()
    }

    func markAbandoned(_ commitmentHex: String) {
        guard let index = entries.firstIndex(where: { $0.commitmentHex == commitmentHex }),
              entries[index].abandonedAt == nil else { return }
        entries[index].abandonedAt = .now
        save()
    }

    func markConfirmationsSent(_ commitmentHex: String) {
        guard let index = entries.firstIndex(where: { $0.commitmentHex == commitmentHex }),
              entries[index].confirmationsSentAt == nil else { return }
        entries[index].confirmationsSentAt = .now
        save()
    }

    func markCompleted(_ commitmentHex: String) {
        guard let index = entries.firstIndex(where: { $0.commitmentHex == commitmentHex }),
              entries[index].completedAt == nil else { return }
        entries[index].completedAt = .now
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            KeychainStore.save(data, for: storageKey)
        }
    }

    private func load() {
        if let data = KeychainStore.load(storageKey),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = decoded
        }
    }
}
