import Foundation

//  DeletedIdentityLedger.swift
//  Seal
//
//  THE LOCAL GRAVEYARD. Every identity this phone has permanently deleted,
//  by credential hash, kept in the keychain under one GLOBAL key.
//
//  Why it exists. Deletion writes a write-once tombstone record to CloudKit
//  and flips the live record's tier. Both are authoritative on the server,
//  but the directory SCAN that feeds registration's exclusion list and the
//  sign-in allow lists is a CloudKit QUERY, and query indexes lag writes by
//  seconds to minutes. In that window the phone that just deleted an
//  identity still sees its credential as live, refuses to register ("this
//  key already holds a Seal identity"), and offers the dead passkey in the
//  Face ID picker. This list closes that window for the one phone that
//  cannot be confused about what it just did.
//
//  Deliberately NOT namespaced by identity and NOT wiped by sign-out or
//  delete (ContentView.wipeLocalAndEngines): a graveyard that empties
//  itself is no graveyard. It is a list of hashes, nothing secret.
enum DeletedIdentityLedger {
    private static let key = "seal.deletedIdentities"

    static func all() -> Set<String> {
        guard let data = KeychainStore.load(key),
              let hashes = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(hashes)
    }

    static func contains(_ credentialIDHash: String) -> Bool {
        all().contains(credentialIDHash)
    }

    static func add(_ credentialIDHash: String) {
        var set = all()
        set.insert(credentialIDHash)
        if let data = try? JSONEncoder().encode(Array(set).sorted()) {
            KeychainStore.save(data, for: key)
        }
    }
}
