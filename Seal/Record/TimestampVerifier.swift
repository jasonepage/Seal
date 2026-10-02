// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import CryptoKit

//  TimestampVerifier.swift
//  Seal
//
//  CHECKING A TIMESTAMP TOKEN ON THE PHONE (audit H2).
//
//  The release feed prefers a timestamp authority's time over the actor's
//  own clock. Before this file it took that time from a byte scan that never
//  checked the authority's signature, so whoever could put bytes in a
//  token field could choose the time: a few bytes holding the event digest
//  and then a date were enough. A heartbeat moved to before a claim no
//  longer stops it, and the owner's veto is gone.
//
//  Now a token's time is believed only when ALL of this holds:
//    1. It is a granted RFC 3161 TimeStampResp, read as DER from the outside
//       in, every length checked against its parent. Nothing is scanned for.
//    2. Its TSTInfo's message imprint is SHA-256 and holds exactly this
//       event's digest, which is what Seal's request asks for.
//    3. Its one SignerInfo's signed attributes name the content a TSTInfo
//       and carry the hash of exactly these TSTInfo bytes.
//    4. The ECDSA signature over those attributes verifies, with CryptoKit
//       alone, under the key of a certificate in the token whose SHA-256 is
//       pinned below. The pin stands in for a chain check: there is one
//       authority. tools/verify_capsule.py still checks chains offline.
//  Anything else returns nil, and the feed falls back to the actor's signed
//  clock (plus FirstSeen's clamp for claims, taps and releases), exactly as
//  for an event with no token. A wrong answer here can only ever be "no
//  authority time", never an invented one.
//
//  If FreeTSA rotates its certificate, tokens signed by the new one stop
//  counting until its pin is added here. That fails safe. Add new pins;
//  never remove an old one while tokens it signed are in anyone's record.

nonisolated enum TimestampVerifier {

    /// SHA-256 of the DER of each timestamp signing certificate this phone
    /// believes. FreeTSA's TSA certificate: ECDSA P-384, in service since
    /// 2026-03-16, valid to 2040. The value is the one published at
    /// https://freetsa.org/index_en.php and in its CPS.
    static let pinnedCertificates: Set<Data> = [
        Data([0x8b, 0xfb, 0x03, 0x05, 0xbb, 0x64, 0xe2, 0x57, 0x1c, 0xa5, 0x07, 0x55, 0x2e, 0xf3, 0x24, 0x5c,
              0xb1, 0xc2, 0xfe, 0xe8, 0x72, 0x8e, 0x0f, 0xf8, 0x68, 0x92, 0x25, 0x08, 0x1e, 0xa1, 0x34, 0x67]),
    ]

    /// A timestamp token is a couple of kilobytes. Anything this large is not one.
    static let maxTokenBytes = 64 * 1024

    private static let verdicts = TimestampVerdicts()

    /// The authority's time for the event with `digest`, or nil unless every
    /// check above passes. Remembered per token, because the feed and the
    /// record screen ask about the same events over and over.
    static func verifiedGenTime(token: Data, digest: Data) -> Date? {
        var hasher = SHA256()
        hasher.update(data: token)
        hasher.update(data: digest)
        let key = Data(hasher.finalize())
        if let known = verdicts.lookup(key) { return known }
        let verdict = verifiedGenTime(token: token, digest: digest, pins: pinnedCertificates)
        verdicts.store(key, verdict)
        return verdict
    }

    /// The same, against any set of pins. The self-tests use their own.
    static func verifiedGenTime(token: Data, digest: Data, pins: Set<Data>) -> Date? {
        guard !digest.isEmpty, !pins.isEmpty, token.count <= maxTokenBytes else { return nil }
        let der = DERReader(token)

        // TimeStampResp ::= SEQUENCE { status PKIStatusInfo, timeStampToken ContentInfo }
        guard let response = der.whole(tag: 0x30),
              let r = der.children(response), r.count == 2,
              isGranted(der, r[0]) else { return nil }

        // ContentInfo ::= SEQUENCE { id-signedData, [0] EXPLICIT SignedData }
        guard r[1].tag == 0x30, let ci = der.children(r[1]), ci.count == 2,
              der.isOID(ci[0], TimestampOID.signedData), ci[1].tag == 0xA0,
              let wrapped = der.children(ci[1]), wrapped.count == 1, wrapped[0].tag == 0x30,
              let sd = der.children(wrapped[0]), sd.count >= 5 else { return nil }

        // SignedData ::= SEQUENCE { version, digestAlgorithms SET, encapContentInfo,
        //   certificates [0] IMPLICIT, crls [1] IMPLICIT OPTIONAL, signerInfos SET }
        // Certificates are required: Seal always asks for them (certReq).
        guard sd[0].tag == 0x02, sd[1].tag == 0x31, sd[2].tag == 0x30, sd[sd.count - 1].tag == 0x31 else { return nil }
        let middle = Array(sd[3..<(sd.count - 1)])
        guard middle.map(\.tag) == [0xA0] || middle.map(\.tag) == [0xA0, 0xA1] else { return nil }
        let certificateSet = middle[0]

        // EncapsulatedContentInfo ::= SEQUENCE { id-ct-TSTInfo, [0] EXPLICIT OCTET STRING }
        guard let encap = der.children(sd[2]), encap.count == 2,
              der.isOID(encap[0], TimestampOID.tstInfo), encap[1].tag == 0xA0,
              let content = der.children(encap[1]), content.count == 1, content[0].tag == 0x04 else { return nil }
        let tstInfo = der.data(content[0].value)

        // The cheap checks first: is this token about this event at all?
        guard let genTime = genTime(ofTSTInfo: tstInfo, digest: digest) else { return nil }

        // SignerInfo ::= SEQUENCE { version, sid, digestAlgorithm, signedAttrs [0],
        //   signatureAlgorithm, signature OCTET STRING, unsignedAttrs [1] OPTIONAL }
        // RFC 3161: the token carries the TSA's signature and no other.
        guard let signers = der.children(sd[sd.count - 1]), signers.count == 1, signers[0].tag == 0x30,
              let si = der.children(signers[0]), si.count == 6 || si.count == 7,
              si[0].tag == 0x02, si[1].tag == 0x30 || si[1].tag == 0x80,
              si[2].tag == 0x30, si[3].tag == 0xA0, si[4].tag == 0x30, si[5].tag == 0x04,
              si.count == 6 || si[6].tag == 0xA1,
              let digestOID = der.algorithmOID(si[2]), let digestHash = TimestampHash(digestOID: digestOID),
              let signatureOID = der.algorithmOID(si[4]) else { return nil }
        let signatureHash: TimestampHash
        if let named = TimestampHash(ecdsaOID: signatureOID) {
            signatureHash = named
        } else if signatureOID == TimestampOID.ecPublicKey {
            signatureHash = digestHash
        } else {
            return nil
        }

        // The signed attributes must say "this is a TSTInfo" and carry the
        // hash of exactly these TSTInfo bytes, each exactly once.
        guard let attributes = der.children(si[3]) else { return nil }
        var contentTypes = 0
        var messageDigests = 0
        for attribute in attributes {
            guard attribute.tag == 0x30, let parts = der.children(attribute), parts.count == 2,
                  parts[0].tag == 0x06, parts[1].tag == 0x31,
                  let values = der.children(parts[1]) else { return nil }
            let type = der.data(parts[0].value)
            if type == TimestampOID.contentType {
                guard values.count == 1, der.isOID(values[0], TimestampOID.tstInfo) else { return nil }
                contentTypes += 1
            } else if type == TimestampOID.messageDigest {
                guard values.count == 1, values[0].tag == 0x04,
                      der.data(values[0].value) == digestHash.hash(tstInfo) else { return nil }
                messageDigests += 1
            }
        }
        guard contentTypes == 1, messageDigests == 1 else { return nil }

        // What was signed is the attributes as a SET: the same bytes with the
        // [0] IMPLICIT tag put back to the SET tag it stands for (RFC 5652 5.4).
        var signedBytes = der.data(si[3].full)
        signedBytes[signedBytes.startIndex] = 0x31
        let signature = der.data(si[5].value)

        guard let certificates = der.children(certificateSet), !certificates.isEmpty else { return nil }
        let signedByPinned = certificates.contains { certificate in
            guard certificate.tag == 0x30,
                  pins.contains(Data(SHA256.hash(data: der.data(certificate.full)))),
                  let spki = der.subjectPublicKeyInfo(certificate) else { return false }
            return ecdsaVerifies(spki: spki, signature: signature, message: signedBytes, hash: signatureHash)
        }
        return signedByPinned ? genTime : nil
    }

    /// TSTInfo ::= SEQUENCE { version 1, policy, messageImprint, serialNumber,
    /// genTime, ... }. The imprint must be SHA-256 over exactly `digest`.
    private static func genTime(ofTSTInfo bytes: Data, digest: Data) -> Date? {
        let tst = DERReader(bytes)
        guard let top = tst.whole(tag: 0x30), let t = tst.children(top), t.count >= 5,
              t[0].tag == 0x02, tst.data(t[0].value) == Data([0x01]),
              t[1].tag == 0x06, t[2].tag == 0x30, t[3].tag == 0x02, t[4].tag == 0x18,
              let imprint = tst.children(t[2]), imprint.count == 2, imprint[1].tag == 0x04,
              tst.algorithmOID(imprint[0]) == TimestampOID.sha256,
              tst.data(imprint[1].value) == digest else { return nil }
        return generalizedTime(tst.data(t[4].value))
    }

    /// GeneralizedTime as RFC 3161 requires it: YYYYMMDDhhmmss[.f...]Z, UTC.
    static func generalizedTime(_ raw: Data) -> Date? {
        let b = [UInt8](raw)
        guard b.count >= 15, b.count <= 32, b[b.count - 1] == UInt8(ascii: "Z") else { return nil }
        func number(_ from: Int, _ count: Int) -> Int? {
            var value = 0
            for i in from..<(from + count) {
                guard b[i] >= 0x30, b[i] <= 0x39 else { return nil }
                value = value * 10 + Int(b[i] - 0x30)
            }
            return value
        }
        guard let year = number(0, 4), let month = number(4, 2), let day = number(6, 2),
              let hour = number(8, 2), let minute = number(10, 2), let second = number(12, 2) else { return nil }
        if b.count > 15 {
            // A fraction of a second: a dot, at least one digit, then the Z.
            guard b[14] == UInt8(ascii: "."), b.count >= 17,
                  b[15..<(b.count - 1)].allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        }
        guard (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute; components.second = second
        guard components.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components)
    }

    private static func isGranted(_ der: DERReader, _ status: DERNode) -> Bool {
        // PKIStatusInfo ::= SEQUENCE { status INTEGER, ... }: 0 granted, 1 with mods.
        guard status.tag == 0x30, let parts = der.children(status),
              let first = parts.first, first.tag == 0x02 else { return false }
        let value = der.data(first.value)
        return value == Data([0x00]) || value == Data([0x01])
    }

    /// ECDSA with CryptoKit, on whichever NIST curve the certificate's key is.
    private static func ecdsaVerifies(spki: Data, signature: Data, message: Data, hash: TimestampHash) -> Bool {
        if let key = try? P384.Signing.PublicKey(derRepresentation: spki) {
            guard let sig = try? P384.Signing.ECDSASignature(derRepresentation: signature) else { return false }
            switch hash {
            case .sha256: return key.isValidSignature(sig, for: SHA256.hash(data: message))
            case .sha384: return key.isValidSignature(sig, for: SHA384.hash(data: message))
            case .sha512: return key.isValidSignature(sig, for: SHA512.hash(data: message))
            }
        }
        if let key = try? P256.Signing.PublicKey(derRepresentation: spki) {
            guard let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
            switch hash {
            case .sha256: return key.isValidSignature(sig, for: SHA256.hash(data: message))
            case .sha384: return key.isValidSignature(sig, for: SHA384.hash(data: message))
            case .sha512: return key.isValidSignature(sig, for: SHA512.hash(data: message))
            }
        }
        if let key = try? P521.Signing.PublicKey(derRepresentation: spki) {
            guard let sig = try? P521.Signing.ECDSASignature(derRepresentation: signature) else { return false }
            switch hash {
            case .sha256: return key.isValidSignature(sig, for: SHA256.hash(data: message))
            case .sha384: return key.isValidSignature(sig, for: SHA384.hash(data: message))
            case .sha512: return key.isValidSignature(sig, for: SHA512.hash(data: message))
            }
        }
        return false
    }
}

// MARK: - Object identifiers (DER contents, without tag and length)

nonisolated enum TimestampOID {
    static let signedData = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02])          // 1.2.840.113549.1.7.2
    static let tstInfo = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x10, 0x01, 0x04])  // 1.2.840.113549.1.9.16.1.4
    static let contentType = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x03])         // 1.2.840.113549.1.9.3
    static let messageDigest = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x04])       // 1.2.840.113549.1.9.4
    static let sha256 = Data([0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01])              // 2.16.840.1.101.3.4.2.1
    static let sha384 = Data([0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02])              // 2.16.840.1.101.3.4.2.2
    static let sha512 = Data([0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03])              // 2.16.840.1.101.3.4.2.3
    static let ecdsaSHA256 = Data([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02])               // 1.2.840.10045.4.3.2
    static let ecdsaSHA384 = Data([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x03])               // 1.2.840.10045.4.3.3
    static let ecdsaSHA512 = Data([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x04])               // 1.2.840.10045.4.3.4
    static let ecPublicKey = Data([0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01])                     // 1.2.840.10045.2.1
}

nonisolated enum TimestampHash {
    case sha256, sha384, sha512

    init?(digestOID oid: Data) {
        if oid == TimestampOID.sha256 { self = .sha256 }
        else if oid == TimestampOID.sha384 { self = .sha384 }
        else if oid == TimestampOID.sha512 { self = .sha512 }
        else { return nil }
    }

    init?(ecdsaOID oid: Data) {
        if oid == TimestampOID.ecdsaSHA256 { self = .sha256 }
        else if oid == TimestampOID.ecdsaSHA384 { self = .sha384 }
        else if oid == TimestampOID.ecdsaSHA512 { self = .sha512 }
        else { return nil }
    }

    func hash(_ data: Data) -> Data {
        switch self {
        case .sha256: Data(SHA256.hash(data: data))
        case .sha384: Data(SHA384.hash(data: data))
        case .sha512: Data(SHA512.hash(data: data))
        }
    }
}

// MARK: - A strict, bounded DER reader

/// One tag-length-value. Ranges index the reader's bytes.
nonisolated struct DERNode {
    let tag: UInt8
    /// Tag, length and contents.
    let full: Range<Int>
    /// Contents only.
    let value: Range<Int>
}

/// Reads DER without recursion and without trusting a single length: every
/// node must fit inside its parent, and anything malformed is nil, never a
/// trap. Only what timestamp tokens use: low tag numbers, definite lengths
/// of at most four bytes.
nonisolated struct DERReader {
    let bytes: [UInt8]

    init(_ data: Data) { bytes = [UInt8](data) }

    /// The one node that spans every byte, with this tag. Trailing bytes are refused.
    func whole(tag: UInt8) -> DERNode? {
        guard let node = node(at: 0, end: bytes.count), node.tag == tag,
              node.full.upperBound == bytes.count else { return nil }
        return node
    }

    func node(at start: Int, end: Int) -> DERNode? {
        guard start >= 0, end <= bytes.count, start < end, end - start >= 2 else { return nil }
        let tag = bytes[start]
        guard tag & 0x1F != 0x1F else { return nil }            // high tag numbers: not here
        var i = start + 1
        let first = bytes[i]
        i += 1
        var length = 0
        if first < 0x80 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7F)
            // 0x80 is BER's indefinite length, never DER. Over four bytes is never a token.
            guard count >= 1, count <= 4, count <= end - i else { return nil }
            for _ in 0..<count {
                length = (length << 8) | Int(bytes[i])
                i += 1
            }
        }
        guard length <= end - i else { return nil }
        return DERNode(tag: tag, full: start..<(i + length), value: i..<(i + length))
    }

    /// The children of a constructed node, which must tile its contents
    /// exactly. At most 64, which is far more than a token has anywhere.
    func children(_ node: DERNode) -> [DERNode]? {
        guard node.tag & 0x20 != 0 else { return nil }
        var out: [DERNode] = []
        var i = node.value.lowerBound
        while i < node.value.upperBound {
            guard out.count < 64, let child = self.node(at: i, end: node.value.upperBound) else { return nil }
            out.append(child)
            i = child.full.upperBound
        }
        return out
    }

    func data(_ range: Range<Int>) -> Data { Data(bytes[range]) }

    func isOID(_ node: DERNode, _ oid: Data) -> Bool {
        node.tag == 0x06 && data(node.value) == oid
    }

    /// AlgorithmIdentifier ::= SEQUENCE { algorithm OID, parameters OPTIONAL }
    func algorithmOID(_ node: DERNode) -> Data? {
        guard node.tag == 0x30, let parts = children(node), (1...2).contains(parts.count),
              parts[0].tag == 0x06 else { return nil }
        return data(parts[0].value)
    }

    /// Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signature }
    /// TBSCertificate ::= SEQUENCE { [0] version OPTIONAL, serialNumber,
    ///   signature, issuer, validity, subject, subjectPublicKeyInfo, ... }
    func subjectPublicKeyInfo(_ certificate: DERNode) -> Data? {
        guard let parts = children(certificate), parts.count == 3, parts[0].tag == 0x30,
              let tbs = children(parts[0]), let first = tbs.first else { return nil }
        let index = (first.tag == 0xA0 ? 1 : 0) + 5
        guard tbs.count > index, tbs[index].tag == 0x30 else { return nil }
        return data(tbs[index].full)
    }
}

/// Verdicts by token, so a phone checks each signature once a launch.
/// Bounded; cleared outright when full, which only costs a recheck.
nonisolated final class TimestampVerdicts: @unchecked Sendable {
    private let lock = NSLock()
    private var verdicts: [Data: Date?] = [:]

    /// nil: never checked. .some(nil): checked and refused.
    func lookup(_ key: Data) -> Date?? {
        lock.lock()
        defer { lock.unlock() }
        return verdicts[key]
    }

    func store(_ key: Data, _ verdict: Date?) {
        lock.lock()
        defer { lock.unlock() }
        if verdicts.count >= 4_096 { verdicts.removeAll(keepingCapacity: true) }
        verdicts[key] = .some(verdict)
    }
}
