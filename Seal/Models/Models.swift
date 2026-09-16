// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Identity tier per SRS FR-21.
enum IdentityTier: String, Codable {
    case verified   // FIDO2 hardware key
    case passkey    // platform passkey (Face ID)
}

/// A user's root identity: their WebAuthn credential public key.
struct RootIdentity: Codable, Identifiable, Hashable {
    var id: String { credentialIDHash }
    let credentialIDHash: String        // record name in the public DB
    let publicKey: Data                 // P-256, raw representation
    let tier: IdentityTier
    var displayName: String
    /// Raw WebAuthn credential ID, needed to request assertions from this
    /// identity's authenticator (friend ceremony). Public, not secret.
    var rawCredentialID: Data?
    /// Backup credentials this root has endorsed (FR-3, `seal.backup.v1`, 
    /// see BackupCredential.swift), as published in the directory and already
    /// signature-checked and revocation-filtered by `SyncEngine.fetchIdentity`.
    ///
    /// It lives ON the identity rather than beside it so that the AUTHORITY
    /// SET travels wherever the identity does. Every existing consumer of
    /// `IdentityManager.verifiedDevices` (the estate log verifier, the
    /// receipts view) then accepts a device endorsement signed by a backup
    /// key without a single call site changing.
    /// Passing them as a separate argument would have meant five call sites
    /// each remembering to thread them through, and one forgotten thread is a
    /// recovered phone whose messages silently fail to verify.
    ///
    /// Optional with a `nil` default so identities already sitting in the
    /// keychain still decode, and so the memberwise initialiser stays
    /// source-compatible with every existing caller (same reasoning as
    /// `Friendship.autoReciprocated`).
    var backupCredentials: [BackupCredential]? = nil
}

/// The verifiable payload inside Friendship.attestation: enough to recompute
/// the challenge commitment and re-verify the friend's signature at any time.
struct FriendshipAttestation: Codable, Hashable {
    let nonce: Data
    let timestamp: Date
    let assertion: WebAuthnAssertion
}

/// Hardware/passkey-signed certificate binding a device key to a root identity (SDS §2).
///
/// Security fix 3 of 4: this struct used to carry an unsigned `revokedAt`
/// field that `verifiedDevices` treated as authoritative, so anyone able to
/// write an Identity record could un-verify every device on it with no key.
/// The field is GONE from the type. Old JSON that still carries it decodes
/// fine (unknown keys are ignored) and the value is discarded. The only
/// revocation channel is a root-signed `DeviceRevocation`.
struct DeviceEndorsement: Codable, Hashable {
    let devicePublicKey: Data           // Secure Enclave P-256 signing key, x963
    /// KEM public material this device can be wrapped to. For endorsements
    /// created before the estate work this is a raw 32 byte X25519 key. For
    /// v3 endorsements it may be a `KEMBundle` encoding carrying X25519 and
    /// ML-KEM-768 (see Crypto/KEMBundle.swift); `KEMBundle.parse` tells the
    /// two apart by length.
    let kemBundlePublicKeys: Data
    let assertion: Data                 // WebAuthn assertion committing to devicePublicKey
    let createdAt: Date
    /// A SPONSORED KEY'S VIRTUAL DEVICE (Identity/SponsoredKey.swift). The
    /// owner registered this hardware key for somebody who is not on Seal
    /// yet, and this "device" is not a phone: its private keys are here,
    /// locked under a secret only the key itself can compute (the WebAuthn
    /// PRF extension). Whoever holds the key and its PIN can unlock them on
    /// any iPhone. Both nil on an ordinary phone endorsement. Neither is in
    /// the endorsement commitment on purpose: a directory that swapped
    /// `lockedPrivate` would only produce a blob that fails to decrypt.
    var lockedPrivate: Data? = nil
    var prfSalt: Data? = nil

    var isSponsored: Bool { lockedPrivate != nil && prfSalt != nil }
}

/// Root-key-signed revocation of a device (FR-19). Clients treat the device
/// as invalid; its endorsement is dropped from every verification path.
struct DeviceRevocation: Codable, Hashable {
    let devicePublicKey: Data
    let assertion: Data                 // WebAuthnAssertion committing to the device key
    let revokedAt: Date
}

/// Mutual, in-person friendship attestation (SRS FR-5/FR-6).
struct Friendship: Codable, Identifiable, Hashable {
    var id: String { friendRootID }
    let friendRootID: String
    let attestation: Data               // friend's assertion over our challenge
    let reverseAttestation: Data?       // our assertion held by them; both required for invites
    let forgedAt: Date
    /// True when THIS side of the edge was completed automatically from the
    /// other party's ForgeHandshake instead of by a ceremony on this phone.
    /// Such an edge proves the peer's intent, not their physical presence, so
    /// ForgeRank must weight it below a real forge (docs/TRUST.md §5.1) and the
    /// UI should not present it as a full brass ceremony. Optional with a
    /// default so friendships already in the keychain still decode, and so the
    /// memberwise initialiser stays source-compatible with existing callers.
    var autoReciprocated: Bool? = nil
    /// True when this person's key was registered on THIS phone by its
    /// owner and handed over (Identity/SponsoredKey.swift). There was no
    /// ceremony because there was no second phone; the owner held the key.
    var sponsored: Bool? = nil
    /// When this phone found that the person deleted their Seal identity
    /// (a write-once "tomb.<hash>" marker, or the live record flipped to
    /// the deleted tier). Set by FriendStore.refreshGone and never cleared:
    /// a tombstone is forever. nil means not known to be gone. The row
    /// stays, because the name still means something to the owner.
    var tombstonedAt: Date? = nil
    var isGone: Bool { tombstonedAt != nil }
    /// Every friendship is in person now: the remote "introduction" path was
    /// retired with the messenger, and its proof field with it. Old keychain
    /// entries that carried one still decode (the key is ignored).
    var isInPerson: Bool { true }
}

//  A DEFAULT VALUE DOES NOT MAKE A MISSING KEY DECODE (GOTCHAS, and the
//  long note at the bottom of EstateModels.swift). Every Friendship in a
//  keychain today was written without `tombstonedAt`, so the decoder is
//  written by hand and every field added after the first release is read
//  with `decodeIfPresent`. Encoding stays synthesized. In an extension so
//  the memberwise initialiser survives for every existing caller.
extension Friendship {
    private enum Keys: String, CodingKey {
        case friendRootID, attestation, reverseAttestation, forgedAt
        case autoReciprocated, sponsored, tombstonedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        friendRootID = try c.decode(String.self, forKey: .friendRootID)
        attestation = try c.decode(Data.self, forKey: .attestation)
        reverseAttestation = try c.decodeIfPresent(Data.self, forKey: .reverseAttestation)
        forgedAt = try c.decode(Date.self, forKey: .forgedAt)
        autoReciprocated = try c.decodeIfPresent(Bool.self, forKey: .autoReciprocated)
        sponsored = try c.decodeIfPresent(Bool.self, forKey: .sponsored)
        tombstonedAt = try c.decodeIfPresent(Date.self, forKey: .tombstonedAt)
    }
}
