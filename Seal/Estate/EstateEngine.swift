// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import CryptoKit
import os

//  EstateEngine.swift
//  Seal
//
//  THE ORCHESTRATION LAYER. Everything with a side effect lives here:
//  keychain, CloudKit, timestamps, the key ceremony. The pure pieces it
//  drives are EstateKeys, EstateLog, ReleaseFeed and ReleaseMachine, and
//  every decision about state is delegated to them.
//
//  One engine per signed-in identity. The same person can be an OWNER (their
//  own estate), a CUSTODIAN (of other people's estates) and a RECIPIENT, so
//  the engine carries all three sides.
//
//  Clock: injected. Nothing here reads Date().

@Observable
final class EstateEngine {

    let ownerHash: String
    let identity: IdentityManager
    let sync: SyncEngine
    let clock: Clock

    /// My own estate, if I have started one.
    private(set) var estate: Estate?
    /// My own estate's admitted events and derived state.
    private(set) var ownerEvents: [EstateEvent] = []
    private(set) var ownerSnapshot: ReleaseSnapshot?
    /// Estates I guard or receive from.
    private(set) var guarded: [GuardedEstate] = []
    private(set) var guardedEvents: [String: [EstateEvent]] = [:]
    private(set) var guardedSnapshots: [String: ReleaseSnapshot] = [:]
    private(set) var isWorking = false
    private(set) var lastError: String?
    /// Custodians whose endorsed phones no longer match the ones their share
    /// was wrapped to at the last seal. Found by `refreshOwner`, shown on the
    /// home screen, and cleared by the next epoch. Empty for an estate
    /// sealed before `publishedCustodianDevices` existed, because there is
    /// nothing to compare against until it seals once more.
    private(set) var custodiansWithNewPhones: [Custodian] = []

    private var directoryCache: [String: (RootIdentity, [DeviceEndorsement])] = [:]

    static let log = Logger(subsystem: "io.github.jasonepage.Seal", category: "estate")

    /// Posted after any refresh so screens re-read state.
    static let changed = Notification.Name("seal.estate.changed")

    init(ownerHash: String, identity: IdentityManager, sync: SyncEngine, clock: Clock = Clocks.current) {
        self.ownerHash = ownerHash
        self.identity = identity
        self.sync = sync
        self.clock = clock
        estate = EstateStore.load(ownerHash: ownerHash)
        guarded = CustodianVault.load(ownerHash: ownerHash)
        let logs = EstateLogStore.load(ownerHash: ownerHash)
        if let estate { ownerEvents = logs[estate.id] ?? [] }
        for g in guarded { guardedEvents[g.estateID] = logs[g.estateID] ?? [] }
        recomputeAll()
    }

    enum EngineError: LocalizedError {
        case noDeviceKey
        case noEstate
        case notReady(String)
        /// who it is about, and why the directory said no.
        case directory(who: String, why: String)
        case notAllowed(String)
        case noShare
        case notReleased

        var errorDescription: String? {
            switch self {
            case .noDeviceKey: "This phone has no device key. Sign in again."
            case .noEstate: "You have not started your envelopes yet."
            case .notReady(let why): why
            // Names the PERSON and the actual reason. It used to print eight
            // hex characters of a hash and then blame the connection, which
            // was the one cause it could not be: a network failure throws out
            // of CloudKit and never reaches here.
            case .directory(let who, let why): "This is about \(who).\n\nSeal stopped because \(why)"
            case .notAllowed(let why): why
            case .noShare: "This phone does not hold your key share for this estate yet."
            case .notReleased: "The envelopes have not been released."
            }
        }
    }

    // MARK: - Persistence

    private func saveLogs() {
        var logs: [String: [EstateEvent]] = [:]
        if let estate { logs[estate.id] = ownerEvents }
        for (id, events) in guardedEvents { logs[id] = events }
        EstateLogStore.save(logs, ownerHash: ownerHash)
    }

    private func saveEstate() {
        if let estate { EstateStore.save(estate) }
    }

    private func saveGuarded() {
        CustodianVault.save(guarded, ownerHash: ownerHash)
    }

    private func recomputeAll() {
        if let estate {
            ownerSnapshot = ReleaseFeed.snapshot(events: ownerEvents, ownerHash: ownerHash,
                                                 fallbackPolicy: estate.policy, estateCreatedAt: estate.createdAt)
        }
        for g in guarded {
            // No events yet means nothing to reason about: leave the snapshot
            // absent so the screens say "waiting" rather than "overdue".
            guard let events = guardedEvents[g.estateID], !events.isEmpty else {
                guardedSnapshots[g.estateID] = nil
                continue
            }
            let policy = g.epoch.map { ReleasePolicy(threshold: $0.threshold) } ?? ReleasePolicy(threshold: 1)
            guardedSnapshots[g.estateID] = ReleaseFeed.snapshot(events: events,
                                                                ownerHash: g.ownerHash,
                                                                fallbackPolicy: policy,
                                                                estateCreatedAt: .distantPast)
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    // MARK: - State queries

    var now: Date { clock.now }

    var ownerState: ReleaseState? {
        ownerSnapshot.map { ReleaseMachine.state($0, now: clock.now) }
    }

    func state(of estateID: String) -> ReleaseState? {
        guardedSnapshots[estateID].map { ReleaseMachine.state($0, now: clock.now) }
    }

    func timeline(of estateID: String) -> ReleaseTimeline? {
        guardedSnapshots[estateID].flatMap { ReleaseMachine.timeline($0, now: clock.now) }
    }

    // MARK: - Directory

    /// Pinned lookups, cached for the session. Throws on a pin mismatch
    /// (KeyPinStore) and on "not found", because for an estate an absent
    /// custodian is an error, not an empty list.
    /// `named` is who this hash belongs to, in the owner's words, so a
    /// failure can say "Karen" instead of eight hex characters. The owner
    /// knows their key holders by name and has never seen a hash.
    private func lookup(_ hash: String, named: String? = nil,
                        forceRefresh: Bool = false) async throws -> (RootIdentity, [DeviceEndorsement]) {
        if !forceRefresh, let cached = directoryCache[hash] { return cached }
        guard let fetched = try await sync.fetchIdentity(credentialIDHash: hash) else {
            let why = await sync.identityAbsence(credentialIDHash: hash)
            throw EngineError.directory(who: who(hash, named: named), why: why)
        }
        directoryCache[hash] = fetched
        return fetched
    }

    /// The best name this engine has for a hash: the one the caller passed,
    /// then the estate's own lists, then the hash as a last resort.
    private func who(_ hash: String, named: String? = nil) -> String {
        if let named, !named.isEmpty { return named }
        if hash == ownerHash { return "your own identity on this phone" }
        if let name = estate?.custodians.first(where: { $0.rootHash == hash })?.displayName, !name.isEmpty {
            return name
        }
        if let name = estate?.recipients.first(where: { $0.rootHash == hash })?.displayName, !name.isEmpty {
            return name
        }
        if let name = guarded.first(where: { $0.ownerHash == hash })?.ownerName, !name.isEmpty {
            return name
        }
        return "the person whose seal starts \(String(hash.prefix(8)))"
    }

    /// Every endorsed, unrevoked device's KEM bundle for an identity.
    private func kemBundles(of hash: String, named: String? = nil) async throws -> [Data] {
        let (root, endorsements) = try await lookup(hash, named: named)
        let bundles = IdentityManager.verifiedDevices(root: root, endorsements: endorsements).map(\.kemBundlePublicKeys)
        // A record exists but lists no usable device. Distinct from "not
        // found", and the fix is different: they open Seal once.
        guard !bundles.isEmpty else {
            throw EngineError.directory(
                who: who(hash, named: named ?? root.displayName),
                why: "that identity has no device Seal can encrypt to. They open Seal once on their phone and sign in, and it repairs itself. A phone that has not signed in since the last update has no key published.")
        }
        return bundles
    }

    // MARK: - Events

    private func sign(_ kind: EstateEvent.Kind, estateID: String, payload: Data = Data(), previous: Data) throws -> EstateEvent {
        guard let deviceKey = identity.deviceKey else { throw EngineError.noDeviceKey }
        return try EstateEventBuilder.make(kind: kind, estateID: estateID, actorHash: ownerHash,
                                           deviceKey: deviceKey, previousDigest: previous,
                                           payload: payload, now: clock.now)
    }

    /// Publish, store locally, then stamp in the background. The kinds that
    /// carry weight in the release machine get a token; the rest do not need
    /// one and a token costs a network round trip and a stored blob.
    private func publish(_ event: EstateEvent, into estateID: String, mine: Bool) async throws {
        try await sync.publishEstateEvent(event)
        if mine {
            ownerEvents = EstateLogStore.merged(ownerEvents, [event])
        } else {
            guardedEvents[estateID] = EstateLogStore.merged(guardedEvents[estateID] ?? [], [event])
        }
        saveLogs()
        recomputeAll()
        let stampable: Set<EstateEvent.Kind> = [.heartbeat, .cancellation, .releaseClaimed, .authorization, .released, .epochPublished]
        if stampable.contains(event.kind), !DemoFixtures.isActive {
            Task { await self.stamp(event, estateID: estateID, mine: mine) }
        }
    }

    private func stamp(_ event: EstateEvent, estateID: String, mine: Bool) async {
        guard let token = await TimestampService.stamp(digest: event.digest) else { return }
        var stamped = event
        stamped.timestampToken = token
        try? await sync.attachEstateTimestamp(estateID: estateID, eventID: event.id, token: token)
        if mine {
            ownerEvents = EstateLogStore.merged(ownerEvents, [stamped])
        } else {
            guardedEvents[estateID] = EstateLogStore.merged(guardedEvents[estateID] ?? [], [stamped])
        }
        saveLogs()
        recomputeAll()
    }

    // MARK: - Owner: building the estate

    @discardableResult
    func createEstateIfNeeded() -> Estate {
        if let estate { return estate }
        let fresh = Estate.new(ownerHash: ownerHash, now: clock.now)
        estate = fresh
        saveEstate()
        recomputeAll()
        return fresh
    }

    func addCustodian(_ friend: RootIdentity, receiptID: String? = nil) {
        var e = createEstateIfNeeded()
        guard !e.custodians.contains(where: { $0.rootHash == friend.credentialIDHash }) else { return }
        e.custodians.append(Custodian(rootHash: friend.credentialIDHash, displayName: friend.displayName,
                                      addedAt: clock.now, handoverReceiptID: receiptID))
        if e.policy.threshold > e.custodians.count { e.policy.threshold = e.custodians.count }
        // SAFE DEFAULT AT THE MOMENT IT BECOMES A CHOICE. Estate.new starts
        // at a threshold of 1 because with no key holders there is nothing
        // else it could be, and the clamp above only ever lowers it. So an
        // owner who added three people and never opened the rule screen had
        // "any 1 of 3": each of them able to release the whole estate alone,
        // while PRODUCT.md's story, the onboarding and every figure say two
        // of three.
        //
        // One of one is forced and stays. The second key holder is the first
        // moment the threshold is a decision rather than the only option, so
        // that is where the default moves to two. It fires ONLY on that
        // transition, so an owner who then deliberately sets one of two and
        // adds a third keeps their choice.
        if e.custodians.count == 2 && e.policy.threshold == 1 {
            e.policy.threshold = 2
        }
        estate = e; saveEstate(); recomputeAll()
    }

    func setHandoverReceipt(_ receiptID: String, for custodianHash: String) {
        guard var e = estate, let i = e.custodians.firstIndex(where: { $0.rootHash == custodianHash }) else { return }
        e.custodians[i].handoverReceiptID = receiptID
        estate = e; saveEstate()
    }

    func removeCustodian(_ hash: String) {
        guard var e = estate else { return }
        e.custodians.removeAll { $0.rootHash == hash }
        if e.policy.threshold > e.custodians.count { e.policy.threshold = max(1, e.custodians.count) }
        estate = e; saveEstate(); recomputeAll()
    }

    func setPolicy(_ policy: ReleasePolicy) throws {
        var e = createEstateIfNeeded()
        try policy.validate(custodianCount: max(e.custodians.count, 1))
        e.policy = policy
        estate = e; saveEstate(); recomputeAll()
    }

    func addRecipient(_ friend: RootIdentity) {
        var e = createEstateIfNeeded()
        guard !e.recipients.contains(where: { $0.rootHash == friend.credentialIDHash }) else { return }
        e.recipients.append(Recipient(rootHash: friend.credentialIDHash, displayName: friend.displayName))
        estate = e; saveEstate()
    }

    func newEnvelope(for recipientHash: String, title: String) -> Envelope {
        var e = createEstateIfNeeded()
        let order = (e.envelopes(for: recipientHash).map(\.revealOrder).max() ?? 0) + 1
        let env = Envelope.new(recipientHash: recipientHash, title: title, now: clock.now, revealOrder: order)
        e.envelopes.append(env)
        estate = e; saveEstate()
        return env
    }

    /// An envelope for somebody who is not in Seal yet, addressed to a typed
    /// name. See Envelope.draftRecipientName for why this exists.
    func newEnvelope(forName name: String) -> Envelope {
        var e = createEstateIfNeeded()
        let envelope = Envelope.unbound(name: name, title: "For \(name)", now: clock.now)
        e.envelopes.append(envelope)
        estate = e; saveEstate()
        return envelope
    }

    /// The day they meet. The envelope keeps its words, its photos and its
    /// content key, and gains a real recipient, so nothing written is lost
    /// and the next seal picks it up like any other draft.
    func bindEnvelope(_ envelopeID: String, to friend: RootIdentity) {
        addRecipient(friend)
        guard var e = estate, let i = e.envelopes.firstIndex(where: { $0.id == envelopeID }) else { return }
        let hash = friend.credentialIDHash
        // Fall in behind anything already written for this person.
        let order = (e.envelopes(for: hash).map(\.revealOrder).max() ?? 0) + 1
        e.envelopes[i].recipientHash = hash
        e.envelopes[i].draftRecipientName = nil
        e.envelopes[i].revealOrder = order
        e.envelopes[i].updatedAt = clock.now
        e.envelopes[i].sealed = false
        estate = e; saveEstate(); recomputeAll()
    }

    /// Any edit un-seals the envelope so the next seal republishes it.
    func updateEnvelope(_ envelope: Envelope) {
        guard var e = estate, let i = e.envelopes.firstIndex(where: { $0.id == envelope.id }) else { return }
        var updated = envelope
        updated.updatedAt = clock.now
        updated.sealed = false
        updated.stampNewSecrets(now: clock.now)
        e.envelopes[i] = updated
        estate = e; saveEstate()
    }

    /// "Still right." Records the date on the owner's copy and nothing
    /// else: not `updatedAt`, not `sealed`, not the payload. This is the
    /// one write to an envelope that must never cost a re-seal.
    func confirmSecret(envelopeID: String, key: String) {
        guard var e = estate, let i = e.envelopes.firstIndex(where: { $0.id == envelopeID }) else { return }
        e.envelopes[i].secretConfirmations[key] = clock.now
        estate = e; saveEstate()
    }

    /// Every secret on this phone, for the review list.
    var allSecrets: [(envelope: Envelope, card: SealedCard)] {
        (estate?.envelopes ?? []).flatMap { envelope in envelope.secrets.map { (envelope, $0) } }
    }

    /// A new reveal order for one person's envelopes, given as ids top to
    /// bottom. Only an envelope whose place actually changed is touched, and
    /// touching it marks it unsealed, because the order travels in the key
    /// table and the next seal must publish it.
    func reorderEnvelopes(_ orderedIDs: [String]) {
        guard var e = estate else { return }
        var changed = false
        for (position, id) in orderedIDs.enumerated() {
            guard let i = e.envelopes.firstIndex(where: { $0.id == id }) else { continue }
            if e.envelopes[i].revealOrder != position {
                e.envelopes[i].revealOrder = position
                e.envelopes[i].updatedAt = clock.now
                e.envelopes[i].sealed = false
                changed = true
            }
        }
        if changed { estate = e; saveEstate() }
    }

    func removeEnvelope(_ id: String) {
        guard var e = estate else { return }
        if let env = e.envelopes.first(where: { $0.id == id }) {
            for blob in env.photos.map(\.blobID) + [env.voiceNote?.blobID].compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: EstateMediaStore.directory(ownerHash: ownerHash).appendingPathComponent(blob))
            }
        }
        e.envelopes.removeAll { $0.id == id }
        estate = e; saveEstate()
    }

    /// Encrypts media under the envelope's content key and stores the
    /// ciphertext locally. The blob goes to CloudKit at the next seal.
    func attachMedia(_ plaintext: Data, kind: MediaItem.Kind, to envelopeID: String) throws -> MediaItem {
        guard var e = estate, let i = e.envelopes.firstIndex(where: { $0.id == envelopeID }) else { throw EngineError.noEstate }
        let blobID = UUID().uuidString
        let ciphertext = try EstateKeyHierarchy.sealContent(plaintext, contentKey: e.envelopes[i].contentKey,
                                                            estateID: e.id, blobID: blobID)
        try EstateMediaStore.write(ciphertext, blobID: blobID, ownerHash: ownerHash)
        let item = MediaItem(blobID: blobID, kind: kind, sha256: Data(SHA256.hash(data: plaintext)),
                             byteCount: plaintext.count, localName: blobID)
        switch kind {
        case .photo: e.envelopes[i].photos.append(item)
        case .voice: e.envelopes[i].voiceNote = item
        }
        e.envelopes[i].sealed = false
        e.envelopes[i].updatedAt = clock.now
        estate = e; saveEstate()
        return item
    }

    /// Decrypts a local media blob for the owner's own preview.
    func mediaPlaintext(_ item: MediaItem, in envelope: Envelope) -> Data? {
        guard let estate, let ciphertext = EstateMediaStore.read(blobID: item.blobID, ownerHash: ownerHash) else { return nil }
        return try? EstateKeyHierarchy.openContent(ciphertext, contentKey: envelope.contentKey, estateID: estate.id, blobID: item.blobID)
    }

    // MARK: - Owner: sealing and publishing

    /// The whole publish, in order: epoch (if needed), blobs, tables, the
    /// vault statement, invites. Safe to run again after a failure: every
    /// step is idempotent and the estate records what has been done.
    func sealAndPublish() async throws {
        guard var e = estate else { throw EngineError.noEstate }
        guard let mine = identity.kemPrivateBundle else { throw EngineError.noDeviceKey }
        try e.policy.validate(custodianCount: e.custodians.count)
        isWorking = true
        defer { isWorking = false }
        lastError = nil

        let ownerBundles = try await kemBundles(of: ownerHash, named: "your own identity on this phone")
        var previous = EstateLogStore.headDigest(ownerEvents)

        if ownerEvents.isEmpty {
            let body = try EstateEvent.encodeBody(EstateCreatedBody(policy: e.policy, createdAtEpoch: RecordEvent.epochSeconds(e.createdAt)))
            let created = try sign(.estateCreated, estateID: e.id, payload: body, previous: previous)
            try await publish(created, into: e.id, mine: true)
            previous = created.digest
            e.publishedPolicy = e.policy
            estate = e; saveEstate()
        }

        // 1. The epoch.
        let estateKey: Data
        // A key holder on a new phone is the same person with a share they
        // cannot open, so it forces a fresh epoch exactly as a new person
        // would. The check is by directory record, not by the stale list, so
        // it is done again here rather than trusting what refreshOwner saw.
        if e.needsNewEpoch || !custodiansWithNewPhones.isEmpty {
            var custodians: [EstateKeyHierarchy.Custodian] = []
            var custodianKeys: [Data] = []
            var devices: [String: [String]] = [:]
            for c in e.custodians {
                let bundles = try await kemBundles(of: c.rootHash, named: c.displayName)
                custodians.append(.init(hash: c.rootHash, kemBundles: bundles))
                custodianKeys.append(try await lookup(c.rootHash, named: c.displayName).0.publicKey)
                devices[c.rootHash] = Estate.deviceDigests(bundles)
            }
            let newKey = EstateCrypto.randomKey()
            let epoch = e.epoch + 1
            let material = try EstateKeyHierarchy.makeEpoch(estateID: e.id, epoch: epoch, estateKey: newKey,
                                                            ownerBundles: ownerBundles, custodians: custodians,
                                                            threshold: e.policy.threshold)
            let materialData = try EstateEvent.encodeBody(material)
            try await sync.saveEstateBlob(materialData, name: EstateNames.epochBlob(e.id, epoch))
            let body = try EstateEvent.encodeBody(EpochBody(
                epoch: epoch, threshold: e.policy.threshold,
                custodianHashes: e.custodians.map(\.rootHash),
                custodianPublicKeys: custodianKeys,
                shareCommitments: material.custodianShares.map(\.commitment),
                estateKeyCommitment: material.estateKeyCommitment,
                materialDigest: Data(SHA256.hash(data: materialData))))
            let event = try sign(.epochPublished, estateID: e.id, payload: body, previous: previous)
            try await publish(event, into: e.id, mine: true)
            previous = event.digest
            // Every table's release wrap must move to the new epoch, so mark
            // everything unsealed BEFORE recording the epoch as published: a
            // failure between the two must leave the next run re-wrapping.
            for i in e.envelopes.indices { e.envelopes[i].sealed = false }
            e.epoch = epoch
            e.epochPublished = true
            e.publishedCustodianHashes = e.custodians.map(\.rootHash)
            e.publishedThreshold = e.policy.threshold
            e.publishedCustodianDevices = devices
            custodiansWithNewPhones = []
            estate = e; saveEstate()
            estateKey = newKey
        } else {
            guard let data = try await sync.fetchEstateBlob(name: EstateNames.epochBlob(e.id, e.epoch)),
                  let material = try? JSONDecoder().decode(EpochKeyMaterial.self, from: data) else {
                throw EngineError.notReady("The published key material for this estate could not be fetched.")
            }
            estateKey = try EstateKeyHierarchy.openEstateKeyAsOwner(material, mine: mine)
        }

        // 1b. The rule, whenever it changed since it was last announced. The
        //     threshold also travels in the epoch statement; the days do not.
        if e.publishedPolicy != e.policy {
            let body = try EstateEvent.encodeBody(PolicyBody(policy: e.policy))
            let event = try sign(.policyChanged, estateID: e.id, payload: body, previous: previous)
            try await publish(event, into: e.id, mine: true)
            previous = event.digest
            e.publishedPolicy = e.policy
            estate = e; saveEstate()
        }

        // 2. Blobs for every unsealed envelope. `isAddressed` skips the ones
        //    written for somebody who is not in Seal yet: publishing their
        //    content would put a blob in CloudKit that no key table ever
        //    names and nobody could ever open.
        for i in e.envelopes.indices where !e.envelopes[i].sealed && e.envelopes[i].isAddressed {
            var env = e.envelopes[i]
            let payloadBlobID = env.payloadBlobID ?? UUID().uuidString
            let payload = try EstateEvent.encodeBody(env.payload)
            let sealed = try EstateKeyHierarchy.sealContent(payload, contentKey: env.contentKey, estateID: e.id, blobID: payloadBlobID)
            try await sync.saveEstateBlob(sealed, name: EstateNames.contentBlob(e.id, payloadBlobID))
            for item in env.photos + [env.voiceNote].compactMap({ $0 }) {
                guard let ciphertext = EstateMediaStore.read(blobID: item.blobID, ownerHash: ownerHash) else { continue }
                try await sync.saveEstateBlob(ciphertext, name: EstateNames.contentBlob(e.id, item.blobID))
            }
            env.payloadBlobID = payloadBlobID
            env.sealed = true
            e.envelopes[i] = env
            estate = e; saveEstate()
        }

        // 3. One key table per recipient with envelopes.
        var tableIDs: [String] = []
        let recipientHashes = Set(e.addressedEnvelopes.map(\.recipientHash))
        for recipientHash in recipientHashes.sorted() {
            let record = e.tableKeys[recipientHash] ?? Estate.TableKeyRecord(tableID: UUID().uuidString, tableKey: EstateCrypto.randomKey())
            e.tableKeys[recipientHash] = record
            let recipientBundles = try await kemBundles(
                of: recipientHash,
                named: e.recipients.first { $0.rootHash == recipientHash }?.displayName)
            let wrap = try EstateKeyHierarchy.wrapTable(e.keyTable(for: recipientHash), tableID: record.tableID,
                                                        tableKey: record.tableKey, estateID: e.id, epoch: e.epoch,
                                                        estateKey: estateKey, ownerBundles: ownerBundles,
                                                        recipientBundles: recipientBundles)
            try await sync.saveEstateBlob(try EstateEvent.encodeBody(wrap), name: EstateNames.tableBlob(e.id, record.tableID))
            tableIDs.append(record.tableID)
        }
        estate = e; saveEstate()

        // 4. The vault statement.
        let allBlobs = e.addressedEnvelopes.flatMap(\.blobIDs).sorted().joined(separator: "\n")
        let vault = VaultBody(blobCommitment: Data(SHA256.hash(data: Data(allBlobs.utf8))), tableIDs: tableIDs.sorted())
        let vaultEvent = try sign(.vaultUpdated, estateID: e.id, payload: try EstateEvent.encodeBody(vault), previous: previous)
        try await publish(vaultEvent, into: e.id, mine: true)
        e.publishedTableIDs = tableIDs.sorted()
        estate = e; saveEstate()

        // 5. Invites, and a heartbeat so the clock starts from now.
        let myName = identity.rootIdentity?.displayName ?? ""
        for c in e.custodians {
            try await sync.publishEstateInvite(EstateInvite(estateID: e.id, ownerHash: ownerHash, ownerName: myName, role: .custodian),
                                               to: c.rootHash,
                                               addresseeBundles: try await kemBundles(of: c.rootHash, named: c.displayName))
        }
        for r in recipientHashes {
            try await sync.publishEstateInvite(EstateInvite(estateID: e.id, ownerHash: ownerHash, ownerName: myName, role: .recipient),
                                               to: r,
                                               addresseeBundles: try await kemBundles(
                                                of: r, named: e.recipients.first { $0.rootHash == r }?.displayName))
        }
        await sync.ensureEstateSubscription(estateID: e.id)
        await heartbeat()
    }

    // MARK: - Owner: the heartbeat and the cancel

    /// Called on every launch and foreground. One signed line: "I am here."
    /// If a claim is live it ALSO posts a cancellation, so custodians see
    /// the word rather than inferring it. Never needs the hardware key.
    func heartbeat() async {
        guard let e = estate, e.epochPublished, !DemoFixtures.isActive else { return }
        await refreshOwner()
        do {
            var previous = EstateLogStore.headDigest(ownerEvents)
            if let snapshot = ownerSnapshot, ReleaseMachine.ownerCanCancel(snapshot, now: clock.now) {
                let body = try EstateEvent.encodeBody(CancellationBody(claimID: snapshot.claim?.id))
                let cancel = try sign(.cancellation, estateID: e.id, payload: body, previous: previous)
                try await publish(cancel, into: e.id, mine: true)
                previous = cancel.digest
            }
            let hb = try sign(.heartbeat, estateID: e.id, previous: previous)
            try await publish(hb, into: e.id, mine: true)
            shareCheckIn()
        } catch {
            lastError = error.localizedDescription
            Self.log.error("heartbeat: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The two numbers the widget may know (CheckInShared): when the last
    /// heartbeat landed and the silence limit. Nothing else leaves the
    /// engine this way.
    private func shareCheckIn() {
        guard let e = estate, let snapshot = ownerSnapshot else { return }
        CheckInShared.record(lastCheckIn: snapshot.silenceAnchor, silenceDays: e.policy.silenceDays)
    }

    /// The explicit "stop this" button. Same as a heartbeat, but the owner
    /// asked for it by name.
    func cancelClaim() async throws {
        guard let e = estate else { throw EngineError.noEstate }
        await refreshOwner()
        guard let snapshot = ownerSnapshot, ReleaseMachine.ownerCanCancel(snapshot, now: clock.now) else {
            throw EngineError.notAllowed("There is no claim to stop.")
        }
        let body = try EstateEvent.encodeBody(CancellationBody(claimID: snapshot.claim?.id))
        let cancel = try sign(.cancellation, estateID: e.id, payload: body, previous: EstateLogStore.headDigest(ownerEvents))
        try await publish(cancel, into: e.id, mine: true)
        let hb = try sign(.heartbeat, estateID: e.id, previous: cancel.digest)
        try await publish(hb, into: e.id, mine: true)
        shareCheckIn()
    }

    func refreshOwner() async {
        guard let e = estate, !DemoFixtures.isActive else { return }
        do {
            let fetched = try await sync.fetchEstateEvents(estateID: e.id)
            var directory = EstateLogVerifier.Directory(identities: [:])
            directory.identities[ownerHash] = try await lookup(ownerHash, forceRefresh: true)
            // Fresh, not cached, for the custodians too: the one thing this
            // loop now watches for is a phone that changed since last time.
            var newPhones: [Custodian] = []
            for c in e.custodians {
                guard let found = try? await lookup(c.rootHash, forceRefresh: true) else { continue }
                directory.identities[c.rootHash] = found
                // Compare the phones their share was wrapped to against the
                // phones the directory vouches for now. A phone that is gone
                // held a share nobody can use; a phone that is new holds
                // none. Either way the fix is one more seal. Nothing recorded
                // means the estate predates the record, and says nothing.
                if let recorded = e.publishedCustodianDevices[c.rootHash] {
                    let current = Estate.deviceDigests(
                        IdentityManager.verifiedDevices(root: found.0, endorsements: found.1).map(\.kemBundlePublicKeys))
                    if current != recorded { newPhones.append(c) }
                }
            }
            custodiansWithNewPhones = newPhones
            let admitted = EstateLogVerifier.admitted(fetched, ownerHash: ownerHash,
                                                      custodianHashes: Set(e.custodians.map(\.rootHash)),
                                                      directory: directory)
            ownerEvents = EstateLogStore.merged(ownerEvents, admitted)
            saveLogs()
            recomputeAll()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Custodian and recipient: keeping up

    /// Invites, then every guarded estate. Called on launch, foreground, and
    /// every push.
    func refreshGuarded() async {
        guard !DemoFixtures.isActive, let mine = identity.kemPrivateBundle else { return }
        if let invites = try? await sync.fetchEstateInvites(myHash: ownerHash, mine: mine) {
            for invite in invites {
                if let i = guarded.firstIndex(where: { $0.estateID == invite.estateID }) {
                    guarded[i].roles.insert(invite.role)
                    guarded[i].ownerName = invite.ownerName
                } else {
                    guarded.append(GuardedEstate(estateID: invite.estateID, ownerHash: invite.ownerHash,
                                                 ownerName: invite.ownerName, roles: [invite.role],
                                                 epoch: nil, epochEventDigest: nil, vault: nil,
                                                 lastObservationAt: nil, openedAt: nil))
                }
            }
            saveGuarded()
        }
        for i in guarded.indices {
            await refresh(guardedIndex: i)
        }
        recomputeAll()
    }

    private func refresh(guardedIndex i: Int) async {
        var g = guarded[i]
        do {
            let fetched = try await sync.fetchEstateEvents(estateID: g.estateID)
            // The owner first: their key is pinned from the ceremony that
            // made me a custodian, so their events are what everything else
            // hangs from.
            var directory = EstateLogVerifier.Directory(identities: [:])
            directory.identities[g.ownerHash] = try await lookup(g.ownerHash, forceRefresh: true)
            let ownerOnly = EstateLogVerifier.admitted(fetched, ownerHash: g.ownerHash, custodianHashes: [], directory: directory)
            // The newest epoch statement names the custodians and their keys.
            if let epochEvent = ownerOnly.filter({ $0.kind == .epochPublished })
                .max(by: { ($0.occurredAtEpoch, $0.id) < ($1.occurredAtEpoch, $1.id) }),
               let body = epochEvent.body(EpochBody.self) {
                for (hash, key) in zip(body.custodianHashes, body.custodianPublicKeys) {
                    KeyPinStore.pin(hash: hash, publicKey: key)
                }
                g.epoch = body
                g.epochEventDigest = epochEvent.digest
            }
            if let vaultEvent = ownerOnly.filter({ $0.kind == .vaultUpdated })
                .max(by: { ($0.occurredAtEpoch, $0.id) < ($1.occurredAtEpoch, $1.id) }),
               let body = vaultEvent.body(VaultBody.self) {
                g.vault = body
            }
            let custodianHashes = Set(g.epoch?.custodianHashes ?? [])
            for hash in custodianHashes {
                if let found = try? await lookup(hash) { directory.identities[hash] = found }
            }
            let admitted = EstateLogVerifier.admitted(fetched, ownerHash: g.ownerHash,
                                                      custodianHashes: custodianHashes, directory: directory)
            guardedEvents[g.estateID] = EstateLogStore.merged(guardedEvents[g.estateID] ?? [], admitted)
            guarded[i] = g
            saveGuarded()
            saveLogs()
            await sync.ensureEstateSubscription(estateID: g.estateID)
            recomputeAll()
            await observeSilenceIfDue(guardedIndex: i)
        } catch {
            lastError = error.localizedDescription
            Self.log.error("refresh \(g.estateID.prefix(8), privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A custodian's phone that sees the owner overdue says so, signed,
    /// once a day. Evidence, not a decision.
    private func observeSilenceIfDue(guardedIndex i: Int) async {
        let g = guarded[i]
        guard g.isCustodian, let snapshot = guardedSnapshots[g.estateID],
              ReleaseMachine.state(snapshot, now: clock.now) == .overdue else { return }
        if let last = g.lastObservationAt, clock.now.timeIntervalSince(last) < 86_400 { return }
        do {
            let events = guardedEvents[g.estateID] ?? []
            let lastHB = events.filter { $0.kind == .heartbeat }.max { $0.occurredAtEpoch < $1.occurredAtEpoch }
            let body = try EstateEvent.encodeBody(ObservationBody(lastHeartbeatDigest: lastHB?.digest,
                                                                  lastHeartbeatAtEpoch: lastHB?.occurredAtEpoch))
            let event = try sign(.silenceObserved, estateID: g.estateID, payload: body, previous: EstateLogStore.headDigest(events))
            try await publish(event, into: g.estateID, mine: false)
            guarded[i].lastObservationAt = clock.now
            saveGuarded()
        } catch {
            Self.log.error("observe: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Custodian: the claim, the objection, the tap

    private func guardedEstate(_ estateID: String) throws -> (GuardedEstate, ReleaseSnapshot) {
        guard let g = guarded.first(where: { $0.estateID == estateID }), let s = guardedSnapshots[estateID] else {
            throw EngineError.noEstate
        }
        return (g, s)
    }

    func openClaim(estateID: String, reason: String) async throws {
        let (g, s) = try guardedEstate(estateID)
        guard g.isCustodian, let epoch = g.epoch else { throw EngineError.notAllowed("You are not a custodian of this estate.") }
        guard ReleaseMachine.custodianCanClaim(s, now: clock.now) else {
            throw EngineError.notAllowed("A claim can only start once the owner has been silent for the full period.")
        }
        let events = guardedEvents[estateID] ?? []
        let lastHB = events.filter { $0.kind == .heartbeat }.max { $0.occurredAtEpoch < $1.occurredAtEpoch }
        let body = try EstateEvent.encodeBody(ClaimBody(claimID: UUID().uuidString, epoch: epoch.epoch,
                                                        lastHeartbeatAtEpoch: lastHB?.occurredAtEpoch, reason: reason))
        let event = try sign(.releaseClaimed, estateID: estateID, payload: body, previous: EstateLogStore.headDigest(events))
        try await publish(event, into: estateID, mine: false)
    }

    func object(estateID: String, note: String, withdraw: Bool = false) async throws {
        let (g, s) = try guardedEstate(estateID)
        guard g.isCustodian, let claim = s.claim else { throw EngineError.notAllowed("There is no claim to object to.") }
        let events = guardedEvents[estateID] ?? []
        let body = try EstateEvent.encodeBody(ObjectionBody(claimID: claim.id, withdrawn: withdraw, note: note))
        let event = try sign(withdraw ? .objectionWithdrawn : .objection, estateID: estateID, payload: body,
                             previous: EstateLogStore.headDigest(events))
        try await publish(event, into: estateID, mine: false)
    }

    /// Fetches this estate's epoch material and checks it against the
    /// owner's signed statement before trusting a byte of it.
    private func epochMaterial(for g: GuardedEstate) async throws -> EpochKeyMaterial {
        guard let epoch = g.epoch else { throw EngineError.noShare }
        guard let data = try await sync.fetchEstateBlob(name: EstateNames.epochBlob(g.estateID, epoch.epoch)) else {
            throw EngineError.notReady("The key material for this estate is not available yet.")
        }
        guard Data(SHA256.hash(data: data)) == epoch.materialDigest,
              let material = try? JSONDecoder().decode(EpochKeyMaterial.self, from: data),
              material.custodianShares.map(\.commitment) == epoch.shareCommitments,
              material.estateKeyCommitment == epoch.estateKeyCommitment else {
            throw EngineError.notReady("The key material does not match what the owner signed. Do not proceed.")
        }
        return material
    }

    /// My share, opened and checked. Stays in memory only.
    func myShare(estateID: String) async throws -> Shamir.Share {
        let (g, _) = try guardedEstate(estateID)
        guard let mine = identity.kemPrivateBundle else { throw EngineError.noDeviceKey }
        let material = try await epochMaterial(for: g)
        return try EstateKeyHierarchy.openMyShare(material, custodianHash: ownerHash, mine: mine)
    }

    /// The tap. Physical key on this phone, over a challenge bound to this
    /// exact claim and history, plus my share re-wrapped to the claimant.
    func authorize(estateID: String, ceremony: CeremonyManager) async throws {
        let (g, s) = try guardedEstate(estateID)
        guard let myRoot = identity.rootIdentity else { throw EngineError.noDeviceKey }
        guard g.isCustodian, let epoch = g.epoch, let claim = s.claim else {
            throw EngineError.notAllowed("There is no open claim on this estate.")
        }
        guard ReleaseMachine.custodianCanAuthorize(s, now: clock.now, custodianHash: ownerHash) else {
            throw EngineError.notAllowed("The claim is not open for keys yet, or you have already tapped.")
        }
        let events = guardedEvents[estateID] ?? []
        let head = EstateLogStore.headDigest(events)
        let share = try await myShare(estateID: estateID)
        let claimantBundles = try await kemBundles(of: claim.claimantHash)
        let wrapped = try HybridWrap.wrapToAll(share.encoded, to: claimantBundles,
                                              aad: ReleaseChallenge.shareAAD(estateID: estateID, epoch: epoch.epoch, claimID: claim.id))
        let challenge = ReleaseChallenge.challenge(estateID: estateID, epoch: epoch.epoch, claimID: claim.id, recordHeadDigest: head)
        let assertion = try await ceremony.signReleaseAuthorization(challenge: challenge, myRoot: myRoot)
        let body = try EstateEvent.encodeBody(AuthorizationBody(claimID: claim.id, epoch: epoch.epoch,
                                                                recordHeadDigest: head, assertion: assertion,
                                                                shareForClaimant: wrapped))
        let event = try sign(.authorization, estateID: estateID, payload: body, previous: head)
        try await publish(event, into: estateID, mine: false)
    }

    /// Which authorizations on the current claim carry a real tap: the
    /// assertion verifies under the custodian's pinned root key over the
    /// challenge it claims. The machine counted them by time; this is the
    /// cryptographic check before shares are combined.
    func verifiedAuthorizations(estateID: String) async throws -> [(event: EstateEvent, body: AuthorizationBody)] {
        let (g, s) = try guardedEstate(estateID)
        guard let claim = s.claim, let epoch = g.epoch else { return [] }
        // Spelled with its labels: an array of unlabelled tuples is a
        // different type and does not convert (see IdentityManager.authorityKeys).
        var out: [(event: EstateEvent, body: AuthorizationBody)] = []
        for event in (guardedEvents[estateID] ?? []) where event.kind == .authorization {
            guard let body = event.body(AuthorizationBody.self), body.claimID == claim.id, body.epoch == epoch.epoch,
                  let found = try? await lookup(event.actorHash),
                  let key = try? P256.Signing.PublicKey(rawRepresentation: found.0.publicKey) else { continue }
            let challenge = ReleaseChallenge.challenge(estateID: estateID, epoch: epoch.epoch, claimID: claim.id,
                                                       recordHeadDigest: body.recordHeadDigest)
            guard body.assertion.verify(with: key),
                  CeremonyManager.clientDataChallengeMatches(body.assertion.clientDataJSON, expected: challenge) else { continue }
            out.append((event: event, body: body))
        }
        return out
    }

    /// The claimant combines. M verified taps, M shares opened on this
    /// phone, each checked against its commitment, the Estate Key recovered
    /// and checked against ITS commitment, then published in the clear in a
    /// signed `released` event.
    func release(estateID: String) async throws {
        let (g, s) = try guardedEstate(estateID)
        guard let mine = identity.kemPrivateBundle else { throw EngineError.noDeviceKey }
        guard let claim = s.claim, claim.claimantHash == ownerHash else {
            throw EngineError.notAllowed("Only the custodian who opened the claim can combine the keys.")
        }
        guard ReleaseMachine.claimantCanRelease(s, now: clock.now), let epoch = g.epoch else {
            throw EngineError.notAllowed("Not enough custodians have tapped yet.")
        }
        let material = try await epochMaterial(for: g)
        var shares: [Shamir.Share] = []
        let aad = ReleaseChallenge.shareAAD(estateID: estateID, epoch: epoch.epoch, claimID: claim.id)
        for (_, body) in try await verifiedAuthorizations(estateID: estateID) {
            if let encoded = try? HybridWrap.openAny(body.shareForClaimant, with: mine, aad: aad),
               let share = Shamir.Share(encoded: encoded) {
                shares.append(share)
            }
        }
        if let own = try? EstateKeyHierarchy.openMyShare(material, custodianHash: ownerHash, mine: mine),
           !shares.contains(where: { $0.index == own.index }) {
            shares.append(own)
        }
        let estateKey = try EstateKeyHierarchy.recoverEstateKey(material, submitted: shares)
        let body = try EstateEvent.encodeBody(ReleasedBody(claimID: claim.id, epoch: epoch.epoch,
                                                           shareIndexes: shares.map(\.index).sorted(),
                                                           estateKey: estateKey))
        let event = try sign(.released, estateID: estateID, payload: body,
                             previous: EstateLogStore.headDigest(guardedEvents[estateID] ?? []))
        try await publish(event, into: estateID, mine: false)
    }

    // MARK: - Recipient: opening

    struct OpenedEnvelope: Identifiable, Hashable {
        var id: String { entry.envelopeID }
        let entry: KeyTableEntry
        let payload: Envelope.Payload
    }

    /// After release: the published Estate Key plus my own KEM key open my
    /// table, and only mine. Media is fetched on demand by `openMedia`.
    func openEnvelopes(estateID: String) async throws -> [OpenedEnvelope] {
        let (g, s) = try guardedEstate(estateID)
        guard let mine = identity.kemPrivateBundle else { throw EngineError.noDeviceKey }
        guard s.releasedAt != nil,
              let released = (guardedEvents[estateID] ?? []).last(where: { $0.kind == .released })?.body(ReleasedBody.self)
        else { throw EngineError.notReleased }
        var out: [OpenedEnvelope] = []
        for tableID in g.vault?.tableIDs ?? [] {
            guard let data = try await sync.fetchEstateBlob(name: EstateNames.tableBlob(estateID, tableID)),
                  let wrap = try? JSONDecoder().decode(RecipientTableWrap.self, from: data) else { continue }
            guard let tableKey = try? EstateKeyHierarchy.openTableKeyAsRecipient(wrap, estateID: estateID,
                                                                                 estateKey: released.estateKey, mine: mine)
            else { continue }   // not my table, by design
            let table = try EstateKeyHierarchy.openTable(wrap, estateID: estateID, tableKey: tableKey)
            for entry in table.entries.sorted(by: { $0.revealOrder < $1.revealOrder }) {
                guard let payloadID = entry.blobIDs.first,
                      let blob = try await sync.fetchEstateBlob(name: EstateNames.contentBlob(estateID, payloadID)) else { continue }
                let plaintext = try EstateKeyHierarchy.openContent(blob, contentKey: entry.contentKey, estateID: estateID, blobID: payloadID)
                let payload = try JSONDecoder().decode(Envelope.Payload.self, from: plaintext)
                out.append(OpenedEnvelope(entry: entry, payload: payload))
            }
        }
        if let i = guarded.firstIndex(where: { $0.estateID == estateID }), guarded[i].openedAt == nil {
            guarded[i].openedAt = clock.now
            saveGuarded()
        }
        return out
    }

    func openMedia(_ item: MediaItem, entry: KeyTableEntry, estateID: String) async throws -> Data {
        guard let blob = try await sync.fetchEstateBlob(name: EstateNames.contentBlob(estateID, item.blobID)) else {
            throw EngineError.notReady("That file is not available.")
        }
        let plaintext = try EstateKeyHierarchy.openContent(blob, contentKey: entry.contentKey, estateID: estateID, blobID: item.blobID)
        guard Data(SHA256.hash(data: plaintext)) == item.sha256 else {
            throw EngineError.notReady("That file does not match what the owner sealed.")
        }
        return plaintext
    }

    // MARK: - Wipe

    static func wipe(ownerHash: String) {
        EstateStore.wipe(ownerHash: ownerHash)
        EstateMediaStore.wipe(ownerHash: ownerHash)
    }
}
