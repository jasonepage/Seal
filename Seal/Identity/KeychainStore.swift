// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Security
import os

/// Tiny keychain wrapper for the Secure Enclave key's encrypted representation
/// and other small secrets. This-device-only, available after first unlock.
///
/// WRITES NEVER DELETE FIRST (audit, medium). `save` used to delete the old
/// item and then add the new one, ignoring both results, so a write that
/// failed (a locked phone before first unlock, a full keychain) left NOTHING
/// behind: an identity, an estate's whole log, gone, and nobody told. Now the
/// item is updated in place, added only if it does not exist yet, the old
/// value stays put if the write fails, and the failure is logged and posted
/// (`writeFailed`) so the app can say so.
enum KeychainStore {
    private static let service = "chat.seal.keychain"
    private static let log = Logger(subsystem: "io.github.jasonepage.Seal", category: "keychain")

    /// Posted when a write fails. ContentView tells the person.
    static let writeFailed = Notification.Name("seal.keychain.writeFailed")

    struct WriteError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "This phone's keychain refused the write (status \(status))." }
    }

    private static func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    /// Stores `data` under `key`. The old value is replaced only once the
    /// new one is written; on failure it is untouched and this throws.
    static func write(_ data: Data, for key: String) throws {
        let query = baseQuery(key)
        let changes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes.merge(changes) { _, new in new }
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw WriteError(status: status) }
    }

    /// The entry point the app's ~40 small stores use. Same as `write`, but a
    /// failure is logged and posted instead of thrown, because none of those
    /// callers can do better than tell the person. Returns whether it stuck.
    @discardableResult
    static func save(_ data: Data, for key: String) -> Bool {
        do {
            try write(data, for: key)
            return true
        } catch {
            let status = (error as? WriteError)?.status ?? errSecParam
            log.error("keychain: write failed, status \(status, privacy: .public), item \(key, privacy: .private)")
            NotificationCenter.default.post(name: writeFailed, object: nil, userInfo: ["status": Int(status)])
            return false
        }
    }

    static func load(_ key: String) -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status != errSecSuccess && status != errSecItemNotFound {
            // Not found is normal. Anything else means something is there
            // that this launch cannot read, which is worth a log line.
            log.error("keychain: read failed, status \(status, privacy: .public), item \(key, privacy: .private)")
        }
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(_ key: String) {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            log.error("keychain: delete failed, status \(status, privacy: .public), item \(key, privacy: .private)")
        }
    }
}
