// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//  tools/vectors/main.swift
//
//  WRITES THE TEST VECTORS THE WEB PAGE HAS TO MATCH (PRODUCT.md section 15).
//
//  The browser is a second implementation of Seal's crypto. It is only safe
//  if it opens exactly what the phone seals, byte for byte. So this compiles
//  the app's own source files (nothing copied, nothing reimplemented), makes
//  real wraps, tables, shares and locked blobs with them, and prints JSON:
//  every input the browser will have, and every output it must reach.
//  tools/vectors/check.mjs then runs the browser's crypto (WebCrypto plus
//  one ML-KEM library) against that file.
//
//  Set 1, this file: what the recipient page (1.2a) needs to open an
//  envelope with a sponsored key, plus the key split for 1.2b.
//  Not yet: event signing bytes, endorsement checks, the release judgment
//  and the envelope payload schema. Those need more of the app to compile
//  on its own first (section 15, "Vectors, set 2").
//
//  Run:  sh tools/export_vectors.sh
//  The output is random each run (fresh keys, fresh nonces). That is fine:
//  the browser must OPEN these, not reproduce them. Commit one run.

import Foundation
import CryptoKit

// MARK: - Output helpers

func hex(_ d: Data) -> String { d.hexString }
func b64(_ d: Data) -> String { d.base64EncodedString() }
func utf8(_ s: String) -> Data { Data(s.utf8) }

/// The exact bytes the app writes for a Codable value, base64, so the
/// browser parses the real format and not a re-spelled one.
func stored<T: Encodable>(_ value: T, sorted: Bool = false) throws -> String {
    let e = JSONEncoder()
    if sorted { e.outputFormatting = [.sortedKeys] }
    return b64(try e.encode(value))
}

func privateBundle(_ b: KEMPrivateBundle) -> [String: Any] {
    var out: [String: Any] = ["x25519": hex(b.x25519.rawRepresentation),
                              "publicBundle": hex(b.publicBundle.encoded)]
    if let seed = b.mlkem768Seed { out["mlkem768Seed"] = hex(seed) }
    return out
}

func freshBundle(hybrid: Bool) -> KEMPrivateBundle {
    KEMPrivateBundle(x25519: Curve25519.KeyAgreement.PrivateKey(),
                     mlkem768Seed: hybrid ? KEMPrivateBundle.newMLKEMSeed() : nil)
}

func fail(_ why: String) -> Never {
    FileHandle.standardError.write(Data("vectors: \(why)\n".utf8))
    exit(1)
}

var root: [String: Any] = [
    "set": 1,
    "made": ISO8601DateFormatter().string(from: Date()),
    "notes": [
        "Bytes are lowercase hex unless the key ends in Base64, which is standard base64 of the exact bytes the app stores.",
        "AES-GCM ciphertexts are CryptoKit combined form: 12 byte nonce, then ciphertext, then 16 byte tag.",
        "Every case was opened again with the Swift code before it was written here.",
    ],
]

// MARK: - 1. AAD strings

let aadCases: [(String, UInt64, String)] = [
    ("E1A2B3C4-0000-4000-8000-000000000001", 0, "table.T1"),
    ("E1A2B3C4-0000-4000-8000-000000000001", 3, "tablekey.release.T1"),
    ("E1A2B3C4-0000-4000-8000-000000000001", 18446744073709551615, "share.255"),
    ("é unicode estate", 1, "blob.ä"),
]
root["aad"] = aadCases.map { c -> [String: String] in
    ["estateID": c.0, "epoch": String(c.1), "purpose": c.2,
     "bytes": hex(EstateCrypto.aad(estateID: c.0, epoch: c.1, purpose: c.2))]
}

// MARK: - 2. ML-KEM-768 on its own

guard #available(macOS 26.0, iOS 26.0, *) else { fail("ML-KEM-768 needs macOS 26 or later to run this") }
do {
    guard let seed = KEMPrivateBundle.newMLKEMSeed() else { fail("no ML-KEM seed") }
    let priv = try MLKEM768.PrivateKey(seedRepresentation: seed, publicKey: nil)
    let result = try priv.publicKey.encapsulate()
    let again = try priv.decapsulate(result.encapsulated)
    let ss = result.sharedSecret.withUnsafeBytes { Data($0) }
    guard again.withUnsafeBytes({ Data($0) }) == ss else { fail("ML-KEM round trip") }
    root["mlkem768"] = [
        "seed": hex(seed),
        "seedLength": seed.count,
        "publicKey": hex(priv.publicKey.rawRepresentation),
        "ciphertext": hex(result.encapsulated),
        "sharedSecret": hex(ss),
    ] as [String: Any]
}

// MARK: - 3. KEM bundle encoding

do {
    let b = freshBundle(hybrid: true)
    let enc = b.publicBundle.encoded
    guard let parsed = KEMBundle.parse(enc), parsed.isHybrid else { fail("bundle parse") }
    let classical = freshBundle(hybrid: false).publicBundle.encoded
    root["kemBundle"] = [
        "hybrid": ["encoded": hex(enc), "x25519": hex(parsed.x25519), "mlkem768": hex(parsed.mlkem768!)] as [String: Any],
        "classical": ["encoded": hex(classical), "x25519": hex(classical)] as [String: Any],
        "rules": "32 bytes is a bare X25519 key. 4+32+1184 bytes starting with ascii SKB1 is hybrid. Anything else is skipped.",
    ] as [String: Any]
}

// MARK: - 4. Hybrid wrap, both suites, opened with the private half

var wrapCases: [[String: Any]] = []
for hybrid in [true, false] {
    let me = freshBundle(hybrid: hybrid)
    let secret = EstateCrypto.randomKey()
    let aad = utf8("seal.vectors.wrap|\(hybrid ? "hybrid" : "classical")")
    // Wrap to two devices, mine second, so the page has to try each copy.
    let other = freshBundle(hybrid: true)
    let envs = try HybridWrap.wrapToAll(secret, to: [other.publicBundle.encoded, me.publicBundle.encoded], aad: aad)
    guard try HybridWrap.openAny(envs, with: me, aad: aad) == secret else { fail("wrap round trip") }
    wrapCases.append([
        "suite": hybrid ? HybridWrap.hybridSuite : HybridWrap.classicalSuite,
        "mine": privateBundle(me),
        "aad": hex(aad),
        "envelopesBase64": try stored(envs),
        "secret": hex(secret),
        "mustFailWithAad": hex(utf8("seal.vectors.wrap|wrong")),
    ])
}
root["hybridWrap"] = wrapCases

// MARK: - 5. Sponsored key: the locked virtual device

let sponsoredHalves = SponsoredKey.makeHalves()
guard let sponsoredKEM = sponsoredHalves.kemBundle else { fail("sponsored halves") }
do {
    let prf = SymmetricKey(size: .bits256)
    let salt = SponsoredKey.randomSalt()
    let locked = try SponsoredKey.lock(sponsoredHalves, prf: prf, salt: salt)
    guard try SponsoredKey.unlock(locked, prf: prf, salt: salt) == sponsoredHalves else { fail("sponsored unlock") }
    let parts = try SponsoredKey.publicParts(of: sponsoredHalves)
    root["sponsored"] = [
        "prfOutput": hex(prf.withUnsafeBytes { Data($0) }),
        "prfSalt": hex(salt),
        "hkdfInfo": hex(SponsoredKey.hkdfInfo),
        "aad": hex(SponsoredKey.aad),
        "lockKey": hex(SponsoredKey.lockKey(prf: prf, salt: salt).withUnsafeBytes { Data($0) }),
        "lockedPrivate": hex(locked),
        "halves": ["signingKey": hex(sponsoredHalves.signingKey),
                   "x25519": hex(sponsoredHalves.x25519),
                   "mlkem768Seed": sponsoredHalves.mlkem768Seed.map { hex($0) as Any } ?? NSNull()] as [String: Any],
        "devicePublicKeyX963": hex(parts.devicePublicKey),
        "kemBundle": hex(parts.kemBundle),
        "note": "prfOutput is what the key returns for prfSalt. Proving a browser gets the same output as the iPhone for the same key and salt needs a real key on both; see section 15.",
    ] as [String: Any]
}

// MARK: - 6. A small estate, opened as the sponsored recipient

do {
    let estateID = UUID().uuidString
    let epoch: UInt64 = 2
    let estateKey = EstateCrypto.randomKey()
    let owner = freshBundle(hybrid: true)
    let custodians = (0..<3).map { _ in freshBundle(hybrid: true) }
    let custodianList = custodians.enumerated().map { i, b in
        EstateKeyHierarchy.Custodian(hash: "custodian-\(i)", kemBundles: [b.publicBundle.encoded])
    }
    let material = try EstateKeyHierarchy.makeEpoch(estateID: estateID, epoch: epoch, estateKey: estateKey,
                                                    ownerBundles: [owner.publicBundle.encoded],
                                                    custodians: custodianList, threshold: 2)

    // Each key holder opens their own share; two of them rebuild the key.
    var openedShares: [[String: Any]] = []
    var shares: [Shamir.Share] = []
    for (i, c) in custodians.enumerated() {
        let share = try EstateKeyHierarchy.openMyShare(material, custodianHash: "custodian-\(i)", mine: c)
        shares.append(share)
        openedShares.append(["custodianHash": "custodian-\(i)", "mine": privateBundle(c),
                             "shareEncoded": hex(share.encoded), "commitment": hex(share.commitment)])
    }
    guard try EstateKeyHierarchy.recoverEstateKey(material, submitted: [shares[0], shares[2]]) == estateKey else {
        fail("estate key recovery")
    }

    // Two key tables: one for the sponsored recipient, one for somebody else.
    let contentKey = EstateCrypto.randomKey()
    let payloadBlobID = UUID().uuidString
    let payloadPlain = utf8("{\"title\":\"For Ana\",\"letter\":\"The key to the shed is under the blue pot.\"}")
    let payloadBlob = try EstateKeyHierarchy.sealContent(payloadPlain, contentKey: contentKey,
                                                         estateID: estateID, blobID: payloadBlobID)
    let table = KeyTable(recipientHash: "recipient-ana", entries: [
        KeyTableEntry(envelopeID: UUID().uuidString, contentKey: contentKey, title: "For Ana",
                      revealOrder: 0, blobIDs: [payloadBlobID]),
    ])
    let mineID = UUID().uuidString
    let mineWrap = try EstateKeyHierarchy.wrapTable(table, tableID: mineID, tableKey: EstateCrypto.randomKey(),
                                                    estateID: estateID, epoch: epoch, estateKey: estateKey,
                                                    ownerBundles: [owner.publicBundle.encoded],
                                                    recipientBundles: [sponsoredKEM.publicBundle.encoded])
    let someoneElse = freshBundle(hybrid: true)
    let otherTable = KeyTable(recipientHash: "recipient-other", entries: [])
    let otherWrap = try EstateKeyHierarchy.wrapTable(otherTable, tableID: UUID().uuidString, tableKey: EstateCrypto.randomKey(),
                                                     estateID: estateID, epoch: epoch, estateKey: estateKey,
                                                     ownerBundles: [owner.publicBundle.encoded],
                                                     recipientBundles: [someoneElse.publicBundle.encoded])

    // Open it the way EstateEngine does, so the vector is known good.
    let tk = try EstateKeyHierarchy.openTableKeyAsRecipient(mineWrap, estateID: estateID, estateKey: estateKey, mine: sponsoredKEM)
    let opened = try EstateKeyHierarchy.openTable(mineWrap, estateID: estateID, tableKey: tk)
    guard opened == table else { fail("table round trip") }
    guard (try? EstateKeyHierarchy.openTableKeyAsRecipient(otherWrap, estateID: estateID, estateKey: estateKey, mine: sponsoredKEM)) == nil else {
        fail("someone else's table opened")
    }
    guard try EstateKeyHierarchy.openContent(payloadBlob, contentKey: contentKey, estateID: estateID, blobID: payloadBlobID) == payloadPlain else {
        fail("content round trip")
    }

    root["estate"] = [
        "estateID": estateID,
        "epoch": String(epoch),
        "estateKey": hex(estateKey),
        "estateKeyCommitment": hex(material.estateKeyCommitment),
        "threshold": material.threshold,
        "epochKeyMaterialBase64": try stored(material),
        "custodians": openedShares,
        "recoverWith": [0, 2],
        "recipient": "the sponsored halves above (section 5)",
        "tables": [
            ["tableID": mineID, "isMine": true, "wrapBase64": try stored(mineWrap),
             "tableKey": hex(tk), "tablePlainBase64": try stored(table, sorted: true)] as [String: Any],
            ["tableID": otherWrap.tableID, "isMine": false, "wrapBase64": try stored(otherWrap)] as [String: Any],
        ] as [[String: Any]],
        "content": ["blobID": payloadBlobID, "blob": hex(payloadBlob), "plaintext": hex(payloadPlain),
                    "note": "The plaintext here is a stand-in. The real payload schema (Envelope.Payload) is in set 2."] as [String: Any],
    ] as [String: Any]
}

// MARK: - Write

let json = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(json)
FileHandle.standardOutput.write(Data("\n".utf8))
