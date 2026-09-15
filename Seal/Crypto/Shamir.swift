import Foundation
import CryptoKit

//  Shamir.swift
//  Seal
//
//  THRESHOLD SECRET SHARING OVER GF(256).
//
//  The one genuinely new piece of cryptography in the sealed-envelope
//  product, and it is small and it is old (Shamir, 1979). An Estate Key of
//  32 bytes is split into N shares such that any M of them recover it and
//  any M-1 of them reveal nothing at all, information-theoretically. Each
//  byte of the secret is the constant term of its own random polynomial of
//  degree M-1 over GF(256); share number x (1...N) is that polynomial
//  evaluated at x. Recovery is Lagrange interpolation at x = 0.
//
//  The field is GF(2^8) with the reducing polynomial 0x11B, the same field
//  AES uses, so the arithmetic can be checked against published tables
//  (0x53 * 0xCA = 1 is the classic example). SLIP-0039 uses the same field
//  and the same share layout, which is the other reason to pick it: nothing
//  here is novel.
//
//  What this file does NOT do, on purpose: no verifiable secret sharing, no
//  MAC inside the share, no encoding into words. Bad shares are caught by
//  SHA-256 commitments stored in the signed estate record (see
//  Estate/EstateKeys.swift), which identifies WHICH custodian submitted a
//  bad share instead of failing silently. That is a hash, not a new scheme.
//
//  Test vectors come from an independent Python implementation
//  (tools/shamir_vectors.py) and live in SelfTest/ShamirTests.swift.

enum Shamir {

    struct Share: Codable, Hashable {
        /// 1...255. Never 0, because f(0) is the secret.
        let index: UInt8
        let bytes: Data

        /// index ‖ bytes, the form that is hashed for commitments and that
        /// travels on the wire.
        var encoded: Data { Data([index]) + bytes }

        init(index: UInt8, bytes: Data) {
            self.index = index
            self.bytes = bytes
        }

        init?(encoded: Data) {
            guard encoded.count >= 2, encoded[encoded.startIndex] != 0 else { return nil }
            index = encoded[encoded.startIndex]
            bytes = Data(encoded.dropFirst())
        }

        var commitment: Data { Data(SHA256.hash(data: encoded)) }
    }

    enum ShamirError: Error, Equatable {
        case badThreshold
        case tooManyShares
        case emptySecret
        case notEnoughShares(have: Int, need: Int)
        case duplicateIndex(UInt8)
        case mismatchedLengths
        case zeroIndex
    }

    // MARK: - Field arithmetic

    static let reducingPolynomial: UInt16 = 0x11B

    static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var a = UInt16(a), b = UInt16(b), r: UInt16 = 0
        while b != 0 {
            if b & 1 != 0 { r ^= a }
            a <<= 1
            if a & 0x100 != 0 { a ^= reducingPolynomial }
            b >>= 1
        }
        return UInt8(r & 0xFF)
    }

    /// a^254 is a^(-1) in GF(2^8). Square-and-multiply, constant shape.
    static func inverse(_ a: UInt8) -> UInt8 {
        precondition(a != 0, "no inverse of zero")
        var result: UInt8 = 1
        var base = a
        var exponent = 254
        while exponent > 0 {
            if exponent & 1 != 0 { result = mul(result, base) }
            base = mul(base, base)
            exponent >>= 1
        }
        return result
    }

    /// Horner evaluation. `coefficients[0]` is the constant term.
    static func evaluate(_ coefficients: [UInt8], at x: UInt8) -> UInt8 {
        var r: UInt8 = 0
        for c in coefficients.reversed() {
            r = mul(r, x) ^ c
        }
        return r
    }

    // MARK: - Split

    /// Random coefficients from the system CSPRNG. The deterministic variant
    /// below exists only so the test vectors can be reproduced byte for byte.
    static func split(secret: Data, threshold: Int, shares: Int) throws -> [Share] {
        guard !secret.isEmpty else { throw ShamirError.emptySecret }
        var coefficients: [[UInt8]] = []
        coefficients.reserveCapacity(secret.count)
        for _ in 0..<secret.count {
            coefficients.append((0..<(threshold - 1)).map { _ in UInt8.random(in: 0...255) })
        }
        return try split(secret: secret, threshold: threshold, shares: shares, coefficients: coefficients)
    }

    /// `coefficients[j]` holds the `threshold - 1` non-constant coefficients
    /// for secret byte `j`, lowest degree first.
    static func split(secret: Data, threshold: Int, shares: Int, coefficients: [[UInt8]]) throws -> [Share] {
        guard threshold >= 1, threshold <= shares else { throw ShamirError.badThreshold }
        guard shares <= 255 else { throw ShamirError.tooManyShares }
        guard !secret.isEmpty else { throw ShamirError.emptySecret }
        guard coefficients.count == secret.count,
              coefficients.allSatisfy({ $0.count == threshold - 1 }) else { throw ShamirError.badThreshold }
        let secretBytes = [UInt8](secret)
        var out: [Share] = []
        for i in 1...shares {
            let x = UInt8(i)
            var bytes = Data(count: secretBytes.count)
            for j in 0..<secretBytes.count {
                bytes[j] = evaluate([secretBytes[j]] + coefficients[j], at: x)
            }
            out.append(Share(index: x, bytes: bytes))
        }
        return out
    }

    // MARK: - Combine

    /// Lagrange interpolation at x = 0 across exactly the shares given. The
    /// caller decides which shares to trust (see the commitment check in
    /// EstateKeys); this function will happily combine M wrong shares into a
    /// wrong secret, which is why the commitments exist.
    static func combine(_ shares: [Share], threshold: Int) throws -> Data {
        guard shares.count >= threshold else {
            throw ShamirError.notEnoughShares(have: shares.count, need: threshold)
        }
        let used = Array(shares.prefix(threshold))
        var seen = Set<UInt8>()
        for s in used {
            guard s.index != 0 else { throw ShamirError.zeroIndex }
            guard seen.insert(s.index).inserted else { throw ShamirError.duplicateIndex(s.index) }
        }
        let length = used[0].bytes.count
        guard used.allSatisfy({ $0.bytes.count == length }), length > 0 else {
            throw ShamirError.mismatchedLengths
        }
        // Lagrange basis at 0: l_i = prod_{k != i} x_k / (x_i xor x_k).
        var basis: [UInt8] = []
        for i in used.indices {
            var numerator: UInt8 = 1
            var denominator: UInt8 = 1
            for k in used.indices where k != i {
                numerator = mul(numerator, used[k].index)
                denominator = mul(denominator, used[i].index ^ used[k].index)
            }
            basis.append(mul(numerator, inverse(denominator)))
        }
        var secret = Data(count: length)
        for j in 0..<length {
            var acc: UInt8 = 0
            for i in used.indices {
                acc ^= mul(used[i].bytes[used[i].bytes.startIndex + j], basis[i])
            }
            secret[j] = acc
        }
        return secret
    }
}
