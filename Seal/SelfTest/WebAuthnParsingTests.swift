// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import CryptoKit

//  WebAuthnParsingTests.swift
//  Seal
//
//  Malformed registration data is an error, never a crash (audit, medium).
//  Every input here used to trap: an Int conversion past 2^63, a read past
//  the end of authenticator data, or nesting deep enough to blow the stack.

enum WebAuthnParsingTests {

    static var suites: [SelfTest.Suite] { [
        .init(name: "webauthn.hostileCBOR") { try hostileCBOR($0) },
        .init(name: "webauthn.registration") { try registration($0) },
    ] }

    // A few bytes of CBOR, enough to build attestation objects by hand.
    static func head(_ major: UInt8, _ n: Int) -> Data {
        if n < 24 { return Data([major << 5 | UInt8(n)]) }
        if n < 256 { return Data([major << 5 | 24, UInt8(n)]) }
        return Data([major << 5 | 25, UInt8(n >> 8), UInt8(n & 0xFF)])
    }
    static func bytes(_ d: Data) -> Data { head(2, d.count) + d }
    static func text(_ s: String) -> Data { head(3, s.utf8.count) + Data(s.utf8) }

    static func attestation(authData: Data) -> Data {
        Data([0xA3]) + text("fmt") + text("none") + text("attStmt") + Data([0xA0]) + text("authData") + bytes(authData)
    }

    /// rpIdHash, flags with AT and UP set, sign count, aaguid, the credential
    /// ID, and an ES256 COSE key for `key`.
    static func authData(credentialID: Data, key: P256.Signing.PublicKey) -> Data {
        let raw = key.rawRepresentation
        var cose = Data([0xA5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21])
        cose += bytes(raw.prefix(32))
        cose += Data([0x22]) + bytes(raw.suffix(32))
        var out = Data(SHA256.hash(data: Data(CeremonyManager.relyingPartyID.utf8)))
        out.append(0x41)
        out.append(contentsOf: [0, 0, 0, 1])
        out.append(Data(repeating: 0, count: 16))
        out.append(contentsOf: [UInt8(credentialID.count >> 8), UInt8(credentialID.count & 0xFF)])
        out.append(credentialID)
        out.append(cose)
        return out
    }

    static func hostileCBOR(_ t: SelfTest.Context) throws {
        let ff = [UInt8](repeating: 0xFF, count: 8)
        let cases: [(String, Data)] = [
            ("empty", Data()),
            ("a negative number past Int64", Data([0x3B] + ff)),
            ("a byte string longer than Int", Data([0x5B] + ff)),
            ("an array longer than the input", Data([0x9B, 0, 0, 1, 0, 0, 0, 0, 0])),
            ("a map longer than Int", Data([0xBB] + ff)),
            ("nesting without end", Data(repeating: 0x81, count: 100_000)),
            ("an indefinite length", Data([0x9F, 0x01, 0xFF])),
            ("a truncated integer", Data([0x1B, 0x01])),
        ]
        for (name, data) in cases {
            t.check((try? CBOR.decode(data)) == nil, "malformed CBOR is an error, not a crash", name)
        }
        // A map key of 2^64 - 1 decodes, and looking up a small key does not trap on it.
        if let map = try? CBOR.decode(Data([0xA1, 0x1B] + ff + [0x01])) {
            t.check(map[3] == nil, "a huge integer key is simply not the key asked for")
            t.check(map[3]?.intValue == nil, "and reading it as a number does not trap")
        } else {
            t.check(false, "a map with a huge unsigned key still decodes")
        }
    }

    static func registration(_ t: SelfTest.Context) throws {
        let key = P256.Signing.PrivateKey().publicKey
        let credentialID = Data((0..<16).map { UInt8($0) })
        let good = authData(credentialID: credentialID, key: key)

        let parsed = try WebAuthnParsing.parseRegistration(attestationObject: attestation(authData: good))
        t.equal(parsed.credentialID, credentialID, "a well-formed registration gives its credential ID")
        t.equal(parsed.publicKey.rawRepresentation, key.rawRepresentation, "and its key")

        // Every truncation of the authenticator data, and of the whole
        // object, is an error. None of them may trap.
        var accepted = 0
        for n in 0..<good.count {
            if (try? WebAuthnParsing.parseRegistration(attestationObject: attestation(authData: good.prefix(n)))) != nil { accepted += 1 }
        }
        t.equal(accepted, 0, "no truncated authenticator data parses")
        let whole = attestation(authData: good)
        for n in 0..<whole.count {
            _ = try? WebAuthnParsing.parseRegistration(attestationObject: whole.prefix(n))
        }
        t.check(true, "no truncated attestation object traps")

        // A credential ID length that points past the end.
        var lying = good
        lying[lying.startIndex + 53] = 0xFF
        lying[lying.startIndex + 54] = 0xFF
        t.check((try? WebAuthnParsing.parseRegistration(attestationObject: attestation(authData: lying))) == nil,
                "a credential ID length past the end is refused")
    }
}
