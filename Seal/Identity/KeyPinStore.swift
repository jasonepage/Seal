import Foundation
import os

//  KeyPinStore.swift
//  Seal
//
//  ROOT KEY PINNING (security fix 1 of 4, docs/SDS.md section 11).
//
//  Before this file, a friend's root public key was read from the directory
//  on every fetch and trusted every time. The ceremony proved, once, that the
//  person tapping controlled the key the directory published at that moment.
//  Nothing remembered that proof. A directory able to swap the `publicKey`
//  field on a record could therefore swap the person: every later
//  verification would happily check signatures against the attacker's key.
//
//  In a messenger that is a bad bug. In a product where the directory entry
//  is a custodian who can help open somebody's envelopes, it means the
//  directory can swap an heir. So the key is pinned at the moment it was
//  proven, and every directory fetch afterwards must match the pin or the
//  record is refused outright.
//
//  Pins are facts about OTHER identities ("hash H has key K") and are the
//  same fact whoever observed them, so the store is global rather than per
//  owner identity. A pin can only ever cause a refusal, never an acceptance,
//  so a stale pin is a loud failure ("this person's key changed, meet again")
//  rather than a quiet hole. Pins survive sign-out on purpose for the same
//  reason: the next sign-in should not start trusting the directory again.
//
//  A hash is SHA256 of the credential ID, and the credential ID is fixed at
//  registration, so an identity that is deleted and recreated gets a NEW hash
//  and never collides with an old pin. The only way to legitimately change
//  the key behind a hash is not to; there is no such path in the protocol.

enum KeyPinStore {

    enum PinError: LocalizedError, Equatable {
        case publicKeyChanged(hash: String)

        var errorDescription: String? {
            switch self {
            case .publicKeyChanged:
                return "This person's key does not match the one you met them with. The directory may have been tampered with. Meet in person and add them again before trusting anything from this identity."
            }
        }
    }

    enum Outcome: Equatable {
        /// No pin yet. The caller decides whether this fetch is a trust on
        /// first use moment; the ceremony paths are, a plain lookup is not.
        case firstSeen
        case matches
        case mismatch
    }

    private static let log = Logger(subsystem: "io.github.jasonepage.Seal", category: "keypin")
    private static let storageKey = "seal.keypins.v1"

    // MARK: - Pure core, so it can be tested without a keychain

    static func check(hash: String, publicKey: Data, pins: [String: Data]) -> Outcome {
        guard let pinned = pins[hash] else { return .firstSeen }
        return pinned == publicKey ? .matches : .mismatch
    }

    /// Adds a pin unless one already exists for `hash`. A pin is NEVER
    /// overwritten by this path: the first proven key wins, and replacing it
    /// requires `forget(hash:)`, which only the identity's owner may reach
    /// through the "remove this person" flow.
    static func pinning(hash: String, publicKey: Data, into pins: [String: Data]) -> [String: Data] {
        guard pins[hash] == nil, !publicKey.isEmpty else { return pins }
        var out = pins
        out[hash] = publicKey
        return out
    }

    // MARK: - Keychain-backed API

    static func load() -> [String: Data] {
        guard let data = KeychainStore.load(storageKey),
              let decoded = try? JSONDecoder().decode([String: Data].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func save(_ pins: [String: Data]) {
        if let data = try? JSONEncoder().encode(pins) {
            KeychainStore.save(data, for: storageKey)
        }
    }

    static func pinnedKey(for hash: String) -> Data? { load()[hash] }

    /// Pin a key that has just been PROVEN: a ceremony tap verified against
    /// it, our own registration, or a device signature verified against a
    /// chain rooted in it. Never call this with a key that was merely read
    /// from the directory.
    static func pin(hash: String, publicKey: Data) {
        let before = load()
        let after = pinning(hash: hash, publicKey: publicKey, into: before)
        if after.count != before.count {
            save(after)
            log.info("pinned root key for \(hash.prefix(8), privacy: .public)")
        }
    }

    /// Refuse a directory record whose key disagrees with the pin. First
    /// sight passes through untouched, because a lookup of someone we have
    /// never met has nothing to compare against yet.
    static func enforce(hash: String, publicKey: Data) throws {
        switch check(hash: hash, publicKey: publicKey, pins: load()) {
        case .firstSeen, .matches:
            return
        case .mismatch:
            log.error("REFUSED directory record for \(hash.prefix(8), privacy: .public): public key does not match the pinned key")
            throw PinError.publicKeyChanged(hash: hash)
        }
    }

    /// The one sanctioned way to drop a pin: the owner removes the person.
    static func forget(hash: String) {
        var pins = load()
        guard pins.removeValue(forKey: hash) != nil else { return }
        save(pins)
    }
}
