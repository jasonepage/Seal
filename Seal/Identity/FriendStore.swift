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
        /// VERIFIED perk attestations (PerkAuthority checked before caching).
        /// Optional so pre-perk keychain data still decodes.
        var perks: [PerkAttestation]?
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
        // Removing a person is the ONE sanctioned way to drop their pin, so
        // that meeting them again after a genuine re-registration works.
        KeyPinStore.forget(hash: credentialIDHash)
        friends.removeAll { $0.identity.credentialIDHash == credentialIDHash }
        save()
    }

    /// Cache a friend's verified perks (caller verifies via PerkAuthority first).
    func setPerks(_ perks: [PerkAttestation], for credentialIDHash: String) {
        guard let index = friends.firstIndex(where: { $0.identity.credentialIDHash == credentialIDHash }),
              friends[index].perks != perks else { return }
        friends[index].perks = perks
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
    }
}
