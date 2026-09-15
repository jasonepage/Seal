import Foundation
import os

//  TimestampService.swift
//  Seal
//
//  TRUSTED TIMESTAMPS (docs/RECORD.md §4).
//
//  Every time in Seal comes off the acting phone's own clock, which means a
//  modified client can date anything it likes. That is the one real gap between
//  "signed" and "provable". This closes it: take the SHA-256 of a record event,
//  send ONLY that hash to a timestamp authority, and keep the signed token it
//  returns. RFC 3161, a standard old enough to have off-the-shelf verifiers.
//
//  THE CONTENT NEVER LEAVES THE DEVICE, because a hash is not the content.
//
//  WHAT THIS PHONE DOES AND DOES NOT CHECK
//  ---------------------------------------
//  Verifying an RFC 3161 token properly means parsing CMS SignedData and
//  validating a certificate chain. iOS ships no API for that, and hand-rolling
//  a CMS verifier is precisely the kind of security code that should not be
//  written to hit a deadline. So this file is deliberately modest:
//
//  * It builds the request itself, which is a small fixed DER structure.
//  * It reads the response's top-level status, which is a shallow, well-defined
//    parse.
//  * It refuses any token that does not literally contain our digest. That is a
//    scan, not a parse, and it is used ONLY to reject. A guard that can produce
//    a false rejection and never a false acceptance is a safe use of a
//    heuristic; the reverse would not be.
//  * It stores the token bytes untouched.
//
//  It does NOT check the authority's signature, and the UI says so in those
//  words. Full verification belongs in the export's standalone verifier
//  (docs/RECORD.md §6), where Python has real ASN.1 libraries and where the
//  check actually matters, because that is the artefact somebody else reads.
//
//  OFF BY DEFAULT
//  --------------
//  Timestamping sends a hash to a third party, which tells that party some
//  hash was submitted at some time from some address. That is real metadata,
//  small but real, and an app should not start doing it quietly. The toggle
//  lives under Your record on the You screen, and the record footer points
//  at it by that name.

// MARK: - Stored token

struct TimestampRecord: Codable, Hashable {
    let digestHex: String
    /// The authority's response, byte for byte. Never rewritten: the export
    /// verifier needs exactly what came back.
    let token: Data
    let authority: String
    /// THIS phone's clock, kept for display and debugging only. It is not the
    /// timestamp and must never be shown as one.
    let obtainedAt: Date
    var attempts: Int
    var lastAttemptAt: Date?

    var hasToken: Bool { !token.isEmpty }
}

// MARK: - Store

enum TimestampStore {
    /// Five, then the event settles at "Signed" and stops asking. An app that
    /// retries a dead endpoint forever is a battery bug wearing a feature's
    /// clothes.
    static let attemptCap = 5

    private static func storageKey(_ ownerHash: String) -> String { "seal.tst.\(ownerHash)" }
    private static func enabledKey(_ ownerHash: String) -> String { "seal.tst.on.\(ownerHash)" }

    static func isEnabled(ownerHash: String) -> Bool {
        KeychainStore.load(enabledKey(ownerHash)) != nil
    }

    static func setEnabled(_ enabled: Bool, ownerHash: String) {
        if enabled {
            KeychainStore.save(Data([1]), for: enabledKey(ownerHash))
        } else {
            KeychainStore.delete(enabledKey(ownerHash))
        }
    }

    static func load(ownerHash: String) -> [String: TimestampRecord] {
        guard let data = KeychainStore.load(storageKey(ownerHash)),
              let decoded = try? JSONDecoder().decode([String: TimestampRecord].self, from: data)
        else { return [:] }
        return decoded
    }

    static func save(_ records: [String: TimestampRecord], ownerHash: String) {
        if let data = try? JSONEncoder().encode(records) {
            KeychainStore.save(data, for: storageKey(ownerHash))
        }
    }

    static func wipe(ownerHash: String) {
        KeychainStore.delete(storageKey(ownerHash))
        KeychainStore.delete(enabledKey(ownerHash))
    }

    /// What Seal can honestly say about this event's time.
    static func proof(forDigest hex: String,
                      in records: [String: TimestampRecord],
                      enabled: Bool) -> RecordEvent.TimeProof {
        if let record = records[hex], record.hasToken { return .timestamped }
        guard enabled else { return .deviceClaimed }
        let attempts = records[hex]?.attempts ?? 0
        return attempts < attemptCap ? .pendingTimestamp : .deviceClaimed
    }
}

// MARK: - The service

enum TimestampService {

    static let log = Logger(subsystem: "io.github.jasonepage.Seal", category: "timestamp")

    /// Open question 1 in docs/RECORD.md: this operator has NOT been chosen on
    /// the basis of terms or uptime, only that it is public and free. Decide
    /// before anyone relies on it, and consider carrying an OpenTimestamps
    /// anchor beside it so the record does not depend on one company staying up.
    nonisolated static let defaultAuthority = "https://freetsa.org/tsr"

    /// At most this many per pass, so a long-neglected record does not fire off
    /// a hundred requests the first time somebody opens the screen.
    static let batchLimit = 20

    /// Stamps whatever still needs it. Returns the updated map, or nil when
    /// nothing changed, so a caller can skip a redundant write and redraw.
    static func stampPending(events: [RecordEvent],
                             ownerHash: String,
                             authority: String = defaultAuthority) async -> [String: TimestampRecord]? {
        guard TimestampStore.isEnabled(ownerHash: ownerHash),
              let url = URL(string: authority) else { return nil }

        var records = TimestampStore.load(ownerHash: ownerHash)
        let due = events.filter { event in
            let hex = event.digest.hexString
            if let existing = records[hex] {
                return !existing.hasToken && existing.attempts < TimestampStore.attemptCap
            }
            return true
        }.prefix(batchLimit)
        guard !due.isEmpty else { return nil }

        var changed = false
        for event in due {
            let hex = event.digest.hexString
            let attempts = (records[hex]?.attempts ?? 0) + 1
            let token = await request(digest: event.digest, from: url)
            records[hex] = TimestampRecord(digestHex: hex,
                                           token: token ?? Data(),
                                           authority: authority,
                                           obtainedAt: Clocks.current.now,
                                           attempts: attempts,
                                           lastAttemptAt: Clocks.current.now)
            changed = true
        }
        guard changed else { return nil }
        TimestampStore.save(records, ownerHash: ownerHash)
        return records
    }

    /// Stamp one digest, for the estate log (Estate/EstateEngine.swift).
    /// Unlike `stampPending` this does not consult the Independent
    /// timestamps toggle: an
    /// estate's heartbeats and claims are the thing the timestamps exist for,
    /// and the owner agreed to it when they created the estate. Returns nil
    /// on any failure.
    static func stamp(digest: Data, authority: String = defaultAuthority) async -> Data? {
        guard let url = URL(string: authority) else { return nil }
        return await request(digest: digest, from: url)
    }

    /// One round trip. Returns the response bytes on success, nil on anything
    /// else. Failure is ordinary here: no network, an authority having a bad
    /// day, a captive portal returning HTML. None of those are worth an alert.
    private static func request(digest: Data, from url: URL) async -> Data? {
        var nonce: UInt64 = 0
        // A fresh nonce per request, so a replayed old response is detectable
        // by a verifier even though this phone does not check it.
        for byte in (0..<8).map({ _ in UInt8.random(in: 0...255) }) {
            nonce = (nonce << 8) | UInt64(byte)
        }
        nonce |= 1   // never zero

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/timestamp-query", forHTTPHeaderField: "Content-Type")
        request.httpBody = TimestampDER.request(for: digest, nonce: nonce)
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                log.error("timestamp: HTTP failure")
                return nil
            }
            // 0 granted, 1 grantedWithMods. Anything else is a refusal.
            guard let status = TimestampDER.status(of: data), status == 0 || status == 1 else {
                log.error("timestamp: authority refused")
                return nil
            }
            // Reject-only guard. If our digest is not in there, this token is
            // not about our event, whatever else it may be.
            guard TimestampDER.contains(digest, in: data) else {
                log.error("timestamp: response does not carry our digest, discarding")
                return nil
            }
            return data
        } catch {
            log.error("timestamp: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

// MARK: - The small amount of DER this needs

/// Just enough ASN.1 to build an RFC 3161 request and read a response's status.
/// Not a general parser and should not grow into one: anything more belongs in
/// the export verifier, where real libraries exist.
enum TimestampDER {

    static let sha256AlgorithmOID = Data([0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01])
    static let null = Data([0x05, 0x00])

    static func length(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var value = count
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    static func tlv(_ tag: UInt8, _ value: Data) -> Data {
        var out = Data([tag])
        out.append(length(value.count))
        out.append(value)
        return out
    }

    static func sequence(_ parts: [Data]) -> Data {
        tlv(0x30, parts.reduce(into: Data()) { $0.append($1) })
    }

    /// DER INTEGER: signed, big-endian, minimal, with a leading zero when the
    /// top bit would otherwise make a positive value look negative.
    static func integer(_ value: UInt64) -> Data {
        var bytes: [UInt8] = []
        var remaining = value
        repeat {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        } while remaining > 0
        if bytes[0] & 0x80 != 0 { bytes.insert(0x00, at: 0) }
        return tlv(0x02, Data(bytes))
    }

    /// TimeStampReq (RFC 3161 §2.4.1): version, messageImprint, nonce, certReq.
    /// `certReq` is true so the authority returns its certificate inside the
    /// token, which is what lets the export verify offline years later without
    /// having to go and find it.
    static func request(for digest: Data, nonce: UInt64) -> Data {
        let algorithm = sequence([sha256AlgorithmOID, null])
        let imprint = sequence([algorithm, tlv(0x04, digest)])
        return sequence([integer(1), imprint, integer(nonce), tlv(0x01, Data([0xFF]))])
    }

    /// The PKIStatus at the top of a TimeStampResp. Two nested SEQUENCE headers
    /// then an INTEGER, and nothing deeper. Returns nil rather than guessing if
    /// the shape is not what RFC 3161 says it is.
    static func status(of response: Data) -> Int? {
        let bytes = [UInt8](response)
        var index = 0

        /// Consumes one tag and length, leaving `index` on the value.
        func consumeHeader(expecting tag: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == tag else { return false }
            index += 1
            guard index < bytes.count else { return false }
            let first = bytes[index]
            index += 1
            if first < 0x80 { return true }
            let byteCount = Int(first & 0x7F)
            guard byteCount > 0, byteCount <= 4, index + byteCount <= bytes.count else { return false }
            index += byteCount
            return true
        }

        guard consumeHeader(expecting: 0x30) else { return nil }   // TimeStampResp
        guard consumeHeader(expecting: 0x30) else { return nil }   // PKIStatusInfo
        guard index < bytes.count, bytes[index] == 0x02 else { return nil }
        index += 1
        guard index < bytes.count else { return nil }
        let valueLength = Int(bytes[index])
        index += 1
        guard valueLength > 0, valueLength <= 4, index + valueLength <= bytes.count else { return nil }
        var status = 0
        for offset in 0..<valueLength { status = (status << 8) | Int(bytes[index + offset]) }
        return status
    }

    /// The authority's `genTime`, read from the TSTInfo inside the token.
    ///
    /// TSTInfo is SEQUENCE { version, policy, messageImprint, serialNumber
    /// INTEGER, genTime GeneralizedTime, ... }. The message imprint ends with
    /// OUR digest, which `contains` has already located, so this walks
    /// forward from the digest: one INTEGER (the serial), then one
    /// GeneralizedTime (0x18). Anything else is nil. This is the same
    /// discipline as `status`: a shallow, targeted read that can produce a
    /// wrong answer only by returning nil, never by inventing a time. It is
    /// used by the release feed to prefer the authority's time over the
    /// actor's clock. The token's signature is still only verified by
    /// tools/verify_capsule.py, and the record screen says so.
    static func genTime(of response: Data, digest: Data) -> Date? {
        let bytes = [UInt8](response)
        let pin = [UInt8](digest)
        guard !pin.isEmpty, bytes.count > pin.count else { return nil }
        var start: Int? = nil
        for i in 0...(bytes.count - pin.count) where Array(bytes[i..<(i + pin.count)]) == pin {
            start = i
            break
        }
        guard var index = start else { return nil }
        index += pin.count

        func skipTLV(expecting tag: UInt8) -> Range<Int>? {
            guard index < bytes.count, bytes[index] == tag else { return nil }
            index += 1
            guard index < bytes.count else { return nil }
            let first = bytes[index]
            index += 1
            var length = 0
            if first < 0x80 {
                length = Int(first)
            } else {
                let byteCount = Int(first & 0x7F)
                guard byteCount > 0, byteCount <= 4, index + byteCount <= bytes.count else { return nil }
                for _ in 0..<byteCount { length = (length << 8) | Int(bytes[index]); index += 1 }
            }
            guard index + length <= bytes.count else { return nil }
            let range = index..<(index + length)
            index += length
            return range
        }

        guard skipTLV(expecting: 0x02) != nil,                  // serialNumber
              let timeRange = skipTLV(expecting: 0x18),          // genTime
              let text = String(bytes: bytes[timeRange], encoding: .ascii),
              text.count >= 15, text.hasSuffix("Z") else { return nil }
        // YYYYMMDDHHMMSS[.fff]Z
        let core = String(text.prefix(14))
        guard core.allSatisfy(\.isNumber) else { return nil }
        func part(_ from: Int, _ length: Int) -> Int? {
            let s = core.index(core.startIndex, offsetBy: from)
            return Int(core[s..<core.index(s, offsetBy: length)])
        }
        guard let year = part(0, 4), let month = part(4, 2), let day = part(6, 2),
              let hour = part(8, 2), let minute = part(10, 2), let second = part(12, 2) else { return nil }
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute; components.second = second
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)
    }

    /// Byte scan, used only to REJECT a token that cannot be about our event.
    static func contains(_ needle: Data, in haystack: Data) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        let hay = [UInt8](haystack)
        let pin = [UInt8](needle)
        let last = hay.count - pin.count
        guard last >= 0 else { return false }
        for start in 0...last where Array(hay[start..<(start + pin.count)]) == pin {
            return true
        }
        return false
    }
}
