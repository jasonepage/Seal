import Foundation
import CryptoKit

//  TestAuthenticator.swift
//  Seal
//
//  A software stand-in for a FIDO2 key, for the self-tests only. It produces
//  byte-exact WebAuthn assertions (authenticatorData ‖ SHA256(clientDataJSON)
//  signed with P-256) so the verification code under test is the SAME code
//  that checks a real key's output, with no test-only branch in it.
//
//  It can also produce deliberately WRONG assertions (wrong relying party,
//  no user presence, a registration type) to prove those are refused.

struct TestAuthenticator {
    let privateKey: P256.Signing.PrivateKey
    let credentialID: Data

    init(credentialID: Data = Data((0..<16).map { _ in UInt8.random(in: 0...255) })) {
        self.privateKey = P256.Signing.PrivateKey()
        self.credentialID = credentialID
    }

    var publicKey: P256.Signing.PublicKey { privateKey.publicKey }
    var publicKeyData: Data { publicKey.rawRepresentation }
    var credentialIDHash: String { Data(SHA256.hash(data: credentialID)).hexString }

    var rootIdentity: RootIdentity {
        RootIdentity(credentialIDHash: credentialIDHash,
                     publicKey: publicKeyData,
                     tier: .verified,
                     displayName: "Test \(credentialIDHash.prefix(4))",
                     rawCredentialID: credentialID)
    }

    struct Options {
        var relyingPartyID = CeremonyManager.relyingPartyID
        var userPresent = true
        var userVerified = false
        var type = "webauthn.get"
    }

    func assertion(challenge: Data, options: Options = Options()) -> WebAuthnAssertion {
        var flags: UInt8 = 0
        if options.userPresent { flags |= 0x01 }
        if options.userVerified { flags |= 0x04 }
        var authData = Data(SHA256.hash(data: Data(options.relyingPartyID.utf8)))
        authData.append(flags)
        authData.append(contentsOf: [0, 0, 0, 1])   // sign count
        let clientData: [String: Any] = [
            "type": options.type,
            "challenge": challenge.base64URLEncodedString(),
            "origin": "https://\(options.relyingPartyID)"
        ]
        let clientDataJSON = try! JSONSerialization.data(withJSONObject: clientData, options: [.sortedKeys])
        let signed = authData + Data(SHA256.hash(data: clientDataJSON))
        let signature = try! privateKey.signature(for: signed)
        return WebAuthnAssertion(credentialID: credentialID,
                                 clientDataJSON: clientDataJSON,
                                 authenticatorData: authData,
                                 signature: signature.derRepresentation)
    }

    /// A device endorsement signed by this authenticator, the way
    /// registration produces one, over a fresh software device key.
    func endorse(deviceKey: P256.Signing.PrivateKey, kem: Data, legacyV2: Bool = false) -> DeviceEndorsement {
        let devicePub = deviceKey.publicKey.x963Representation
        let commitment = legacyV2
            ? IdentityManager.legacyEndorsementCommitmentV2(devicePublicKey: devicePub, kemBundlePublicKeys: kem)
            : IdentityManager.endorsementCommitment(devicePublicKey: devicePub, kemBundlePublicKeys: kem)
        let stored = assertion(challenge: commitment)
        return DeviceEndorsement(devicePublicKey: devicePub,
                                 kemBundlePublicKeys: kem,
                                 assertion: try! JSONEncoder().encode(stored),
                                 createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func revoke(devicePublicKey: Data) -> DeviceRevocation {
        let commitment = Data(SHA256.hash(data: Data("seal.revoke.v1".utf8) + devicePublicKey))
        let stored = assertion(challenge: commitment)
        return DeviceRevocation(devicePublicKey: devicePublicKey,
                                assertion: try! JSONEncoder().encode(stored),
                                revokedAt: Date(timeIntervalSince1970: 1_700_000_100))
    }
}
