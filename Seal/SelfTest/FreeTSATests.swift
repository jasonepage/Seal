// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import CryptoKit

//  FreeTSATests.swift
//  Seal
//
//  A REAL FreeTSA token, checked against the app's REAL pin.
//
//  TimestampVerifierTests uses a throwaway test authority with its own pin,
//  which is why build 36 could carry a FreeTSA pin that matched nothing:
//  every test passed while no real token was ever believed. This one is the token
//  freetsa.org/tsr returned on 2026-10-03 for SHA-256("seal-freetsa-check"),
//  signed with ecdsa-with-SHA512 by the P-384 certificate pinned in
//  TimestampVerifier.pinnedCertificates. If FreeTSA changes certificates,
//  this keeps passing (the old token is still validly signed by the old
//  key); fetch a fresh token in that case and add the new pin beside the old.

enum FreeTSATests {

    static var suites: [SelfTest.Suite] { [
        .init(name: "timestamp.realFreeTSA") { try realFreeTSA($0) },
    ] }

    static let digest = Data(SHA256.hash(data: Data("seal-freetsa-check".utf8)))

    /// genTime of the token: 2026-10-03 02:51:19 UTC.
    static let stampedAt = Date(timeIntervalSince1970: 1_790_995_879)

    static let token = Data(base64Encoded: """
        MIISFTADAgEAMIISDAYJKoZIhvcNAQcCoIIR/TCCEfkCAQMxDzANBglghkgBZQMEAgMFADCCAYYGCyqGSIb3DQEJEAEEoIIBdQSC
        AXEwggFtAgEBBgQqAwQBMDEwDQYJYIZIAWUDBAIBBQAEIBLatFGOE2EQ8nGuVAl+0qpvQxSaRQbvhS3NSmmS+esCAgQI0IYoGA8y
        MDI2MTAwMzAyNTExOVoBAf+gggETpIIBDzCCAQsxETAPBgNVBAoMCEZyZWUgVFNBMQwwCgYDVQQLDANUU0ExdjB0BgNVBA0MbVRo
        aXMgY2VydGlmaWNhdGUgZGlnaXRhbGx5IHNpZ25zIGRvY3VtZW50cyBhbmQgdGltZSBzdGFtcCByZXF1ZXN0cyBtYWRlIHVzaW5n
        IHRoZSBmcmVldHNhLm9yZyBvbmxpbmUgc2VydmljZXMxGDAWBgNVBAMMD3d3dy5mcmVldHNhLm9yZzEkMCIGCSqGSIb3DQEJARYV
        YnVzaWxlemFzQG1haWxib3gub3JnMRIwEAYDVQQHDAlXdWVyemJ1cmcxCzAJBgNVBAYTAkRFMQ8wDQYDVQQIDAZCYXllcm6ggg5n
        MIIGYDCCBEigAwIBAgIJAMLphhYNqOnNMA0GCSqGSIb3DQEBDQUAMIGVMREwDwYDVQQKEwhGcmVlIFRTQTEQMA4GA1UECxMHUm9v
        dCBDQTEYMBYGA1UEAxMPd3d3LmZyZWV0c2Eub3JnMSIwIAYJKoZIhvcNAQkBFhNidXNpbGV6YXNAZ21haWwuY29tMRIwEAYDVQQH
        EwlXdWVyemJ1cmcxDzANBgNVBAgTBkJheWVybjELMAkGA1UEBhMCREUwHhcNMjYwMjE1MTk0NDIyWhcNNDAwMjAyMTk0NDIyWjCC
        AQsxETAPBgNVBAoMCEZyZWUgVFNBMQwwCgYDVQQLDANUU0ExdjB0BgNVBA0MbVRoaXMgY2VydGlmaWNhdGUgZGlnaXRhbGx5IHNp
        Z25zIGRvY3VtZW50cyBhbmQgdGltZSBzdGFtcCByZXF1ZXN0cyBtYWRlIHVzaW5nIHRoZSBmcmVldHNhLm9yZyBvbmxpbmUgc2Vy
        dmljZXMxGDAWBgNVBAMMD3d3dy5mcmVldHNhLm9yZzEkMCIGCSqGSIb3DQEJARYVYnVzaWxlemFzQG1haWxib3gub3JnMRIwEAYD
        VQQHDAlXdWVyemJ1cmcxCzAJBgNVBAYTAkRFMQ8wDQYDVQQIDAZCYXllcm4wdjAQBgcqhkjOPQIBBgUrgQQAIgNiAASiFeGhstbL
        hxix0o4UAumNSwHUUlOe3DBvs8fYs580wADW59oqGSCx15bp61TSmXkwLm1JW48XnbLLizP6ZtjcvshV3H9uz2bS53sgDXhg1wLb
        IhAtraC+fHCytHeuVaujggHmMIIB4jAJBgNVHRMEAjAAMB0GA1UdDgQWBBQVwL0m69RdgtFdkyYxL+9wsotGXjAfBgNVHSMEGDAW
        gBT6VQ2MNGZRQ0z357OnbJWveuaklzALBgNVHQ8EBAMCBsAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwbAYIKwYBBQUHAQEEYDBe
        MDMGCCsGAQUFBzAChidodHRwOi8vd3d3LmZyZWV0c2Eub3JnL2ZpbGVzL2NhY2VydC5wZW0wJwYIKwYBBQUHMAGGG2h0dHA6Ly93
        d3cuZnJlZXRzYS5vcmc6MjU2MDA3BgNVHR8EMDAuMCygKqAohiZodHRwOi8vd3d3LmZyZWV0c2Eub3JnL2NybC9yb290X2NhLmNy
        bDCByAYDVR0gBIHAMIG9MIG6BgMrBQgwgbIwMwYIKwYBBQUHAgEWJ2h0dHA6Ly93d3cuZnJlZXRzYS5vcmcvZnJlZXRzYV9jcHMu
        aHRtbDAyBggrBgEFBQcCARYmaHR0cDovL3d3dy5mcmVldHNhLm9yZy9mcmVldHNhX2Nwcy5wZGYwRwYIKwYBBQUHAgIwOxo5RnJl
        ZVRTQSB0cnVzdGVkIHRpbWVzdGFtcGluZyBTb2Z0d2FyZSBhcyBhIFNlcnZpY2UgKFNhYVMpMA0GCSqGSIb3DQEBDQUAA4ICAQBr
        MVS/YfnfMr0ziZnesBUOrDNRrNNgt3IgMNDwNhwl6oKWHVIhlYnM/5boljfbpZTAbqvxHI3ztT0/swxQOqTat5qBJRAY/VH1n/T4
        M9uDjSuu3qfh0ZH5PL9ENqoVW44i5NT/znQev2MGXOAHwz9kZwwzz9MFX6hbGhBqWa+nlAqb7Y72KFzj33m1OVHxV2Wl4YD9f91b
        ZTFpUEGW4Ktbkmxpf/iGIPaf4WHpoBW/O6EzofMKYlz4yXyEBh0wRRVyXltLrj+MFHqhe+PsMBllq/dCaO4W/F+AuHElu7aUYWMA
        SelphWAJiUsNMr5HAoeCSSgilqf1CSoWC+k6e4334Fym+Iy4csMex+PG4rSdqXJVQ+AWEdRajSPKh7yDfpNkdnO6yqQJ/tSd11XQ
        5cL0M9jWuCD1zHlgA+u+R2cry3yo23jD7qTGLhZqUvXCyWigH30/Q/RXjjDwrc4DJiQ+gRY0FhdTYqlvgMBPr4LcJKnNksivdj+k
        bz7bVSbrBAzRiazK9l841/5XMtP9BvD0hKCpQFvP9PSgCC8EQnKqgSe26FSJBaAQcA5TnK8NF4jkbElBxf/zyh7P3IjHso35jtgU
        WD1/itg9BJWbYUwJ4tfILpB2F0wbk1GcZDCDZoyW3Xf3trApz/Zd93gF3joc9Hh9RFveKRzWQ7ddUt3egTCCB/8wggXnoAMCAQIC
        CQDB6YYWDajpgDANBgkqhkiG9w0BAQ0FADCBlTERMA8GA1UEChMIRnJlZSBUU0ExEDAOBgNVBAsTB1Jvb3QgQ0ExGDAWBgNVBAMT
        D3d3dy5mcmVldHNhLm9yZzEiMCAGCSqGSIb3DQEJARYTYnVzaWxlemFzQGdtYWlsLmNvbTESMBAGA1UEBxMJV3VlcnpidXJnMQ8w
        DQYDVQQIEwZCYXllcm4xCzAJBgNVBAYTAkRFMB4XDTE2MDMxMzAxNTIxM1oXDTQxMDMwNzAxNTIxM1owgZUxETAPBgNVBAoTCEZy
        ZWUgVFNBMRAwDgYDVQQLEwdSb290IENBMRgwFgYDVQQDEw93d3cuZnJlZXRzYS5vcmcxIjAgBgkqhkiG9w0BCQEWE2J1c2lsZXph
        c0BnbWFpbC5jb20xEjAQBgNVBAcTCVd1ZXJ6YnVyZzEPMA0GA1UECBMGQmF5ZXJuMQswCQYDVQQGEwJERTCCAiIwDQYJKoZIhvcN
        AQEBBQADggIPADCCAgoCggIBALYCjg4wMvERENlkzalLnQJ44ZQq6ROqpZkHzaaXk5lb2ax+M7rZ/jcE2hwBqY0hr+P1kaWdcGdw
        UWeZj1AWci4KtGKyH0ORcdLPzEWT83Na95SlqzEfbAEMeJjeM9dcRRDudvS9HRSYzxfTA/BqXdn3lsxsqbZXpW/j6k/vvnzmtqGN
        PjWjDO5f8XDRzzmjM9P9qJZNIttoWynlYb6JDwqoRYc7LoSrJquDn/6PrenSO7MeYdJzzJuIBkkYX6vs+gU0YAq6kBthTi6FRYLe
        oiJvwZzX31K+1Q2Hd82ZiMBTo/x9wyh6BopP8StxPNmANmbpVThUVv84+AKYz2uThW6SJHdKZs8c3RHC+O/YUgPXRYslZksT7WOc
        3tT/gRPWzFNT0nKUc8PDBxV8ciqltd0L+y1sOLG5N0nIgexgAm0IlRs4JL1xusvORzrr1jbwuRi0osj/RpTwdFevLW8c+CVU0XcP
        15/10xTc0QTN3KvJQTgFbfzwF+frhXL9UvcBRPGI2gX1gj9Y3QYpfnOHvtLXcsE9qCZmAQRf5BLdcJhsDJh7pzRLkDc4dRbSWOeI
        W1H4lot/JgEhO8TLTIX4/wuEr2qYgzfN+4GGj37PMdymcW1+wt2ALBZyYp5cAFLLNX3Smq/EP2FbOx/51OHOCMccc+H+u33FajNi
        Eynp7WwjAgMBAAGjggJOMIICSjAMBgNVHRMEBTADAQH/MA4GA1UdDwEB/wQEAwIBxjAdBgNVHQ4EFgQU+lUNjDRmUUNM9+ezp2yV
        r3rmpJcwgcoGA1UdIwSBwjCBv4AU+lUNjDRmUUNM9+ezp2yVr3rmpJehgZukgZgwgZUxETAPBgNVBAoTCEZyZWUgVFNBMRAwDgYD
        VQQLEwdSb290IENBMRgwFgYDVQQDEw93d3cuZnJlZXRzYS5vcmcxIjAgBgkqhkiG9w0BCQEWE2J1c2lsZXphc0BnbWFpbC5jb20x
        EjAQBgNVBAcTCVd1ZXJ6YnVyZzEPMA0GA1UECBMGQmF5ZXJuMQswCQYDVQQGEwJERYIJAMHphhYNqOmAMDMGA1UdHwQsMCowKKAm
        oCSGImh0dHA6Ly93d3cuZnJlZXRzYS5vcmcvcm9vdF9jYS5jcmwwgc8GA1UdIASBxzCBxDCBwQYKKwYBBAGB8iQBATCBsjAzBggr
        BgEFBQcCARYnaHR0cDovL3d3dy5mcmVldHNhLm9yZy9mcmVldHNhX2Nwcy5odG1sMDIGCCsGAQUFBwIBFiZodHRwOi8vd3d3LmZy
        ZWV0c2Eub3JnL2ZyZWV0c2FfY3BzLnBkZjBHBggrBgEFBQcCAjA7GjlGcmVlVFNBIHRydXN0ZWQgdGltZXN0YW1waW5nIFNvZnR3
        YXJlIGFzIGEgU2VydmljZSAoU2FhUykwNwYIKwYBBQUHAQEEKzApMCcGCCsGAQUFBzABhhtodHRwOi8vd3d3LmZyZWV0c2Eub3Jn
        OjI1NjAwDQYJKoZIhvcNAQENBQADggIBAGivfr+ThWLvTOs7WAvi+vbMNaJncpYvPZWQH6VjDIfQkZiYTOigajP4qcKC7Z8csRrG
        wj4XEI7k785vspTelcEzJiJVclUiymGXHUo7f3glDfuNSu7A+xlZsWQQBSC5wQ5kxiZi5K1NCrriKY/JSPxOmejZ5rj9vkQEEh7H
        wUIurLLJ1zKOBzluYLTzu4A61KVVyA/vtT+F53ZKCp+0r8OZ9M0vX79YcQXGCBzz0FM3trt9GwELdJ9IiMkS82lrobaQLXe338BG
        wEoMwexPjRheLaVd+3vCogNsYhkkak+Z3btvH4KTmPO4A9wK2Q3LWb70wnx3QEuZBDt4JxhnmRFSw5nxLL/ExiWtwJY1WuRONCEA
        7FF6UC4vBvlAuNQ1mbvBFU+K52GgsNVV+0oTkdTzQgr42/EvLX3bnXfc4VN4BAdK8XXk8tbVWzS11vfcvdMXMK9WSA1MDP8UP56D
        vBUYZtC6Dwu9xH/ieGQXa71sGrhd8yXt93eIm8RHG/P6c+VsxZHosWDNp7B4ah7ASsOyT6LijV0Z5eSABNXhZqg8guxv1U+zheuv
        cTOoW1LeRttSROHDSujTbnEvn84NST19Pt1YbGGY4+w+bpY0b0F6yfIh4K/zOo9qCx70wCNjC3atqo2RQzgl7MQcSaW5ixgcfaMO
        mXq5VMc8LNgFr9qZMYIB7DCCAegCAQEwgaMwgZUxETAPBgNVBAoTCEZyZWUgVFNBMRAwDgYDVQQLEwdSb290IENBMRgwFgYDVQQD
        Ew93d3cuZnJlZXRzYS5vcmcxIjAgBgkqhkiG9w0BCQEWE2J1c2lsZXphc0BnbWFpbC5jb20xEjAQBgNVBAcTCVd1ZXJ6YnVyZzEP
        MA0GA1UECBMGQmF5ZXJuMQswCQYDVQQGEwJERQIJAMLphhYNqOnNMA0GCWCGSAFlAwQCAwUAoIG4MBoGCSqGSIb3DQEJAzENBgsq
        hkiG9w0BCRABBDAcBgkqhkiG9w0BCQUxDxcNMjYxMDAzMDI1MTE5WjArBgsqhkiG9w0BCRACDDEcMBowGDAWBBRIH9U8U004QYDA
        KGUZoDb5iFRHZjBPBgkqhkiG9w0BCQQxQgRATPme/qlPRyEB4xlfL6jKoTjrVUfliVLw7c/s3K62ZYkBT5swYM9eOqpPLViqMFyR
        iJX6qQ/zDKuO2hTp7UcaYTAKBggqhkjOPQQDBARnMGUCMGD7F4x3/oISLhB11axRNxBdzaty79BPXs+l2KP9eq1kCospdqgUVLSu
        V6CT8ltc2AIxAOHk47S9M/PtCCHMncdIxZZlOt8Yo/tVRBPOWWDZi28kPwvLIwk0uGDipl3b5P+DgQ==
        """, options: .ignoreUnknownCharacters)

    static func realFreeTSA(_ t: SelfTest.Context) throws {
        guard let token else {
            t.check(false, "the FreeTSA token decodes")
            return
        }
        // The production path: default pins, as the release feed calls it.
        t.equal(TimestampVerifier.verifiedGenTime(token: token, digest: digest), stampedAt,
                "a real FreeTSA token verifies under the app's own pin (P-384, SHA-512)")
        t.check(TimestampVerifier.verifiedGenTime(token: token, digest: Data(repeating: 9, count: 32)) == nil,
                "and gives nothing for another event")
    }
}
