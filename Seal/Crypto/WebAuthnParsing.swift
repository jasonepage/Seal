import Foundation
import CryptoKit
import os

/// Structured, per-key WebAuthn telemetry. The security-key path fails in
/// hardware-/firmware-specific ways (some models work, some don't), and every
/// failure used to collapse into a generic `badCOSEKey`/`verificationFailed`
/// with nothing captured. These lines give a single on-device pass over all
/// keys enough detail to build a per-model failure table.
///
/// Read it in Console.app (or Xcode console) filtered on subsystem
/// `io.github.jasonepage.Seal` / category `webauthn`. No secrets are logged:
/// public coordinates lengths, algorithm IDs, flags, and lengths only — never
/// private keys or full clientData.
enum WebAuthnDiag {
    static let log = Logger(subsystem: "io.github.jasonepage.Seal", category: "webauthn")

    /// COSE algorithm identifiers we care to name in logs (RFC 9053).
    static func algName(_ alg: Int64?) -> String {
        switch alg {
        case -7: return "ES256(P-256)"
        case -8: return "EdDSA(Ed25519)"
        case -257: return "RS256"
        case .some(let a): return "alg(\(a))"
        case .none: return "alg(absent)"
        }
    }

    static func crvName(_ crv: Int64?) -> String {
        switch crv {
        case 1: return "P-256"
        case 6: return "Ed25519"
        case .some(let c): return "crv(\(c))"
        case .none: return "crv(absent)"
        }
    }

    /// Decode the authenticatorData flag byte into a readable summary.
    /// flags: bit0 UP, bit2 UV, bit3 BE, bit4 BS, bit6 AT, bit7 ED.
    static func flagsSummary(_ flags: UInt8) -> String {
        var on: [String] = []
        if flags & 0x01 != 0 { on.append("UP") }
        if flags & 0x04 != 0 { on.append("UV") }
        if flags & 0x08 != 0 { on.append("BE") }
        if flags & 0x10 != 0 { on.append("BS") }
        if flags & 0x40 != 0 { on.append("AT") }
        if flags & 0x80 != 0 { on.append("ED") }
        return on.isEmpty ? "none" : on.joined(separator: "|")
    }
}

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
        /// COSE labels like `alg` (3) and `crv` (-1) are signed integers.
        var intValue: Int64? {
            switch self {
            case .unsigned(let u): return Int64(u)
            case .negative(let n): return n
            default: return nil
            }
        }
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

    enum ParseError: Error, LocalizedError {
        case noAuthData
        case noAttestedCredential
        case missingCoordinates
        case unsupportedAlgorithm(Int64?)
        case unsupportedCurve(Int64?)
        case oversizedCoordinate
        case badPublicKey(Error)

        var errorDescription: String? {
            switch self {
            case .noAuthData: "Attestation had no authenticator data."
            case .noAttestedCredential: "Authenticator data carried no credential (AT flag unset)."
            case .missingCoordinates: "COSE key was missing its x/y coordinates."
            case .unsupportedAlgorithm(let a):
                "Key signed with \(WebAuthnDiag.algName(a)); Seal requires ES256(P-256)."
            case .unsupportedCurve(let c):
                "Key uses \(WebAuthnDiag.crvName(c)); Seal requires P-256."
            case .oversizedCoordinate: "COSE coordinate was not a valid 32-byte P-256 value."
            case .badPublicKey(let e): "CryptoKit rejected the public key: \(e.localizedDescription)"
            }
        }
    }

    /// Normalize a COSE EC coordinate to exactly 32 bytes. Conformant
    /// authenticators emit fixed 32-byte big-endian coordinates, but some
    /// firmware strips a leading zero (→31 bytes) or prepends one (→33). A
    /// hard `== 32` check rejected those keys outright — a model-dependent
    /// "this key never works" failure. We left-pad short values and trim a
    /// single leading zero from long ones; anything else is genuinely bad.
    private static func normalizeCoordinate(_ raw: Data) throws -> Data {
        var bytes = Data(raw)
        if bytes.count > 32 {
            // Drop leading zero padding only — a non-zero high byte means the
            // value really is too big to be a P-256 coordinate.
            while bytes.count > 32, bytes.first == 0 { bytes.removeFirst() }
            guard bytes.count == 32 else { throw ParseError.oversizedCoordinate }
        } else if bytes.count < 32 {
            bytes = Data(repeating: 0, count: 32 - bytes.count) + bytes
        }
        return bytes
    }

    /// attestationObject = CBOR { fmt, attStmt, authData }.
    /// authData = rpIdHash(32) ‖ flags(1) ‖ signCount(4) ‖ attestedCredentialData.
    /// attestedCredentialData = aaguid(16) ‖ credIdLen(2 BE) ‖ credId ‖ COSE public key.
    static func parseRegistration(attestationObject: Data) throws -> RegistrationData {
        let top = try CBOR.decode(attestationObject)
        let fmt: String = { if case .text(let s)? = top["fmt"] { return s }; return "?" }()
        guard let authData = top["authData"]?.bytesValue else {
            WebAuthnDiag.log.error("register: no authData (fmt=\(fmt, privacy: .public))")
            throw ParseError.noAuthData
        }
        let flags = authData.count > 32 ? authData[authData.startIndex + 32] : 0
        guard authData.count > 37, flags & 0x40 != 0 else {
            WebAuthnDiag.log.error("register: AT flag unset (fmt=\(fmt, privacy: .public) flags=\(WebAuthnDiag.flagsSummary(flags), privacy: .public))")
            throw ParseError.noAttestedCredential   // AT flag not set
        }
        var i = authData.startIndex + 37 + 16       // skip header + aaguid
        let idLen = Int(authData[i]) << 8 | Int(authData[i + 1]); i += 2
        let credentialID = Data(authData[i..<(i + idLen)]); i += idLen

        // COSE_Key: alg 3, EC2 params -1 curve, -2 x, -3 y.
        let cose = try CBOR.decode(Data(authData[i...]))
        let alg = cose[3]?.intValue
        let crv = cose[-1]?.intValue
        let xRaw = cose[-2]?.bytesValue
        let yRaw = cose[-3]?.bytesValue

        // Always log what the key presented BEFORE we validate, so a key that
        // fails still leaves a fingerprint in the console.
        WebAuthnDiag.log.info("""
        register: fmt=\(fmt, privacy: .public) \
        \(WebAuthnDiag.algName(alg), privacy: .public) \
        \(WebAuthnDiag.crvName(crv), privacy: .public) \
        flags=\(WebAuthnDiag.flagsSummary(flags), privacy: .public) \
        credIdLen=\(idLen, privacy: .public) \
        xLen=\(xRaw?.count ?? -1, privacy: .public) yLen=\(yRaw?.count ?? -1, privacy: .public)
        """)

        // ES256 / P-256 only. We pin ES256 at registration, but a
        // non-conformant key could still answer with something else — fail
        // loud and named instead of with a generic error.
        if let alg, alg != -7 {
            throw ParseError.unsupportedAlgorithm(alg)
        }
        if let crv, crv != 1 {
            throw ParseError.unsupportedCurve(crv)
        }
        guard let xRaw, let yRaw else { throw ParseError.missingCoordinates }

        let x = try normalizeCoordinate(xRaw)
        let y = try normalizeCoordinate(yRaw)
        do {
            let publicKey = try P256.Signing.PublicKey(x963Representation: Data([0x04]) + x + y)
            return RegistrationData(credentialID: credentialID, publicKey: publicKey)
        } catch {
            WebAuthnDiag.log.error("register: CryptoKit rejected pubkey: \(error.localizedDescription, privacy: .public)")
            throw ParseError.badPublicKey(error)
        }
    }
}

/// A stored WebAuthn assertion — everything needed to re-verify it later.
struct WebAuthnAssertion: Codable, Hashable {
    let credentialID: Data
    let clientDataJSON: Data
    let authenticatorData: Data
    let signature: Data

    /// Enforce the WebAuthn context checks below instead of only logging them.
    ///
    /// **Ships `false` on purpose.** These checks have never run in this app,
    /// so nobody knows what the family's real authenticators actually emit —
    /// and turning them on blind would un-verify existing friendships and
    /// endorsements with no way to tell an attack from a bad guess. Run a
    /// build with this false, read the `webauthn` os-log for CONTEXT VIOLATION
    /// lines over a few days, then flip it. One line, deliberately greppable.
    static let enforceContextChecks = false

    /// What a signature check alone does NOT establish.
    ///
    /// `verify` proves a P-256 signature matches a message. That is not the
    /// same as proving the assertion was made FOR SEAL, in an ASSERTION
    /// ceremony, with a HUMAN PRESENT. Without these three, "a Seal assertion"
    /// is just a raw signature over chosen bytes: a signature the same key
    /// produced for another relying party — or in a registration rather than
    /// an assertion context — is accepted here if the bytes line up.
    ///
    /// - rpIdHash: first 32 bytes of authenticatorData == SHA256(RP ID).
    /// - User Present (bit 0): somebody physically touched the authenticator.
    /// - clientData.type == webauthn.get: this was an assertion.
    ///
    /// User Verified is deliberately NOT required: the UV policy is
    /// `.preferred` so PIN-less keys stay tap-only (the 6/26 fix), which means
    /// a perfectly legitimate assertion can carry UV unset.
    func contextViolations() -> [String] {
        var problems: [String] = []
        guard authenticatorData.count >= 37 else {
            return ["authenticatorData too short (\(authenticatorData.count) bytes)"]
        }
        let expected = Data(SHA256.hash(data: Data(CeremonyManager.relyingPartyID.utf8)))
        if Data(authenticatorData.prefix(32)) != expected {
            problems.append("rpIdHash is not SHA256 of \(CeremonyManager.relyingPartyID)")
        }
        let flags = authenticatorData[authenticatorData.startIndex + 32]
        if flags & 0x01 == 0 { problems.append("User Present flag unset") }
        if let obj = try? JSONSerialization.jsonObject(with: clientDataJSON) as? [String: Any] {
            switch obj["type"] as? String {
            case "webauthn.get": break
            case .some(let other): problems.append("clientData.type is \(other), not webauthn.get")
            case .none: problems.append("clientData.type missing")
            }
        } else {
            problems.append("clientDataJSON did not parse as JSON")
        }
        return problems
    }

    /// WebAuthn signature is over authenticatorData ‖ SHA256(clientDataJSON).
    /// Security keys return ECDSA signatures DER-encoded; CryptoKit's
    /// `derRepresentation` parser handles them. We log which step fails
    /// (parse vs. cryptographic check) so a model-specific failure is
    /// attributable instead of a silent `false`.
    func verify(with publicKey: P256.Signing.PublicKey) -> Bool {
        let flags = authenticatorData.count > 32 ? authenticatorData[authenticatorData.startIndex + 32] : 0
        guard let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature) else {
            WebAuthnDiag.log.error("""
            verify: signature did not parse as DER ECDSA \
            (sigLen=\(signature.count, privacy: .public) \
            flags=\(WebAuthnDiag.flagsSummary(flags), privacy: .public))
            """)
            return false
        }
        let signed = authenticatorData + Data(SHA256.hash(data: clientDataJSON))
        let ok = publicKey.isValidSignature(sig, for: signed)
        if ok {
            // A matching signature is necessary, not sufficient — see
            // contextViolations. Logged now, enforced once we know what real
            // devices actually emit.
            let violations = contextViolations()
            if !violations.isEmpty {
                let detail = violations.joined(separator: "; ")
                WebAuthnDiag.log.error("verify: signature OK but CONTEXT VIOLATION [\(detail, privacy: .public)] enforcing=\(Self.enforceContextChecks, privacy: .public)")
                if Self.enforceContextChecks { return false }
            }
            WebAuthnDiag.log.info("verify: OK (flags=\(WebAuthnDiag.flagsSummary(flags), privacy: .public))")
        } else {
            WebAuthnDiag.log.error("""
            verify: signature parsed but did NOT match the directory public key \
            (authDataLen=\(authenticatorData.count, privacy: .public) \
            flags=\(WebAuthnDiag.flagsSummary(flags), privacy: .public))
            """)
        }
        return ok
    }
}
