import Foundation
import CryptoKit

//  KEMBundle.swift
//  Seal
//
//  THE HYBRID KEY ENCAPSULATION THE DOCS ALWAYS PROMISED.
//
//  docs/GOTCHAS.md says it plainly: README and SDS claimed X25519 plus
//  ML-KEM-768 while HybridKEM.swift only ever did X25519. For chat that was a
//  documentation bug. For a vault that will be decrypted decades from now it
//  is the difference between "harvest now, decrypt later" being a real threat
//  and not. So this file adds the lattice half, and it adds it ONLY for the
//  estate wraps (Estate Key to owner devices, Shamir shares to custodians).
//  The legacy single-X25519 path in HybridKEM.swift is untouched.
//
//  A device's `DeviceEndorsement.kemBundlePublicKeys` now carries one of two
//  things, told apart by length:
//    - 32 bytes: a raw X25519 public key (every endorsement before this file)
//    - "SKB1" ‖ X25519(32) ‖ ML-KEM-768 public key (1184): the hybrid bundle
//  Both are signed under the device endorsement exactly as before, so the
//  ML-KEM key is enclave-rooted the same way the X25519 key was.
//
//  The hybrid wrap: an ephemeral X25519 agreement gives ss1, an ML-KEM-768
//  encapsulation to the recipient's lattice key gives ss2, and ONE HKDF over
//  ss1 ‖ ss2 gives the AES-256-GCM wrapping key. An attacker must break both.
//  A recipient whose bundle has no ML-KEM key gets the classical wrap only,
//  and the envelope says so, so a verifier can tell which protection a share
//  actually has.
//
//  COMPILER NOTE, READ BEFORE BLAMING THIS FILE. The ML-KEM API used here is
//  CryptoKit's `MLKEM768` as introduced with iOS 26. The code in this file was
//  written without a compiler available; the first Xcode build showed that
//  `PrivateKey.init()` throws and that the seed initialiser is
//  `init(seedRepresentation:publicKey:)`, both fixed. The project's deployment
//  target is below iOS 26 in one configuration, so every ML-KEM call is behind
//  `#available(iOS 26.0, *)` and a phone below that gets the classical suite.
//  Everything that touches ML-KEM is confined to this file and to
//  `KEMPrivateBundle.newMLKEMSeed`, so any remaining correction is local.

struct KEMBundle: Hashable {
    static let magic = Data("SKB1".utf8)
    static let x25519Length = 32
    static let mlkem768PublicKeyLength = 1184
    static let mlkem768CiphertextLength = 1088

    let x25519: Data
    /// nil for a legacy bundle (X25519 only).
    let mlkem768: Data?

    var isHybrid: Bool { mlkem768 != nil }

    var encoded: Data {
        guard let mlkem768 else { return x25519 }
        return Self.magic + x25519 + mlkem768
    }

    /// Accepts either form. Anything else is nil, and callers skip it the way
    /// `HybridKEM.wrapToAll` already skips a bad key.
    static func parse(_ data: Data) -> KEMBundle? {
        if data.count == x25519Length {
            return KEMBundle(x25519: data, mlkem768: nil)
        }
        let hybridLength = magic.count + x25519Length + mlkem768PublicKeyLength
        guard data.count == hybridLength, data.prefix(magic.count) == magic else { return nil }
        let x = Data(data.dropFirst(magic.count).prefix(x25519Length))
        let m = Data(data.suffix(mlkem768PublicKeyLength))
        return KEMBundle(x25519: x, mlkem768: m)
    }
}

/// This device's KEM private material. The X25519 half is the same key
/// `IdentityManager.kemPrivateKey` has always held; the ML-KEM half is new
/// and optional so a phone that predates it still decrypts everything it
/// could before.
struct KEMPrivateBundle {
    let x25519: Curve25519.KeyAgreement.PrivateKey
    let mlkem768Seed: Data?

    var publicBundle: KEMBundle {
        var lattice: Data? = nil
        if #available(iOS 26.0, *), let seed = mlkem768Seed {
            lattice = try? MLKEM768.PrivateKey(seedRepresentation: seed, publicKey: nil).publicKey.rawRepresentation
        }
        return KEMBundle(x25519: x25519.publicKey.rawRepresentation, mlkem768: lattice)
    }

    /// A fresh ML-KEM-768 seed, or nil below iOS 26.
    static func newMLKEMSeed() -> Data? {
        if #available(iOS 26.0, *) {
            return try? MLKEM768.PrivateKey().seedRepresentation
        }
        return nil
    }
}

enum HybridWrap {

    /// One wrapped copy for one recipient device.
    struct Envelope: Codable, Hashable {
        /// "x25519" or "x25519+mlkem768". Recorded so a capsule verifier can
        /// state which protection each share actually has.
        let suite: String
        let ephemeralPublicKey: Data
        /// Present only for the hybrid suite.
        let mlkemCiphertext: Data?
        /// AES-256-GCM combined (nonce ‖ ciphertext ‖ tag).
        let ciphertext: Data
    }

    enum WrapError: Error { case badRecipient, badEnvelope, noRecipients }

    static let classicalSuite = "x25519"
    static let hybridSuite = "x25519+mlkem768"
    private static let info = Data("seal.kem.hybrid.v1".utf8)

    /// Derive the wrapping key from the classical secret, the lattice secret
    /// (empty for the classical suite) and every public value involved, so
    /// the key is bound to exactly this recipient and this encapsulation.
    private static func wrapKey(ss1: Data, ss2: Data, ephemeral: Data, recipient: KEMBundle, mlkemCiphertext: Data) -> SymmetricKey {
        let ikm = SymmetricKey(data: ss1 + ss2)
        let salt = ephemeral + recipient.x25519 + Data(SHA256.hash(data: recipient.mlkem768 ?? Data())) + Data(SHA256.hash(data: mlkemCiphertext))
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: info, outputByteCount: 32)
    }

    static func wrap(_ secret: Data, to recipient: KEMBundle, aad: Data) throws -> Envelope {
        guard let recipientX = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipient.x25519) else {
            throw WrapError.badRecipient
        }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let ss1 = try ephemeral.sharedSecretFromKeyAgreement(with: recipientX).withUnsafeBytes { Data($0) }
        var ss2 = Data()
        var mlkemCiphertext = Data()
        var suite = classicalSuite
        if let latticeKeyBytes = recipient.mlkem768 {
            guard #available(iOS 26.0, *) else { throw WrapError.badRecipient }
            guard let latticeKey = try? MLKEM768.PublicKey(rawRepresentation: latticeKeyBytes) else {
                throw WrapError.badRecipient
            }
            let result = try latticeKey.encapsulate()
            ss2 = result.sharedSecret.withUnsafeBytes { Data($0) }
            mlkemCiphertext = result.encapsulated
            suite = hybridSuite
        }
        let ephemeralPub = ephemeral.publicKey.rawRepresentation
        let key = wrapKey(ss1: ss1, ss2: ss2, ephemeral: ephemeralPub,
                          recipient: recipient, mlkemCiphertext: mlkemCiphertext)
        let sealed = try AES.GCM.seal(secret, using: key, authenticating: aad)
        return Envelope(suite: suite,
                        ephemeralPublicKey: ephemeralPub,
                        mlkemCiphertext: suite == hybridSuite ? mlkemCiphertext : nil,
                        ciphertext: sealed.combined!)
    }

    /// Wrap the same secret to EVERY endorsed device of a recipient, the
    /// self-healing pattern from `HybridKEM.wrapToAll`. Keys that fail to
    /// parse are skipped; at least one must wrap.
    static func wrapToAll(_ secret: Data, to bundles: [Data], aad: Data) throws -> [Envelope] {
        var seen = Set<Data>()
        var out: [Envelope] = []
        for raw in bundles {
            guard !raw.isEmpty, seen.insert(raw).inserted, let bundle = KEMBundle.parse(raw) else { continue }
            if let env = try? wrap(secret, to: bundle, aad: aad) { out.append(env) }
        }
        guard !out.isEmpty else { throw WrapError.noRecipients }
        return out
    }

    static func open(_ envelope: Envelope, with mine: KEMPrivateBundle, aad: Data) throws -> Data {
        guard let ephPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: envelope.ephemeralPublicKey) else {
            throw WrapError.badEnvelope
        }
        let ss1 = try mine.x25519.sharedSecretFromKeyAgreement(with: ephPub).withUnsafeBytes { Data($0) }
        var ss2 = Data()
        var mlkemCiphertext = Data()
        if envelope.suite == hybridSuite {
            guard #available(iOS 26.0, *) else { throw WrapError.badEnvelope }
            guard let seed = mine.mlkem768Seed, let ct = envelope.mlkemCiphertext else { throw WrapError.badEnvelope }
            let latticeKey = try MLKEM768.PrivateKey(seedRepresentation: seed, publicKey: nil)
            ss2 = try latticeKey.decapsulate(ct).withUnsafeBytes { Data($0) }
            mlkemCiphertext = ct
        }
        let key = wrapKey(ss1: ss1, ss2: ss2, ephemeral: envelope.ephemeralPublicKey,
                          recipient: mine.publicBundle, mlkemCiphertext: mlkemCiphertext)
        return try AES.GCM.open(try AES.GCM.SealedBox(combined: envelope.ciphertext), using: key, authenticating: aad)
    }

    /// Try every copy; the first that opens wins.
    static func openAny(_ envelopes: [Envelope], with mine: KEMPrivateBundle, aad: Data) throws -> Data {
        for env in envelopes {
            if let opened = try? open(env, with: mine, aad: aad) { return opened }
        }
        throw WrapError.badEnvelope
    }
}
