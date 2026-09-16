// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

//  RuleBook.swift
//  Seal
//
//  ONE RULE IS ONE BOX OF KEYS (RELEASE.md section 13).
//
//  An envelope picks a rule. Envelopes that share a rule share one Estate
//  Key, one set of shares, one set of key holders, one claim and one round
//  of taps. Each rule is therefore its own EstateEngine with its own local
//  storage, exactly what "Bills and medical" was: this file only makes the
//  list of them a list instead of two fixed cases.
//
//    RuleSlot      one rule: an id that never changes and a name the owner
//                  can edit. The id decides where the rule's stores are
//                  filed, so "" (the default) and "urgent" (the old Bills
//                  and medical set) keep the storage they always had, and
//                  nothing on any phone moves.
//    RuleBook      the list of one identity's rules, keychain JSON, at most
//                  three, wiped with everything else at sign out.
//    EstateEngines the live engines, one per rule, the default first.
//
//  Nothing here touches the key hierarchy, the release machine, the
//  record or CloudKit. A key holder's phone sees each rule as its own
//  estate, named "Karen" for the default and "Karen (Sooner)" otherwise.

// MARK: - One rule

struct RuleSlot: Codable, Hashable, Identifiable {
    /// "" for the default rule, "urgent" for the set Bills and medical made
    /// before rules existed, "r2", "r3" for rules added since. Never shown
    /// to a person and never changed once made.
    let id: String
    /// What the owner calls it. Shown on the Keys tab, on each envelope row
    /// when there is more than one rule, and to key holders in brackets
    /// after the owner's name.
    var name: String

    static let defaultID = ""
    static let legacyUrgentID = "urgent"
    static let legacyUrgentName = "Bills and medical"
    static let defaultName = "Your rule"
    static let suggestedSecondName = "Sooner"

    static let main = RuleSlot(id: defaultID, name: defaultName)

    var isDefault: Bool { id == Self.defaultID }

    /// The key every local store of this rule's engine is filed under.
    /// The identity hash for the default rule (unchanged from before rules
    /// existed), a prefixed one for every other rule.
    func storeHash(ownerHash: String) -> String {
        isDefault ? ownerHash : "\(id).\(ownerHash)"
    }

    /// What a key holder sees the owner called, so two rules from one
    /// person read apart on their phone. The default rule is the bare
    /// name, so nothing changes for anyone who set up before rules.
    func ownerLabel(_ name: String) -> String {
        let trimmed = self.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if isDefault || trimmed.isEmpty { return name }
        return "\(name) (\(trimmed))"
    }

    /// A rule that is not the default starts with the short numbers, the
    /// ones Bills and medical used, because that is the rule people ask
    /// for. The owner can change them on the rule screen.
    var startsShort: Bool { !isDefault }
}

// MARK: - The list

enum RuleBook {
    /// Three, not more. Every rule is one more round of taps for the
    /// family and one more line on each key holder's phone.
    static let maxRules = 3

    static func key(_ ownerHash: String) -> String { "seal.rules.\(ownerHash)" }

    /// The saved list, or, when nothing was ever saved, the default rule
    /// plus the Bills and medical set if a build before rules made one.
    static func load(ownerHash: String) -> [RuleSlot] {
        if let data = KeychainStore.load(key(ownerHash)),
           let saved = try? JSONDecoder().decode([RuleSlot].self, from: data),
           !saved.isEmpty {
            return normalized(saved)
        }
        return migrated(ownerHash: ownerHash, urgentExists: EstateStore.load(ownerHash: legacyUrgentStoreHash(ownerHash)) != nil)
    }

    /// Pure, so the test can run it without a keychain.
    static func migrated(ownerHash: String, urgentExists: Bool) -> [RuleSlot] {
        var rules = [RuleSlot.main]
        if urgentExists {
            rules.append(RuleSlot(id: RuleSlot.legacyUrgentID, name: RuleSlot.legacyUrgentName))
        }
        return rules
    }

    static func legacyUrgentStoreHash(_ ownerHash: String) -> String {
        RuleSlot(id: RuleSlot.legacyUrgentID, name: "").storeHash(ownerHash: ownerHash)
    }

    static func save(_ rules: [RuleSlot], ownerHash: String) {
        if let data = try? JSONEncoder().encode(normalized(rules)) {
            KeychainStore.save(data, for: key(ownerHash))
        }
    }

    static func wipe(ownerHash: String) {
        KeychainStore.delete(key(ownerHash))
    }

    /// The default first, no duplicate ids, never empty, never more than
    /// the cap. Pure.
    static func normalized(_ rules: [RuleSlot]) -> [RuleSlot] {
        var seen = Set<String>()
        var out: [RuleSlot] = []
        for r in rules where !seen.contains(r.id) {
            seen.insert(r.id)
            out.append(r)
        }
        if let i = out.firstIndex(where: { $0.isDefault }) {
            if i != 0 { out.insert(out.remove(at: i), at: 0) }
        } else {
            out.insert(.main, at: 0)
        }
        return Array(out.prefix(maxRules))
    }

    /// The next free id, or nil at the cap. Pure.
    static func nextID(after rules: [RuleSlot]) -> String? {
        guard rules.count < maxRules else { return nil }
        var n = 2
        while rules.contains(where: { $0.id == "r\(n)" }) { n += 1 }
        return "r\(n)"
    }

    /// Every store hash a wipe has to cover: the ids in the book, the two
    /// legacy ids, and every id a rule could ever have been given, whether
    /// or not the book still lists it. Cheap, and it means a rule removed
    /// by a build with a bug still leaves nothing behind at sign out.
    static func allStoreHashes(ownerHash: String) -> [String] {
        var ids = Set(load(ownerHash: ownerHash).map(\.id))
        ids.insert(RuleSlot.defaultID)
        ids.insert(RuleSlot.legacyUrgentID)
        for n in 2...(maxRules + 3) { ids.insert("r\(n)") }
        return ids.sorted().map { RuleSlot(id: $0, name: "").storeHash(ownerHash: ownerHash) }
    }
}

// MARK: - The live engines

/// One engine per rule, the default first. Built by ContentView once per
/// identity and handed down; every screen that used to take two engines
/// takes this.
@Observable
final class EstateEngines {
    let ownerHash: String
    private let identity: IdentityManager
    private let sync: SyncEngine
    private(set) var rules: [RuleSlot]
    private(set) var all: [EstateEngine]

    init(ownerHash: String, identity: IdentityManager, sync: SyncEngine) {
        self.ownerHash = ownerHash
        self.identity = identity
        self.sync = sync
        let rules = RuleBook.load(ownerHash: ownerHash)
        self.rules = rules
        self.all = rules.map { EstateEngine(ownerHash: ownerHash, identity: identity, sync: sync, slot: $0) }
    }

    /// The default rule's engine. What this phone holds for others lives
    /// here (guarded estates are fetched once, not once per rule), and so
    /// does the widget's number.
    var main: EstateEngine { all[0] }

    var canAdd: Bool { rules.count < RuleBook.maxRules }

    func engine(forRuleID id: String) -> EstateEngine? {
        all.first { $0.slot.id == id }
    }

    func slot(of engine: EstateEngine) -> RuleSlot { engine.slot }

    /// The name to show beside an envelope, or nil when there is only one
    /// rule and a tag would be noise.
    func tag(for engine: EstateEngine) -> String? {
        rules.count > 1 ? engine.slot.name : nil
    }

    /// Every envelope on this phone with the engine it belongs to, newest
    /// first, for the one inbox.
    var allEnvelopes: [(engine: EstateEngine, envelope: Envelope)] {
        all.flatMap { engine in (engine.estate?.envelopes ?? []).map { (engine: engine, envelope: $0) } }
            .sorted { $0.envelope.updatedAt > $1.envelope.updatedAt }
    }

    /// A new rule with the short numbers. Nil at the cap.
    @discardableResult
    func addRule(named name: String) -> EstateEngine? {
        guard let id = RuleBook.nextID(after: rules) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let slot = RuleSlot(id: id, name: trimmed.isEmpty ? RuleSlot.suggestedSecondName : trimmed)
        rules.append(slot)
        RuleBook.save(rules, ownerHash: ownerHash)
        let engine = EstateEngine(ownerHash: ownerHash, identity: identity, sync: sync, slot: slot)
        engine.createEstateIfNeeded()
        all.append(engine)
        return engine
    }

    /// The name is metadata: it is in no signature and no share. Key
    /// holders see the new name on the next seal, in the invite.
    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[i].name = trimmed
        RuleBook.save(rules, ownerHash: ownerHash)
        all.first { $0.slot.id == id }?.rename(slot: rules[i])
    }

    enum RemoveRefusal {
        case isDefault, hasEnvelopes, sealed
        var line: String {
            switch self {
            case .isDefault: "Your first rule stays. You can rename it or change its numbers."
            case .hasEnvelopes: "Move or delete its envelopes first."
            case .sealed: "It has been sealed, so key holders hold shares for it. Move its envelopes out and seal again first."
            }
        }
    }

    /// Why a rule cannot go, or nil when it can. Pure over the estate.
    func removeRefusal(_ id: String) -> RemoveRefusal? {
        guard let engine = engine(forRuleID: id) else { return nil }
        return Self.removeRefusal(slot: engine.slot, estate: engine.estate)
    }

    static func removeRefusal(slot: RuleSlot, estate: Estate?) -> RemoveRefusal? {
        if slot.isDefault { return .isDefault }
        guard let estate else { return nil }
        if !estate.envelopes.isEmpty { return .hasEnvelopes }
        if estate.epochPublished { return .sealed }
        return nil
    }

    enum MoveError: LocalizedError {
        case sameRule, notFound, media(String)
        var errorDescription: String? {
            switch self {
            case .sameRule: "The envelope is already on that rule."
            case .notFound: "That envelope is not on this phone any more."
            case .media(let what): "Could not carry \(what) across. The envelope was not moved."
            }
        }
    }

    /// MOVE AN ENVELOPE TO ANOTHER RULE. Another rule is another box of
    /// keys, so the envelope gets a fresh id and a fresh content key in the
    /// new box (the old key was in the old box's tables), the words come
    /// across, and every photo, voice and video is decrypted under the old
    /// rule and encrypted again under the new one. The old rule is marked
    /// so its next seal publishes its tables without the envelope. Both
    /// rules need sealing again, and the editor says so before the move.
    /// Nothing is removed from the old rule until everything has landed in
    /// the new one.
    @discardableResult
    func move(_ envelopeID: String, from source: EstateEngine, to target: EstateEngine) throws -> Envelope {
        guard source !== target else { throw MoveError.sameRule }
        guard let old = source.estate?.envelopes.first(where: { $0.id == envelopeID }) else { throw MoveError.notFound }
        let now = source.now

        var moved: Envelope
        if !old.isAddressed {
            moved = Envelope.unbound(name: old.draftRecipientName ?? "", title: old.title, now: now)
        } else {
            moved = Envelope.new(recipientHash: old.recipientHash, title: old.title, now: now, revealOrder: 1)
        }
        moved.letter = old.letter
        moved.secrets = old.secrets
        moved.firstSteps = old.firstSteps
        moved.openNoEarlierThan = old.openNoEarlierThan
        moved.secretConfirmations = old.secretConfirmations

        // Everything must be readable before anything is written.
        var photos: [Data] = []
        for item in old.photos {
            guard let data = source.mediaPlaintext(item, in: old) else { throw MoveError.media("a photo") }
            photos.append(data)
        }
        var voice: Data? = nil
        if let item = old.voiceNote {
            guard let data = source.mediaPlaintext(item, in: old) else { throw MoveError.media("the voice message") }
            voice = data
        }
        var video: Data? = nil
        if let item = old.videoNote {
            guard let data = source.mediaPlaintext(item, in: old) else { throw MoveError.media("the video") }
            video = data
        }

        let recipient = source.estate?.recipients.first { $0.rootHash == old.recipientHash }
        target.adopt(moved, recipient: recipient)
        do {
            for data in photos { _ = try target.attachMedia(data, kind: .photo, to: moved.id) }
            if let voice { _ = try target.attachMedia(voice, kind: .voice, to: moved.id) }
            if let video { _ = try target.attachMedia(video, kind: .video, to: moved.id) }
        } catch {
            // Undo the landing so the owner is not left with two copies.
            target.removeEnvelope(moved.id)
            throw MoveError.media("the photos, voice or video")
        }

        source.removeEnvelope(old.id)
        source.markTablesStale()
        return target.estate?.envelopes.first { $0.id == moved.id } ?? moved
    }

    /// Everyone who holds a key for any rule, once each, with the rules
    /// they hold a key for. For the Keys tab, which is about people.
    struct KeyHolderRow: Identifiable {
        let custodian: Custodian
        let engines: [EstateEngine]
        var id: String { custodian.rootHash }
        var ruleNames: [String] { engines.map(\.slot.name) }
        /// The engine whose page opens for this person: the default rule's
        /// when they hold a key for it, otherwise the first.
        var primary: EstateEngine { engines.first { $0.slot.isDefault } ?? engines[0] }
        /// Signed on every rule they hold a key for.
        var handoverSigned: Bool {
            engines.allSatisfy { engine in
                engine.estate?.custodians.first { $0.rootHash == custodian.rootHash }?.handoverReceiptID != nil
            }
        }
    }

    var keyHolderRows: [KeyHolderRow] {
        var order: [String] = []
        var byHash: [String: (Custodian, [EstateEngine])] = [:]
        for engine in all {
            for c in engine.estate?.custodians ?? [] {
                if byHash[c.rootHash] == nil { order.append(c.rootHash); byHash[c.rootHash] = (c, []) }
                byHash[c.rootHash]?.1.append(engine)
            }
        }
        return order.compactMap { hash in byHash[hash].map { KeyHolderRow(custodian: $0.0, engines: $0.1) } }
    }

    /// Removes the rule and wipes its local stores. Refuses silently when
    /// `removeRefusal` says no; the button is off in that case anyway.
    func remove(_ id: String) {
        guard removeRefusal(id) == nil, let engine = engine(forRuleID: id) else { return }
        rules.removeAll { $0.id == id }
        all.removeAll { $0 === engine }
        RuleBook.save(rules, ownerHash: ownerHash)
        EstateStore.wipe(ownerHash: engine.storeHash)
        EstateMediaStore.wipe(ownerHash: engine.storeHash)
        OwnerNotices.wipe(ownerHash: engine.storeHash)
    }
}
