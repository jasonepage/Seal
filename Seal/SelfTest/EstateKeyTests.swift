import Foundation
import CryptoKit

//  EstateKeyTests.swift
//  Seal
//
//  The hierarchy in Estate/EstateKeys.swift, end to end, with real hybrid
//  wraps. These are the tests that say "the owner always reads, M custodians
//  can release, M-1 cannot, a bad share is named, a recipient sees only their
//  own table, and rotation leaves the blobs alone."

enum EstateKeyTests {

    static let suites: [SelfTest.Suite] = [
        .init(name: "estatekeys.hybridWrap", run: hybridWrap),
        .init(name: "estatekeys.epoch", run: epoch),
        .init(name: "estatekeys.tables", run: tables),
        .init(name: "estatekeys.rotation", run: rotation),
    ]

    /// A device with both KEM halves, like a phone that signed in after the
    /// hybrid bundle landed.
    static func hybridDevice() -> KEMPrivateBundle {
        KEMPrivateBundle(x25519: Curve25519.KeyAgreement.PrivateKey(),
                         mlkem768Seed: MLKEM768.PrivateKey().seedRepresentation)
    }

    /// A device with only X25519, like a phone that has not signed in since.
    static func legacyDevice() -> KEMPrivateBundle {
        KEMPrivateBundle(x25519: Curve25519.KeyAgreement.PrivateKey(), mlkem768Seed: nil)
    }

    static func hybridWrap(_ t: SelfTest.Context) throws {
        let secret = EstateCrypto.randomKey()
        let aad = Data("test".utf8)
        let hybrid = hybridDevice()
        let legacy = legacyDevice()

        let bundle = hybrid.publicBundle
        t.check(bundle.isHybrid, "a device with a lattice seed publishes a hybrid bundle")
        t.equal(KEMBundle.parse(bundle.encoded), bundle, "hybrid bundle round-trips through its encoding")
        t.equal(KEMBundle.parse(legacy.publicBundle.encoded), legacy.publicBundle, "legacy bundle round-trips")
        t.check(KEMBundle.parse(Data(repeating: 1, count: 33)) == nil, "an odd length is not a bundle")

        let env = try HybridWrap.wrap(secret, to: bundle, aad: aad)
        t.equal(env.suite, HybridWrap.hybridSuite, "hybrid suite recorded")
        t.equal(env.mlkemCiphertext?.count, KEMBundle.mlkem768CiphertextLength, "ML-KEM-768 ciphertext length")
        t.equal(try HybridWrap.open(env, with: hybrid, aad: aad), secret, "hybrid wrap opens")
        t.throwsError("wrong AAD is refused") { _ = try HybridWrap.open(env, with: hybrid, aad: Data("other".utf8)) }
        t.throwsError("another device cannot open it") { _ = try HybridWrap.open(env, with: hybridDevice(), aad: aad) }

        let classical = try HybridWrap.wrap(secret, to: legacy.publicBundle, aad: aad)
        t.equal(classical.suite, HybridWrap.classicalSuite, "legacy recipient gets the classical suite, and it says so")
        t.equal(try HybridWrap.open(classical, with: legacy, aad: aad), secret, "classical wrap opens")

        let all = try HybridWrap.wrapToAll(secret, to: [bundle.encoded, legacy.publicBundle.encoded, Data()], aad: aad)
        t.equal(all.count, 2, "wrapToAll skips empty keys and wraps the rest")
        t.equal(try HybridWrap.openAny(all, with: legacy, aad: aad), secret, "openAny finds our copy")
    }

    static func epoch(_ t: SelfTest.Context) throws {
        let estateID = UUID().uuidString
        let estateKey = EstateCrypto.randomKey()
        let ownerPhone = hybridDevice()
        let custodianDevices = (0..<3).map { _ in hybridDevice() }
        let custodians = custodianDevices.enumerated().map {
            EstateKeyHierarchy.Custodian(hash: "custodian\($0.offset)", kemBundles: [$0.element.publicBundle.encoded])
        }
        let material = try EstateKeyHierarchy.makeEpoch(estateID: estateID, epoch: 1, estateKey: estateKey,
                                                        ownerBundles: [ownerPhone.publicBundle.encoded],
                                                        custodians: custodians, threshold: 2)
        t.equal(material.custodianCount, 3, "three custodian slots")
        t.equal(try EstateKeyHierarchy.openEstateKeyAsOwner(material, mine: ownerPhone), estateKey, "the owner always reads")
        t.throwsError("a custodian cannot open the owner wrap") {
            _ = try EstateKeyHierarchy.openEstateKeyAsOwner(material, mine: custodianDevices[0])
        }

        var shares: [Shamir.Share] = []
        for (i, device) in custodianDevices.enumerated() {
            shares.append(try EstateKeyHierarchy.openMyShare(material, custodianHash: "custodian\(i)", mine: device))
        }
        t.throwsError("a custodian cannot open somebody else's share") {
            _ = try EstateKeyHierarchy.openMyShare(material, custodianHash: "custodian1", mine: custodianDevices[0])
        }
        t.equal(try EstateKeyHierarchy.recoverEstateKey(material, submitted: [shares[0], shares[2]]), estateKey,
                "two of three custodians recover the Estate Key")
        t.throwsError("one of three cannot") {
            _ = try EstateKeyHierarchy.recoverEstateKey(material, submitted: [shares[1]])
        }
        // A bad share is NAMED, not silently combined.
        var corrupt = shares[1].bytes; corrupt[0] ^= 0xFF
        let bad = Shamir.Share(index: shares[1].index, bytes: corrupt)
        do {
            _ = try EstateKeyHierarchy.recoverEstateKey(material, submitted: [shares[0], bad])
            t.fail("a corrupt share was accepted")
        } catch EstateKeyError.badShare(let who) {
            t.equal(who, "custodian1", "the corrupt share is attributed to its custodian")
        } catch {
            t.fail("wrong error for a corrupt share", "\(error)")
        }
        t.throwsError("threshold above custodian count is refused") {
            _ = try EstateKeyHierarchy.makeEpoch(estateID: estateID, epoch: 1, estateKey: estateKey,
                                                 ownerBundles: [ownerPhone.publicBundle.encoded],
                                                 custodians: custodians, threshold: 4)
        }
    }

    static func tables(_ t: SelfTest.Context) throws {
        let estateID = UUID().uuidString
        let estateKey = EstateCrypto.randomKey()
        let owner = hybridDevice()
        let wife = hybridDevice()
        let partner = legacyDevice()
        let contentKey = EstateCrypto.randomKey()
        let table = KeyTable(recipientHash: "wife", entries: [
            KeyTableEntry(envelopeID: "e1", contentKey: contentKey, title: "Every password", revealOrder: 1, blobIDs: ["b1"])
        ])
        let tableKey = EstateCrypto.randomKey()
        let wrap = try EstateKeyHierarchy.wrapTable(table, tableID: "t-wife", tableKey: tableKey, estateID: estateID,
                                                    epoch: 1, estateKey: estateKey,
                                                    ownerBundles: [owner.publicBundle.encoded],
                                                    recipientBundles: [wife.publicBundle.encoded])
        // Owner path.
        let ownerKey = try EstateKeyHierarchy.openTableKeyAsOwner(wrap, estateID: estateID, mine: owner)
        t.equal(try EstateKeyHierarchy.openTable(wrap, estateID: estateID, tableKey: ownerKey), table, "owner opens the table")
        // Recipient before release: has the outer key, not the Estate Key.
        t.throwsError("recipient cannot open before release") {
            _ = try EstateKeyHierarchy.openTableKeyAsRecipient(wrap, estateID: estateID, estateKey: EstateCrypto.randomKey(), mine: wife)
        }
        // Recipient after release.
        let released = try EstateKeyHierarchy.openTableKeyAsRecipient(wrap, estateID: estateID, estateKey: estateKey, mine: wife)
        t.equal(try EstateKeyHierarchy.openTable(wrap, estateID: estateID, tableKey: released), table, "recipient opens after release")
        // Somebody else holding the released Estate Key: isolation.
        do {
            _ = try EstateKeyHierarchy.openTableKeyAsRecipient(wrap, estateID: estateID, estateKey: estateKey, mine: partner)
            t.fail("another person opened a table not addressed to them")
        } catch EstateKeyError.tableNotForMe {
            t.check(true, "a table not addressed to me is tableNotForMe")
        } catch {
            t.fail("wrong error for isolation", "\(error)")
        }
        // Nothing in the wrap names the recipient.
        let encoded = try JSONEncoder().encode(wrap)
        t.check(!String(decoding: encoded, as: UTF8.self).contains("wife"), "the published table wrap never names its recipient")
        // Content.
        let letter = Data("Dear you".utf8)
        let sealed = try EstateKeyHierarchy.sealContent(letter, contentKey: contentKey, estateID: estateID, blobID: "b1")
        t.equal(try EstateKeyHierarchy.openContent(sealed, contentKey: contentKey, estateID: estateID, blobID: "b1"), letter, "content round trips")
        t.throwsError("content bound to its blob id") {
            _ = try EstateKeyHierarchy.openContent(sealed, contentKey: contentKey, estateID: estateID, blobID: "b2")
        }
    }

    static func rotation(_ t: SelfTest.Context) throws {
        let estateID = UUID().uuidString
        let owner = hybridDevice()
        let wife = hybridDevice()
        let key1 = EstateCrypto.randomKey()
        let key2 = EstateCrypto.randomKey()
        let tableKey = EstateCrypto.randomKey()
        let table = KeyTable(recipientHash: "wife", entries: [])
        let wrap1 = try EstateKeyHierarchy.wrapTable(table, tableID: "t", tableKey: tableKey, estateID: estateID,
                                                     epoch: 1, estateKey: key1,
                                                     ownerBundles: [owner.publicBundle.encoded],
                                                     recipientBundles: [wife.publicBundle.encoded])
        let wrap2 = try EstateKeyHierarchy.rewrap(wrap1, tableKey: tableKey, estateID: estateID, newEpoch: 2,
                                                  newEstateKey: key2, recipientBundles: [wife.publicBundle.encoded])
        t.equal(wrap2.ciphertext, wrap1.ciphertext, "rotation never touches the table ciphertext")
        t.equal(wrap2.ownerWraps, wrap1.ownerWraps, "rotation never touches the owner wraps")
        t.equal(wrap2.epoch, 2, "new epoch recorded")
        t.throwsError("the old Estate Key no longer opens the rotated table") {
            _ = try EstateKeyHierarchy.openTableKeyAsRecipient(wrap2, estateID: estateID, estateKey: key1, mine: wife)
        }
        t.equal(try EstateKeyHierarchy.openTableKeyAsRecipient(wrap2, estateID: estateID, estateKey: key2, mine: wife),
                tableKey, "the new Estate Key opens it")
    }
}
