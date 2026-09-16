// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import CryptoKit

//  EstateKeys.swift
//  Seal
//
//  THE KEY HIERARCHY ABOVE THE EXISTING ONE (conversion brief, section 4).
//
//    Envelope Content Key   random 256 bit, AES-256-GCM, one per envelope
//        listed in
//    Key Table              one per RECIPIENT, encrypted under that table's own
//                           random Key Table Key (KTK)
//        KTK reachable two ways
//        ├─ wrapped directly to the OWNER's devices (owner always reads)
//        └─ encrypted under the Estate Key, THEN wrapped to the recipient's
//           devices (recipient reads only once the Estate Key is released)
//    Estate Key             one per owner per epoch
//        reachable two ways
//        ├─ wrapped directly to the OWNER's devices
//        └─ split by Shamir into N shares, threshold M, each share wrapped
//           to one custodian's devices
//
//  Every wrap here is the hybrid X25519 plus ML-KEM-768 construction in
//  Crypto/KEMBundle.swift, and every AES-GCM call carries a domain-separated
//  AAD naming the estate, the epoch and the purpose, so a ciphertext made for
//  one slot cannot be replayed into another.
//
//  RECIPIENT ISOLATION. A key table is a separate blob per recipient and
//  names its recipient nowhere in the clear. The recipient finds their table
//  by trial-opening every table's release wraps with their own KEM key,
//  exactly the way `HybridKEM.unwrap` already tries every copy. The claiming
//  custodian who recovers the Estate Key holds the INNER key of every table
//  and the OUTER key of none of them, so releasing the estate tells them
//  nothing about envelopes not addressed to them. What the record does leak
//  is the NUMBER of key tables, which is the number of recipients, and the
//  number and size of blobs. That is stated in docs/PRODUCT.md rather than
//  hidden.
//
//  ROTATION. Removing a custodian is a new epoch: fresh Estate Key, new
//  shares, new owner wraps, and the small inner ciphertext of each table's
//  release wrap re-encrypted under the new Estate Key. The tables themselves
//  (under their KTKs) and the media blobs (under content keys) are never
//  touched, which is what keeps rotation cheap however large the estate.

// MARK: - Symmetric helpers

enum EstateCrypto {

    static func randomKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    static func aad(estateID: String, epoch: UInt64, purpose: String) -> Data {
        Data("seal.estate.v1|\(estateID)|\(epoch)|\(purpose)".utf8)
    }

    static func seal(_ plaintext: Data, key: Data, aad: Data) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), authenticating: aad)
        return sealed.combined!
    }

    static func open(_ combined: Data, key: Data, aad: Data) throws -> Data {
        try AES.GCM.open(try AES.GCM.SealedBox(combined: combined), using: SymmetricKey(data: key), authenticating: aad)
    }

    static func sha256Hex(_ data: Data) -> String { Data(SHA256.hash(data: data)).hexString }
}

// MARK: - Key tables

/// One row per envelope addressed to this table's recipient. The whole table
/// is encrypted, so titles and blob references are never in the clear.
struct KeyTableEntry: Codable, Hashable {
    let envelopeID: String
    let contentKey: Data
    let title: String
    /// The owner's reveal order among this recipient's envelopes, lowest first.
    let revealOrder: Int
    /// Blob names in the estate store: the payload blob first, then media.
    let blobIDs: [String]
}

struct KeyTable: Codable, Hashable {
    let recipientHash: String
    var entries: [KeyTableEntry]
}

/// The published form of one recipient's key table.
struct RecipientTableWrap: Codable, Hashable, Identifiable {
    var id: String { tableID }
    /// Random. NOT derived from the recipient, on purpose.
    let tableID: String
    /// The Key Table Key, wrapped straight to the owner's devices.
    let ownerWraps: [HybridWrap.Envelope]
    /// The Key Table Key encrypted under the Estate Key of `epoch`, then
    /// wrapped to the recipient's devices. Rewritten on every epoch.
    let releaseWraps: [HybridWrap.Envelope]
    let epoch: UInt64
    /// The Key Table, encrypted under the Key Table Key.
    let ciphertext: Data
}

// MARK: - Epoch key material

struct CustodianShareWrap: Codable, Hashable {
    let custodianHash: String
    let shareIndex: UInt8
    /// The share (`Shamir.Share.encoded`), wrapped to each custodian device.
    let envelopes: [HybridWrap.Envelope]
    /// SHA-256 of the share's encoded form. Also in the signed record.
    let commitment: Data
}

struct EpochKeyMaterial: Codable, Hashable {
    let estateID: String
    let epoch: UInt64
    let threshold: Int
    /// Estate Key wrapped to the owner's devices.
    let ownerWraps: [HybridWrap.Envelope]
    let custodianShares: [CustodianShareWrap]
    /// SHA-256 of the Estate Key itself, so a recovered key can be checked
    /// before anything is decrypted with it.
    let estateKeyCommitment: Data

    var custodianCount: Int { custodianShares.count }
}

enum EstateKeyError: Error, Equatable {
    case noOwnerDevices
    case noCustodianDevices(String)
    case badThreshold
    case notMyShare
    case badShare(custodianHash: String)
    case notEnoughShares(have: Int, need: Int)
    case recoveredKeyMismatch
    case tableNotForMe
}

// MARK: - The hierarchy

enum EstateKeyHierarchy {

    struct Custodian {
        let hash: String
        let kemBundles: [Data]
    }

    private static let purposeEstateKeyOwner = "estatekey.owner"
    private static let purposeShare = "share"
    private static let purposeTable = "table"
    private static let purposeTableKeyOwner = "tablekey.owner"
    private static let purposeTableKeyInner = "tablekey.inner"
    private static let purposeTableKeyRelease = "tablekey.release"

    // MARK: Epoch

    /// Builds everything the release path needs for one epoch. The Estate
    /// Key is returned to the caller for the owner's own use in this
    /// session; it is never stored in the clear.
    static func makeEpoch(estateID: String,
                          epoch: UInt64,
                          estateKey: Data,
                          ownerBundles: [Data],
                          custodians: [Custodian],
                          threshold: Int) throws -> EpochKeyMaterial {
        guard threshold >= 1, threshold <= custodians.count else { throw EstateKeyError.badThreshold }
        guard let ownerWraps = try? HybridWrap.wrapToAll(
            estateKey, to: ownerBundles,
            aad: EstateCrypto.aad(estateID: estateID, epoch: epoch, purpose: purposeEstateKeyOwner))
        else { throw EstateKeyError.noOwnerDevices }

        let shares = try Shamir.split(secret: estateKey, threshold: threshold, shares: custodians.count)
        var wrapped: [CustodianShareWrap] = []
        for (share, custodian) in zip(shares, custodians) {
            let aad = EstateCrypto.aad(estateID: estateID, epoch: epoch,
                                       purpose: "\(purposeShare).\(share.index)")
            guard let envelopes = try? HybridWrap.wrapToAll(share.encoded, to: custodian.kemBundles, aad: aad) else {
                throw EstateKeyError.noCustodianDevices(custodian.hash)
            }
            wrapped.append(CustodianShareWrap(custodianHash: custodian.hash,
                                              shareIndex: share.index,
                                              envelopes: envelopes,
                                              commitment: share.commitment))
        }
        return EpochKeyMaterial(estateID: estateID,
                                epoch: epoch,
                                threshold: threshold,
                                ownerWraps: ownerWraps,
                                custodianShares: wrapped,
                                estateKeyCommitment: Data(SHA256.hash(data: estateKey)))
    }

    static func openEstateKeyAsOwner(_ material: EpochKeyMaterial, mine: KEMPrivateBundle) throws -> Data {
        let aad = EstateCrypto.aad(estateID: material.estateID, epoch: material.epoch, purpose: purposeEstateKeyOwner)
        let key = try HybridWrap.openAny(material.ownerWraps, with: mine, aad: aad)
        guard Data(SHA256.hash(data: key)) == material.estateKeyCommitment else {
            throw EstateKeyError.recoveredKeyMismatch
        }
        return key
    }

    /// A custodian opens their own share. `custodianHash` selects the slot;
    /// the commitment is checked so a corrupted copy is caught on the
    /// custodian's own phone, before it is ever submitted.
    static func openMyShare(_ material: EpochKeyMaterial, custodianHash: String, mine: KEMPrivateBundle) throws -> Shamir.Share {
        guard let slot = material.custodianShares.first(where: { $0.custodianHash == custodianHash }) else {
            throw EstateKeyError.notMyShare
        }
        let aad = EstateCrypto.aad(estateID: material.estateID, epoch: material.epoch,
                                   purpose: "\(purposeShare).\(slot.shareIndex)")
        let encoded = try HybridWrap.openAny(slot.envelopes, with: mine, aad: aad)
        guard let share = Shamir.Share(encoded: encoded),
              share.index == slot.shareIndex,
              share.commitment == slot.commitment else {
            throw EstateKeyError.badShare(custodianHash: custodianHash)
        }
        return share
    }

    /// Checks every submitted share against its commitment FIRST, so the
    /// error names the custodian whose share is bad instead of the combine
    /// producing garbage. Then combines and checks the result against the
    /// Estate Key commitment.
    static func recoverEstateKey(_ material: EpochKeyMaterial, submitted: [Shamir.Share]) throws -> Data {
        var good: [Shamir.Share] = []
        for share in submitted {
            guard let slot = material.custodianShares.first(where: { $0.shareIndex == share.index }) else {
                throw EstateKeyError.badShare(custodianHash: "unknown share index \(share.index)")
            }
            guard share.commitment == slot.commitment else {
                throw EstateKeyError.badShare(custodianHash: slot.custodianHash)
            }
            if !good.contains(where: { $0.index == share.index }) { good.append(share) }
        }
        guard good.count >= material.threshold else {
            throw EstateKeyError.notEnoughShares(have: good.count, need: material.threshold)
        }
        let key = try Shamir.combine(good, threshold: material.threshold)
        guard Data(SHA256.hash(data: key)) == material.estateKeyCommitment else {
            throw EstateKeyError.recoveredKeyMismatch
        }
        return key
    }

    // MARK: Key tables

    static func wrapTable(_ table: KeyTable,
                          tableID: String,
                          tableKey: Data,
                          estateID: String,
                          epoch: UInt64,
                          estateKey: Data,
                          ownerBundles: [Data],
                          recipientBundles: [Data]) throws -> RecipientTableWrap {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plaintext = try encoder.encode(table)
        let ciphertext = try EstateCrypto.seal(
            plaintext, key: tableKey,
            aad: EstateCrypto.aad(estateID: estateID, epoch: 0, purpose: "\(purposeTable).\(tableID)"))
        guard let ownerWraps = try? HybridWrap.wrapToAll(
            tableKey, to: ownerBundles,
            aad: EstateCrypto.aad(estateID: estateID, epoch: 0, purpose: "\(purposeTableKeyOwner).\(tableID)"))
        else { throw EstateKeyError.noOwnerDevices }
        let releaseWraps = try releaseWraps(tableID: tableID, tableKey: tableKey, estateID: estateID,
                                            epoch: epoch, estateKey: estateKey, recipientBundles: recipientBundles)
        return RecipientTableWrap(tableID: tableID, ownerWraps: ownerWraps, releaseWraps: releaseWraps,
                                  epoch: epoch, ciphertext: ciphertext)
    }

    /// The part of a table wrap that changes with the epoch.
    static func releaseWraps(tableID: String,
                             tableKey: Data,
                             estateID: String,
                             epoch: UInt64,
                             estateKey: Data,
                             recipientBundles: [Data]) throws -> [HybridWrap.Envelope] {
        let inner = try EstateCrypto.seal(
            tableKey, key: estateKey,
            aad: EstateCrypto.aad(estateID: estateID, epoch: epoch, purpose: "\(purposeTableKeyInner).\(tableID)"))
        guard let wraps = try? HybridWrap.wrapToAll(
            inner, to: recipientBundles,
            aad: EstateCrypto.aad(estateID: estateID, epoch: epoch, purpose: "\(purposeTableKeyRelease).\(tableID)"))
        else { throw EstateKeyError.noCustodianDevices("recipient") }
        return wraps
    }

    static func rewrap(_ wrap: RecipientTableWrap,
                       tableKey: Data,
                       estateID: String,
                       newEpoch: UInt64,
                       newEstateKey: Data,
                       recipientBundles: [Data]) throws -> RecipientTableWrap {
        let wraps = try releaseWraps(tableID: wrap.tableID, tableKey: tableKey, estateID: estateID,
                                     epoch: newEpoch, estateKey: newEstateKey, recipientBundles: recipientBundles)
        return RecipientTableWrap(tableID: wrap.tableID, ownerWraps: wrap.ownerWraps,
                                  releaseWraps: wraps, epoch: newEpoch, ciphertext: wrap.ciphertext)
    }

    static func openTableKeyAsOwner(_ wrap: RecipientTableWrap, estateID: String, mine: KEMPrivateBundle) throws -> Data {
        try HybridWrap.openAny(
            wrap.ownerWraps, with: mine,
            aad: EstateCrypto.aad(estateID: estateID, epoch: 0, purpose: "\(purposeTableKeyOwner).\(wrap.tableID)"))
    }

    /// A recipient opens a table after release: outer layer with their own
    /// KEM key, inner layer with the released Estate Key. Throws
    /// `tableNotForMe` on a table addressed to someone else, which is the
    /// normal case while trial-opening.
    static func openTableKeyAsRecipient(_ wrap: RecipientTableWrap, estateID: String,
                                        estateKey: Data, mine: KEMPrivateBundle) throws -> Data {
        guard let inner = try? HybridWrap.openAny(
            wrap.releaseWraps, with: mine,
            aad: EstateCrypto.aad(estateID: estateID, epoch: wrap.epoch, purpose: "\(purposeTableKeyRelease).\(wrap.tableID)"))
        else { throw EstateKeyError.tableNotForMe }
        return try EstateCrypto.open(
            inner, key: estateKey,
            aad: EstateCrypto.aad(estateID: estateID, epoch: wrap.epoch, purpose: "\(purposeTableKeyInner).\(wrap.tableID)"))
    }

    static func openTable(_ wrap: RecipientTableWrap, estateID: String, tableKey: Data) throws -> KeyTable {
        let plaintext = try EstateCrypto.open(
            wrap.ciphertext, key: tableKey,
            aad: EstateCrypto.aad(estateID: estateID, epoch: 0, purpose: "\(purposeTable).\(wrap.tableID)"))
        return try JSONDecoder().decode(KeyTable.self, from: plaintext)
    }

    // MARK: Envelope content

    static func sealContent(_ plaintext: Data, contentKey: Data, estateID: String, blobID: String) throws -> Data {
        try EstateCrypto.seal(plaintext, key: contentKey,
                              aad: EstateCrypto.aad(estateID: estateID, epoch: 0, purpose: "blob.\(blobID)"))
    }

    static func openContent(_ ciphertext: Data, contentKey: Data, estateID: String, blobID: String) throws -> Data {
        try EstateCrypto.open(ciphertext, key: contentKey,
                              aad: EstateCrypto.aad(estateID: estateID, epoch: 0, purpose: "blob.\(blobID)"))
    }
}
