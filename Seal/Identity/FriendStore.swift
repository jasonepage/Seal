// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Local store of forged friendships + cached friend identities.
/// TODO(SyncEngine): mirror Friendship attestations to CloudKit (FR-6) so
/// other devices and group members can verify them.
@Observable
final class FriendStore {
    struct StoredFriend: Codable, Identifiable, Hashable {
        var id: String { identity.credentialIDHash }
        let identity: RootIdentity
        let friendship: Friendship
    }

    private(set) var friends: [StoredFriend] = []
    let ownerHash: String
    private var storageKey: String { "seal.friends.\(ownerHash)" }

    init(ownerHash: String) {
        self.ownerHash = ownerHash
        load()
    }

    static func wipe(ownerHash: String) {
        KeychainStore.delete("seal.friends.\(ownerHash)")
        KeychainStore.delete(goneLedgerKey(ownerHash))
        KeychainStore.delete(goneCheckedKey(ownerHash))
    }

    func add(identity: RootIdentity, friendship: Friendship) {
        // Every path that reaches here has just verified a signature chain
        // rooted in `identity.publicKey` (a ceremony tap, a reciprocal
        // handshake, an introduction). That proof is what earns the pin; the
        // pin is what stops the directory from replacing the key later
        // (KeyPinStore.swift, security fix 1).
        KeyPinStore.pin(hash: identity.credentialIDHash, publicKey: identity.publicKey)
        friends.removeAll { $0.identity.credentialIDHash == identity.credentialIDHash }
        friends.append(StoredFriend(identity: identity, friendship: friendship))
        save()
    }

    func remove(_ credentialIDHash: String) {
        // A person known to be gone keeps that mark after they leave People,
        // so an envelope or a key still addressed to them keeps saying so.
        if let at = goneDate(credentialIDHash) { remember(gone: credentialIDHash, at: at) }
        // Removing a person is the ONE sanctioned way to drop their pin, so
        // that meeting them again after a genuine re-registration works.
        KeyPinStore.forget(hash: credentialIDHash)
        friends.removeAll { $0.identity.credentialIDHash == credentialIDHash }
        save()
    }

    func isFriend(_ credentialIDHash: String) -> Bool {
        friends.contains { $0.identity.credentialIDHash == credentialIDHash }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(friends) {
            KeychainStore.save(data, for: storageKey)
        }
    }

    private func load() {
        if let data = KeychainStore.load(storageKey),
           let decoded = try? JSONDecoder().decode([StoredFriend].self, from: data) {
            friends = decoded
        }
        if let data = KeychainStore.load(Self.goneLedgerKey(ownerHash)),
           let decoded = try? JSONDecoder().decode([String: Date].self, from: data) {
            goneLedger = decoded
        }
        if let data = KeychainStore.load(Self.goneCheckedKey(ownerHash)),
           let decoded = try? JSONDecoder().decode(Date.self, from: data) {
            lastGoneCheck = decoded
        }
    }

    // MARK: - People who deleted their Seal account (GoneCheck.swift)

    /// Hashes known to be gone that are NOT in `friends`: a person removed
    /// from People after they were found gone, or a key holder or recipient
    /// with no friendship on this phone. Keychain JSON, per identity.
    private(set) var goneLedger: [String: Date] = [:]
    /// When this phone last asked the directory. Throttles the daily check.
    private(set) var lastGoneCheck: Date?

    static func goneLedgerKey(_ ownerHash: String) -> String { "seal.gone.\(ownerHash)" }
    static func goneCheckedKey(_ ownerHash: String) -> String { "seal.goneChecked.\(ownerHash)" }

    /// Every hash this phone knows is gone, and when it found out.
    var goneMarks: [String: Date] {
        var out = goneLedger
        for f in friends { if let at = f.friendship.tombstonedAt { out[f.id] = at } }
        return out
    }

    func goneDate(_ credentialIDHash: String) -> Date? { goneMarks[credentialIDHash] }

    /// Mark a person gone. A friend gets the mark on their friendship; any
    /// other hash goes in the ledger. The first date found is kept.
    func markGone(_ credentialIDHash: String, at date: Date) {
        guard goneDate(credentialIDHash) == nil else { return }
        if let i = friends.firstIndex(where: { $0.id == credentialIDHash }) {
            var friendship = friends[i].friendship
            friendship.tombstonedAt = date
            friends[i] = StoredFriend(identity: friends[i].identity, friendship: friendship)
            save()
        } else {
            remember(gone: credentialIDHash, at: date)
        }
    }

    func noteGoneCheck(at date: Date) {
        lastGoneCheck = date
        if let data = try? JSONEncoder().encode(date) {
            KeychainStore.save(data, for: Self.goneCheckedKey(ownerHash))
        }
    }

    private func remember(gone hash: String, at date: Date) {
        guard goneLedger[hash] == nil else { return }
        goneLedger[hash] = date
        if let data = try? JSONEncoder().encode(goneLedger) {
            KeychainStore.save(data, for: Self.goneLedgerKey(ownerHash))
        }
    }
}
