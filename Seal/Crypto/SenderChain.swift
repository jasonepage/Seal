// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import CryptoKit

/// Per-member, per-group symmetric ratchet (SDS §2).
/// Per-message keys are derived, used once, and the chain advances, 
/// old chain states are discarded for forward secrecy.
struct SenderChain {
    private(set) var chainKey: SymmetricKey
    private(set) var index: UInt64
    let epoch: UInt64

    init(chainKey: SymmetricKey, epoch: UInt64, index: UInt64 = 0) {
        self.chainKey = chainKey
        self.epoch = epoch
        self.index = index
    }

    /// Derive the key for the next message, then ratchet forward.
    mutating func nextMessageKey() -> (key: SymmetricKey, index: UInt64) {
        let messageKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: chainKey,
            info: Data("seal.message".utf8),
            outputByteCount: 32
        )
        let nextChain = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: chainKey,
            info: Data("seal.chain".utf8),
            outputByteCount: 32
        )
        defer { chainKey = nextChain; index += 1 }
        return (messageKey, index)
    }

    /// Seal plaintext with AES-256-GCM; AAD binds group, epoch, and sender (SDS §2).
    static func encrypt(_ plaintext: Data, with key: SymmetricKey, aad: Data) throws -> Data {
        try AES.GCM.seal(plaintext, using: key, authenticating: aad).combined!
    }

    static func decrypt(_ combined: Data, with key: SymmetricKey, aad: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key, authenticating: aad)
    }
}
