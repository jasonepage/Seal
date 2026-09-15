import Foundation

//  CustodianVault.swift
//  Seal
//
//  What a custodian's or recipient's phone keeps about the estates it has a
//  part in. Keychain JSON per identity, like every other store. The events
//  themselves live in EstateLogStore; this is the index.

struct GuardedEstate: Codable, Identifiable, Hashable {
    var id: String { estateID }
    let estateID: String
    let ownerHash: String
    var ownerName: String
    var roles: Set<EstateInvite.Role>
    /// The newest epoch statement this phone has verified.
    var epoch: EpochBody?
    var epochEventDigest: Data?
    /// The newest vault statement.
    var vault: VaultBody?
    /// When this phone last posted a silence observation, to avoid one a
    /// minute.
    var lastObservationAt: Date?
    /// Set once the recipient has opened their envelopes after release.
    var openedAt: Date?

    var isCustodian: Bool { roles.contains(.custodian) }
    var isRecipient: Bool { roles.contains(.recipient) }
}

enum CustodianVault {
    private static func key(_ ownerHash: String) -> String { "seal.guarded.\(ownerHash)" }

    static func load(ownerHash: String) -> [GuardedEstate] {
        guard let data = KeychainStore.load(key(ownerHash)),
              let decoded = try? JSONDecoder().decode([GuardedEstate].self, from: data) else { return [] }
        return decoded
    }

    static func save(_ estates: [GuardedEstate], ownerHash: String) {
        if let data = try? JSONEncoder().encode(estates) {
            KeychainStore.save(data, for: key(ownerHash))
        }
    }

    static func wipe(ownerHash: String) {
        KeychainStore.delete(key(ownerHash))
    }
}
