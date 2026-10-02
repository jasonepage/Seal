// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import CryptoKit

//  TimestampVerifierTests.swift
//  Seal
//
//  Audit H2: a timestamp token's time counts only when its signature checks
//  out under a pinned certificate. The tokens below are real RFC 3161
//  responses made by OpenSSL 3.0 ("openssl ts -reply") from a throwaway test
//  authority with a P-384 key, the same kind of key FreeTSA signs with now.
//  Each answers a request shaped like Seal's: SHA-256 imprint, nonce, certReq.
//  The imprint is SHA-256("seal-test-event"). The test authority's
//  certificate is pinned by its SHA-256 for these tests only.

enum TimestampVerifierTests {

    static var suites: [SelfTest.Suite] { [
        .init(name: "timestamp.verify") { try verify($0) },
        .init(name: "timestamp.hostile") { try hostile($0) },
        .init(name: "timestamp.generalizedTime") { try generalizedTime($0) },
        .init(name: "timestamp.feed") { try feed($0) },
    ] }

    static let digest = Data(SHA256.hash(data: Data("seal-test-event".utf8)))

    /// SHA-256 of the test authority's certificate (CN=Seal Test TSA).
    static let testPin: Set<Data> = [Data([
        0xa1, 0x2c, 0xc1, 0xec, 0xfb, 0x98, 0x05, 0xd4, 0xfd, 0xd9, 0xd0, 0x1e, 0x04, 0xdf, 0x66, 0x28,
        0xd7, 0xbc, 0xf9, 0xab, 0xad, 0x1a, 0x3e, 0x53, 0x56, 0x1e, 0xb4, 0xd3, 0x1c, 0xac, 0xf3, 0x65])]

    /// genTime of both good tokens: 2026-10-02 21:49:52 UTC.
    static let stampedAt = Date(timeIntervalSince1970: 1_790_977_792)

    /// Signed with ecdsa-with-SHA384, signer digest SHA-384.
    static let p384SHA384 = Data(base64Encoded:
        """
        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
        """, options: .ignoreUnknownCharacters)

    /// Same authority, ecdsa-with-SHA256, signer digest SHA-256.
    static let p384SHA256 = Data(base64Encoded:
        """
        MIIF7DADAgEAMIIF4wYJKoZIhvcNAQcCoIIF1DCCBdACAQMxDzANBglghkgBZQMEAgEFADByBgsqhkiG9w0BCRABBKBjBGEwXwIB
        AQYEKgMEATAxMA0GCWCGSAFlAwQCAQUABCDnoNnkEA9ZxwIBvJqRyKHz5V0zJxcgRE/sp6ELtaYPNQIBAxgPMjAyNjEwMDIyMTQ5
        NTJaMAMCAQECCFMASHtr1re0oIID3DCCAeowggFwoAMCAQICFH/8bT/RljHhjg+f3ACv6Sx3IqeEMAoGCCqGSM49BAMDMBkxFzAV
        BgNVBAMMDlNlYWwgVGVzdCBSb290MCAXDTI2MTAwMjIxNDk0NVoYDzIxMjYwOTA4MjE0OTQ1WjAYMRYwFAYDVQQDDA1TZWFsIFRl
        c3QgVFNBMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAExy9qo0xUbCk7tpOH03KXAa2P90Z5ASFooUaf8uknh7ypzRmPGAByK0HsW/sI
        +tcTaH8w0/c9eTVOvuo98gKJThA6uoPZ3iApJbRI2iJo41Ftu+MRHIeXq1taTn53zO+Qo3gwdjAMBgNVHRMBAf8EAjAAMA4GA1Ud
        DwEB/wQEAwIGwDAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAdBgNVHQ4EFgQUs/g/0+/8jsefg3xFXyDyBGtbYn4wHwYDVR0jBBgw
        FoAUXevhSUsjRN3TPlSrg2phd3TAPi0wCgYIKoZIzj0EAwMDaAAwZQIwH5qw7TQiBIONG4o9yBZh0vd+IPdda9PugvKTAljy9NlQ
        E71cNvaN4tOZxCQT81oPAjEA6zThF2WTR3a6AdQSbcls8DYxnvVi4LqJHV+pzE1yAgQwy4hw7vl1w9BY9SS01StzMIIB6jCCAXCg
        AwIBAgIUf/xtP9GWMeGOD5/cAK/pLHcip4QwCgYIKoZIzj0EAwMwGTEXMBUGA1UEAwwOU2VhbCBUZXN0IFJvb3QwIBcNMjYxMDAy
        MjE0OTQ1WhgPMjEyNjA5MDgyMTQ5NDVaMBgxFjAUBgNVBAMMDVNlYWwgVGVzdCBUU0EwdjAQBgcqhkjOPQIBBgUrgQQAIgNiAATH
        L2qjTFRsKTu2k4fTcpcBrY/3RnkBIWihRp/y6SeHvKnNGY8YAHIrQexb+wj61xNofzDT9z15NU6+6j3yAolOEDq6g9neICkltEja
        ImjjUW274xEch5erW1pOfnfM75CjeDB2MAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgbAMBYGA1UdJQEB/wQMMAoGCCsGAQUF
        BwMIMB0GA1UdDgQWBBSz+D/T7/yOx5+DfEVfIPIEa1tifjAfBgNVHSMEGDAWgBRd6+FJSyNE3dM+VKuDamF3dMA+LTAKBggqhkjO
        PQQDAwNoADBlAjAfmrDtNCIEg40bij3IFmHS934g911r0+6C8pMCWPL02VATvVw29o3i05nEJBPzWg8CMQDrNOEXZZNHdroB1BJt
        yWzwNjGe9WLguokdX6nMTXICBDDLiHDu+XXD0Fj1JLTVK3MxggFkMIIBYAIBATAxMBkxFzAVBgNVBAMMDlNlYWwgVGVzdCBSb290
        AhR//G0/0ZYx4Y4Pn9wAr+ksdyKnhDANBglghkgBZQMEAgEFAKCBpDAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQwHAYJKoZI
        hvcNAQkFMQ8XDTI2MTAwMjIxNDk1MlowLwYJKoZIhvcNAQkEMSIEIIIJpdLiy7dNkPDCLcVKaNrbmq+5mlmmP9L6llFBJBOjMDcG
        CyqGSIb3DQEJEAIvMSgwJjAkMCIEIKEswez7mAXU/dnQHgTfZijXvPmrrRo+U1YetNMcrPNlMAoGCCqGSM49BAMCBGYwZAIwM/ra
        /jcy++h9+1mgysvJzTyIgSzNG6Spik9Q6m2HSt2yVlyKee0X5P3/N2kfWHGFAjBzQXGzIH9qJt5As+3iVcEuxiBLqkCGizKdjaD2
        xytEUHLLelrIh1m67KGMjQKUrPA=
        """, options: .ignoreUnknownCharacters)

    /// A forgery: the pinned certificate is in the token, but the signature
    /// is by a different key (CN=Not The TSA) whose certificate rides along.
    static let otherSigner = Data(base64Encoded:
        """
        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
        """, options: .ignoreUnknownCharacters)

    static func verify(_ t: SelfTest.Context) throws {
        guard let a = p384SHA384, let b = p384SHA256 else {
            t.check(false, "the test tokens decode")
            return
        }
        t.equal(TimestampVerifier.verifiedGenTime(token: a, digest: digest, pins: testPin), stampedAt,
                "a real token signed with ecdsa-with-SHA384 gives the authority's time")
        t.equal(TimestampVerifier.verifiedGenTime(token: b, digest: digest, pins: testPin), stampedAt,
                "and one signed with ecdsa-with-SHA256")
        t.check(TimestampVerifier.verifiedGenTime(token: a, digest: Data(repeating: 9, count: 32), pins: testPin) == nil,
                "a token for another event gives nothing")
        t.check(TimestampVerifier.verifiedGenTime(token: a, digest: digest) == nil,
                "a token from an authority that is not pinned gives nothing (the app pins FreeTSA only)")
        t.check(TimestampVerifier.verifiedGenTime(token: a, digest: digest, pins: []) == nil,
                "no pins, no time")
    }

    static func hostile(_ t: SelfTest.Context) throws {
        guard let a = p384SHA384, let forged = otherSigner else {
            t.check(false, "the test tokens decode")
            return
        }
        t.check(TimestampVerifier.verifiedGenTime(token: forged, digest: digest, pins: testPin) == nil,
                "carrying the pinned certificate is not enough: the pinned key must have signed it")

        // The shape the old byte scan accepted: the digest, a serial, a date.
        let serial: [UInt8] = [0x02, 0x01, 0x07]
        let time = Array("20260915120000Z".utf8)
        let scanBait = Data([0x30, 0x10, 0x04, 0x20]) + digest + Data(serial) + Data([0x18, UInt8(time.count)]) + Data(time)
        t.check(TimestampVerifier.verifiedGenTime(token: scanBait, digest: digest, pins: testPin) == nil,
                "a hand-built digest-then-date token is refused")

        // Every truncation is refused, and none of them traps.
        var truncationsAccepted = 0
        for n in 0..<a.count where TimestampVerifier.verifiedGenTime(token: a.prefix(n), digest: digest, pins: testPin) != nil {
            truncationsAccepted += 1
        }
        t.equal(truncationsAccepted, 0, "no truncated token verifies")

        // A changed byte either breaks the token or sits in a part that is
        // not signed (a spare certificate copy, the status). It can never
        // produce a different time.
        var wrongTimes = 0
        for i in stride(from: 0, to: a.count, by: 5) {
            for mask: UInt8 in [0x01, 0xFF] {
                var bent = a
                bent[bent.startIndex + i] ^= mask
                if let got = TimestampVerifier.verifiedGenTime(token: bent, digest: digest, pins: testPin), got != stampedAt {
                    wrongTimes += 1
                }
            }
        }
        t.equal(wrongTimes, 0, "no single changed byte yields a different time")

        // Lengths that lie, nesting that never ends, indefinite lengths.
        let liars: [Data] = [
            Data(), Data([0x30]), Data([0x30, 0x80, 0x00, 0x00]),
            Data([0x30, 0x84, 0xFF, 0xFF, 0xFF, 0xFF]), Data([0x30, 0x85, 1, 2, 3, 4, 5]),
            Data(repeating: 0x30, count: 4_096), Data([0x1F, 0x01, 0x00]),
            Data(repeating: 0, count: TimestampVerifier.maxTokenBytes + 1),
        ]
        for liar in liars {
            t.check(TimestampVerifier.verifiedGenTime(token: liar, digest: digest, pins: testPin) == nil,
                    "malformed DER is refused, not trusted and not a crash", "\(liar.prefix(8).map { String($0) })")
        }
    }

    static func generalizedTime(_ t: SelfTest.Context) throws {
        func g(_ s: String) -> Date? { TimestampVerifier.generalizedTime(Data(s.utf8)) }
        t.equal(g("20261002214952Z"), stampedAt, "plain seconds")
        t.equal(g("20261002214952.123Z"), stampedAt, "a fraction is allowed and ignored")
        t.check(g("20261302214952Z") == nil, "month 13 is refused")
        t.check(g("20260230120000Z") == nil, "February 30 is refused")
        t.check(g("2026100221495Z") == nil, "too short is refused")
        t.check(g("20261002214952") == nil, "no Z is refused")
        t.check(g("20261002214952.Z") == nil, "an empty fraction is refused")
        t.check(g("2026100221495xZ") == nil, "a letter is refused")
    }

    /// The feed believes no token it cannot verify (audit H2). Before, a
    /// key holder could hand the owner's heartbeat any time they liked.
    static func feed(_ t: SelfTest.Context) throws {
        let actor = EstateLogTests.Actor()
        var e = try actor.event(.heartbeat, estate: "E", prev: Data(), at: EstateLogTests.t0)
        let serial: [UInt8] = [0x02, 0x01, 0x07]
        let time = Array("20200101000000Z".utf8)
        e.timestampToken = Data([0x04, 0x20]) + e.digest + Data(serial) + Data([0x18, UInt8(time.count)]) + Data(time)
        t.equal(ReleaseFeed.effectiveTime(e), e.occurredAt, "a forged token does not move an event in time")
        if let real = p384SHA384 {
            e.timestampToken = real
            t.equal(ReleaseFeed.effectiveTime(e), e.occurredAt, "nor does a real token for some other event")
        }
    }
}
