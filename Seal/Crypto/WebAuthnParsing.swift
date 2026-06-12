import Foundation
import CryptoKit

/// Minimal CBOR decoder — just the subset WebAuthn attestation objects need
/// (unsigned/negative ints, byte strings, text strings, arrays, maps).
enum CBOR {
    indirect enum Value {
        case unsigned(UInt64)
        case negative(Int64)        // stored as -1 - n
        case bytes(Data)
        case text(String)
        case array([Value])
        case map([(Value, Value)])

        subscript(key: String) -> Value? {
            if case .map(let pairs) = self {
                for (k, v) in pairs { if case .text(key) = k { return v } }
            }
            return nil
        }
        subscript(key: Int64) -> Value? {
            if case .map(let pairs) = self {
                for (k, v) in pairs {
                    if case .unsigned(let u) = k, Int64(u) == key { return v }
                    if case .negative(let n) = k, n == key { return v }
                }
            }
            return nil
        }
        var bytesValue: Data? { if case .bytes(let d) = self { return d }; return nil }
    }

    enum DecodeError: Error { case truncated, unsupported(UInt8) }

    static func decode(_ data: Data) throws -> Value {
        var offset = data.startIndex
        return try decodeItem(data, &offset)
    }

    private static func decodeItem(_ data: Data, _ offset: inout Data.Index) throws -> Value {
        guard offset < data.endIndex else { throw DecodeError.truncated }
        let initial = data[offset]; offset += 1
        let major = initial >> 5
        let info = initial & 0x1F

        func length() throws -> UInt64 {
            switch info {
            case 0...23: return UInt64(info)
            case 24...27:
                let count = 1 << (Int(info) - 24)
                guard data.distance(from: offset, to: data.endIndex) >= count else { throw DecodeError.truncated }
                var value: UInt64 = 0
                for _ in 0..<count { value = (value << 8) | UInt64(data[offset]); offset += 1 }
                return value
            default: throw DecodeError.unsupported(initial)
            }
        }

        switch major {
        case 0: return .unsigned(try length())
        case 1: return .negative(-1 - Int64(try length()))
        case 2, 3:
            let len = Int(try length())
            guard data.distance(from: offset, to: data.endIndex) >= len else { throw DecodeError.truncated }
            let slice = Data(data[offset..<data.index(offset, offsetBy: len)])
            offset = data.index(offset, offsetBy: len)
            if major == 2 { return .bytes(slice) }
            guard let s = String(data: slice, encoding: .utf8) else { throw DecodeError.unsupported(initial) }
            return .text(s)
        case 4:
            let len = Int(try length())
            var items: [Value] = []
            for _ in 0..<len { items.append(try decodeItem(data, &offset)) }
            return .array(items)
        case 5:
            let len = Int(try length())
            var pairs: [(Value, Value)] = []
            for _ in 0..<len {
                let k = try decodeItem(data, &offset)
                let v = try decodeItem(data, &offset)
                pairs.append((k, v))
            }
            return .map(pairs)
        default:
            throw DecodeError.unsupported(initial)
        }
    }
}

/// Extracts what Seal needs from a WebAuthn registration response.
enum WebAuthnParsing {
    struct RegistrationData {
        let credentialID: Data
        let publicKey: P256.Signing.PublicKey   // the root identity key
    }

    enum ParseError: Error { case noAuthData, noAttestedCredential, badCOSEKey }

    /// attestationObject = CBOR { fmt, attStmt, authData }.
    /// authData = rpIdHash(32) ‖ flags(1) ‖ signCount(4) ‖ attestedCredentialData.
    /// attestedCredentialData = aaguid(16) ‖ credIdLen(2 BE) ‖ credId ‖ COSE public key.
    static func parseRegistration(attestationObject: Data) throws -> RegistrationData {
        let top = try CBOR.decode(attestationObject)
        guard let authData = top["authData"]?.bytesValue else { throw ParseError.noAuthData }
        guard authData.count > 37, authData[authData.startIndex + 32] & 0x40 != 0 else {
            throw ParseError.noAttestedCredential   // AT flag not set
        }
        var i = authData.startIndex + 37 + 16       // skip header + aaguid
        let idLen = Int(authData[i]) << 8 | Int(authData[i + 1]); i += 2
        let credentialID = Data(authData[i..<(i + idLen)]); i += idLen

        // COSE_Key (EC2): -1 curve, -2 x, -3 y
        let cose = try CBOR.decode(Data(authData[i...]))
        guard let x = cose[-2]?.bytesValue, let y = cose[-3]?.bytesValue,
              x.count == 32, y.count == 32 else { throw ParseError.badCOSEKey }
        let publicKey = try P256.Signing.PublicKey(x963Representation: Data([0x04]) + x + y)
        return RegistrationData(credentialID: credentialID, publicKey: publicKey)
    }
}

/// A stored WebAuthn assertion — everything needed to re-verify it later.
struct WebAuthnAssertion: Codable, Hashable {
    let credentialID: Data
    let clientDataJSON: Data
    let authenticatorData: Data
    let signature: Data

    /// WebAuthn signature is over authenticatorData ‖ SHA256(clientDataJSON).
    func verify(with publicKey: P256.Signing.PublicKey) -> Bool {
        guard let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
        let signed = authenticatorData + Data(SHA256.hash(data: clientDataJSON))
        return publicKey.isValidSignature(sig, for: signed)
    }
}
