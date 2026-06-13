import Foundation
import CryptoKit

/// Verification authority for founder perks (SDS §10).
///
/// Grants are minted OFFLINE by a Seal founder key (tools/mint_perks.py) and
/// verified on-device before any perk is honored — the server is untrusted
/// for integrity, as always. Fail-closed: no founder public key compiled in
/// means every grant is rejected.
enum PerkAuthority {

    /// The Seal founder public key (P-256, X9.63 uncompressed hex — 65 bytes,
    /// "04…"). Printed by `tools/mint_perks.py keygen`; paste it here.
    /// EMPTY = fail closed: all grants rejected.
    static let founderPublicKeyHex = ""

    static var founderPublicKey: P256.Signing.PublicKey? {
        guard let data = Data(hexString: founderPublicKeyHex), data.count == 65 else { return nil }
        return try? P256.Signing.PublicKey(x963Representation: data)
    }

    /// Numbered founder editions are a verifiable public promise: clients
    /// reject founder grants outside 1–100, so "only 100 founders" is
    /// cryptographic policy, not operational policy.
    static let founderNumberRange = 1...100

    // MARK: - Claim codes

    /// Codes are case- and punctuation-insensitive: "seal-7Q2K…" and
    /// "SEAL 7Q2K…" hash identically. Must match tools/mint_perks.py.
    static func normalize(code: String) -> String {
        String(code.uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    static func codeHashHex(code: String) -> String {
        Data(SHA256.hash(data: Data(normalize(code: code).utf8))).hexString
    }

    static func grantRecordName(codeHashHex: String) -> String { "perk.\(codeHashHex)" }
    static func claimRecordName(codeHashHex: String) -> String { "pclaim.\(codeHashHex)" }

    // MARK: - Signed messages (byte-identical in tools/mint_perks.py)

    static func grantMessage(kind: PerkKind, number: Int?, codeHashHex: String, issuedAtUnix: Int64) -> Data {
        let num = number.map(String.init) ?? "-"
        return Data("seal.perk.grant.v1|\(kind.rawValue)|\(num)|\(codeHashHex)|\(issuedAtUnix)".utf8)
    }

    static func claimMessage(codeHashHex: String, rootID: String, devicePublicKey: Data, claimedAtUnix: Int64) -> Data {
        Data("seal.perk.claim.v1|\(codeHashHex)|\(rootID)|\(devicePublicKey.hexString)|\(claimedAtUnix)".utf8)
    }

    // MARK: - Verification

    /// Founder signature + edition rules. Pass the hash of the code the USER
    /// entered (when redeeming) so a grant can't be served under someone
    /// else's record name; pass nil when verifying a friend's attestation
    /// (the claim/grant hash cross-check happens in `verifyAttestation`).
    static func verifyGrant(_ grant: PerkGrant, enteredCodeHashHex: String?) -> Bool {
        guard let founderKey = founderPublicKey else { return false }   // fail closed
        if let entered = enteredCodeHashHex, entered != grant.codeHashHex { return false }
        switch grant.kind {
        case .founder:
            guard let n = grant.number, founderNumberRange.contains(n) else { return false }
        case .campusFounder:
            guard grant.number == nil else { return false }
        }
        let message = grantMessage(kind: grant.kind, number: grant.number,
                                   codeHashHex: grant.codeHashHex, issuedAtUnix: grant.issuedAtUnix)
        guard let sig = try? P256.Signing.ECDSASignature(derRepresentation: grant.signature) else { return false }
        return founderKey.isValidSignature(sig, for: message)
    }

    /// Full chain before display, same discipline as messages:
    /// founder key → grant → claim → endorsed device key → root identity.
    static func verifyAttestation(_ attestation: PerkAttestation,
                                  root: RootIdentity,
                                  endorsements: [DeviceEndorsement]) -> Bool {
        let grant = attestation.grant
        let claim = attestation.claim
        guard verifyGrant(grant, enteredCodeHashHex: nil),
              claim.codeHashHex == grant.codeHashHex,
              claim.rootID == root.credentialIDHash else { return false }
        // The signing device must verifiably belong to this root (and not be revoked).
        let trusted = IdentityManager.verifiedDevices(root: root, endorsements: endorsements)
        guard trusted.contains(where: { $0.devicePublicKey == claim.devicePublicKey }),
              let pub = try? P256.Signing.PublicKey(x963Representation: claim.devicePublicKey),
              let sig = try? P256.Signing.ECDSASignature(derRepresentation: claim.signature)
        else { return false }
        let message = claimMessage(codeHashHex: claim.codeHashHex, rootID: claim.rootID,
                                   devicePublicKey: claim.devicePublicKey, claimedAtUnix: claim.claimedAtUnix)
        return pub.isValidSignature(sig, for: message)
    }

    /// Verified perks for an identity, deduped: at most one attestation per
    /// kind, lowest founder number wins (display stability if someone holds
    /// several codes).
    static func verifiedPerks(_ attestations: [PerkAttestation],
                              root: RootIdentity,
                              endorsements: [DeviceEndorsement]) -> [PerkAttestation] {
        let valid = attestations.filter { verifyAttestation($0, root: root, endorsements: endorsements) }
        var byKind: [PerkKind: PerkAttestation] = [:]
        for a in valid {
            if let existing = byKind[a.grant.kind] {
                if (a.grant.number ?? .max) < (existing.grant.number ?? .max) { byKind[a.grant.kind] = a }
            } else {
                byKind[a.grant.kind] = a
            }
        }
        return byKind.values.sorted { ($0.grant.number ?? .max) < ($1.grant.number ?? .max) }
    }
}

extension Data {
    /// Strict hex → Data (even length, hex digits only).
    init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8](); bytes.reserveCapacity(chars.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
            default: return nil
            }
        }
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
        }
        self.init(bytes)
    }
}
