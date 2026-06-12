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
    private static let storageKey = "seal.friends"

    init() { load() }

    func add(identity: RootIdentity, friendship: Friendship) {
        friends.removeAll { $0.identity.credentialIDHash == identity.credentialIDHash }
        friends.append(StoredFriend(identity: identity, friendship: friendship))
        save()
    }

    func remove(_ credentialIDHash: String) {
        friends.removeAll { $0.identity.credentialIDHash == credentialIDHash }
        save()
    }

    func isFriend(_ credentialIDHash: String) -> Bool {
        friends.contains { $0.identity.credentialIDHash == credentialIDHash }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(friends) {
            KeychainStore.save(data, for: Self.storageKey)
        }
    }

    private func load() {
        if let data = KeychainStore.load(Self.storageKey),
           let decoded = try? JSONDecoder().decode([StoredFriend].self, from: data) {
            friends = decoded
        }
    }
}
