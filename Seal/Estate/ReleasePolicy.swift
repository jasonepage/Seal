// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

//  ReleasePolicy.swift
//  Seal
//
//  THE RULE: how long a silence, how many days of warnings, how many quiet
//  days after that, and how many key holders it takes. It lived inside
//  EstateModels.swift, and it is on its own here for one reason: with the
//  release machine it forms the pure core that can be compiled and tested
//  with no app, no phone and no network (tools/coretests/main.swift), which
//  is what lets those tests run in public on every push.
//
//  Nothing about the type changed in the move, including the hand written
//  decoder at the bottom.

struct ReleasePolicy: Codable, Hashable {

    enum ObjectionBehavior: String, Codable, CaseIterable {
        /// A custodian's objection stops the clock until they withdraw it.
        case pause
        /// A custodian's objection kills the claim outright.
        case veto

        var label: String {
            switch self {
            case .pause: "Pause the countdown"
            case .veto: "Stop the release"
            }
        }
    }

    /// WHEN A RULE OPENS (PRODUCT.md section 17, added 1.3). One rule is
    /// one box of keys (RuleBook.swift), so the kind belongs to the rule,
    /// never to a single envelope: a box never holds two kinds.
    ///
    ///   quiet       the rule as it always was: silence, warnings, grace,
    ///               then M taps. Every rule made before 1.3 is this kind.
    ///   breakGlass  instant. Any M of the key holders together, on any
    ///               day: a claim opens at once, there are no warnings and
    ///               no grace, and it opens the moment M keys are tapped.
    ///               The owner chose this, so nothing they do stops it
    ///               (ReleaseMachine.voidReason); they are told after.
    ///   rightAway   a message in a bottle. No key holders and no release.
    ///               Each recipient's key table is wrapped straight to
    ///               their devices, so it opens the moment it is sealed.
    enum Kind: String, Codable, CaseIterable {
        case quiet
        case breakGlass
        case rightAway

        var label: String {
            switch self {
            case .quiet: "When I go quiet"
            case .breakGlass: "Break glass"
            case .rightAway: "Right away"
            }
        }

        /// One line under the choice, written to be read back and agreed with.
        var explanation: String {
            switch self {
            case .quiet:
                "Opens only after you stop opening Seal for a long time, you are warned, and enough key holders agree."
            case .breakGlass:
                "Opens the moment enough of your key holders tap their keys together, on any day. No waiting, and no way to stop it once they do. You are told after. For the passwords a family or a business needs in an emergency."
            case .rightAway:
                "Opens the moment you seal it, for the person you wrote to, with their own key. No key holders, no waiting. A message in a bottle."
            }
        }

        var needsKeyHolders: Bool { self != .rightAway }

        /// What a screen says for this kind (EstateEngine.shown). Pure, and
        /// here so tools/coretests can check it with the machine. A break
        /// glass rule has no quiet time, so the machine reads it as overdue
        /// the moment it is sealed: that is its resting state, shown as all
        /// quiet. A right away rule has nothing to release: for its
        /// recipient it is open, for its owner simply sealed.
        func shown(_ state: ReleaseState, owner: Bool) -> ReleaseState {
            switch self {
            case .quiet: state
            case .breakGlass: state == .overdue ? .active : state
            case .rightAway: owner ? .active : .released
            }
        }

        /// The line the envelope editor shows, decided in section 17 so the
        /// owner is told plainly what "right away" gives away.
        var editorLine: String {
            "Right away means the person holding this key can open it as soon as you seal it."
        }
    }

    /// Seven and fourteen were added in 1.3 for people who need a short
    /// fuse: a reporter, somebody who travels somewhere risky. A short
    /// silence also starts a claim after a hospital stay, which is why the
    /// rule screen says so (`shortSilenceCaution`).
    static let allowedSilenceDays = [7, 14, 30, 90, 180, 365]
    /// The silence a new non-default rule starts with. Was the minimum of
    /// `allowedSilenceDays` until that minimum became seven.
    static let shortRuleSilenceDays = 30
    static let defaultSilenceDays = 90
    static let defaultWarningDays = 21
    static let defaultGraceDays = 14
    /// "Never" (1.3). Stored as a number, not as zero, on purpose: a key
    /// holder on an older build reads it as "ask in a hundred years", which
    /// is never. Zero would make those phones ask on every refresh.
    static let neverCustodyConfirmMonths = 1200
    static let allowedCustodyConfirmMonths = [neverCustodyConfirmMonths, 6, 12, 24]
    /// A new rule never asks key holders to check their key (1.3). The
    /// owner can still turn it on under More options.
    static let defaultCustodyConfirmMonths = neverCustodyConfirmMonths
    /// What a policy saved before the interval existed means: once a year.
    /// Kept apart from the default so old bytes keep their old meaning.
    static let legacyCustodyConfirmMonths = 12

    /// False when key holders are never asked to check their key.
    static func asksForKeyCheck(months: Int) -> Bool { months < neverCustodyConfirmMonths }
    var asksForKeyCheck: Bool { Self.asksForKeyCheck(months: custodyConfirmMonths) }

    /// How long the owner can go without opening the app before custodians
    /// may start a claim.
    var silenceDays: Int = defaultSilenceDays
    /// How long the owner is warned, daily, after a claim opens.
    var warningDays: Int = defaultWarningDays
    /// A quiet period after the warnings, before keys can be tapped.
    var graceDays: Int = defaultGraceDays
    /// M custodians out of N must tap.
    var threshold: Int
    var objectionBehavior: ObjectionBehavior = .pause
    /// How often each key holder's phone asks them to tap their key and
    /// say they still have it (CustodyConfirmation.swift). Travels in the
    /// policy so the key holders' phones know the interval. Not part of
    /// the release rule; nothing in ReleaseMachine reads it.
    var custodyConfirmMonths: Int = defaultCustodyConfirmMonths
    /// Added 1.3. Missing in every older policy, which reads as `.quiet`,
    /// and left out when encoding a quiet rule, so a pre 1.3 rule's bytes
    /// and every older phone's reading of them do not change.
    var kind: Kind = .quiet

    enum PolicyError: LocalizedError, Equatable {
        case silenceNotAllowed(Int)
        case warningTooShort
        case graceNegative
        case thresholdOutOfRange(threshold: Int, custodians: Int)
        case breakGlassShape

        var errorDescription: String? {
            switch self {
            case .breakGlassShape:
                "A break glass rule has no quiet time, no warnings and no grace."
            case .silenceNotAllowed(let d):
                "Silence must be one of \(ReleasePolicy.allowedSilenceDays.map(String.init).joined(separator: ", ")) days, not \(d)."
            case .warningTooShort: "Warnings must run for at least one day."
            case .graceNegative: "The grace period cannot be negative."
            case .thresholdOutOfRange(let m, let n):
                n == 0
                    ? "There are no key holders yet. Add at least one person on the Keys tab, then seal."
                    : n == 1
                        ? "The rule needs 1 key holder to agree. \(m) is not possible with one key holder."
                        : "The rule needs between 1 and \(n) key holders to agree. \(m) is not possible."
            }
        }
    }

    func validate(custodianCount: Int) throws {
        switch kind {
        case .rightAway:
            // Nothing to check: no key holders, no clock. The numbers are
            // kept as they are and read by nobody.
            return
        case .breakGlass:
            guard silenceDays == 0, warningDays == 0, graceDays == 0 else { throw PolicyError.breakGlassShape }
        case .quiet:
            guard Self.allowedSilenceDays.contains(silenceDays) else { throw PolicyError.silenceNotAllowed(silenceDays) }
            guard warningDays >= 1 else { throw PolicyError.warningTooShort }
        }
        guard graceDays >= 0 else { throw PolicyError.graceNegative }
        guard threshold >= 1, threshold <= custodianCount else {
            throw PolicyError.thresholdOutOfRange(threshold: threshold, custodians: custodianCount)
        }
    }

    var silence: TimeInterval { TimeInterval(silenceDays) * 86_400 }
    var warning: TimeInterval { TimeInterval(warningDays) * 86_400 }
    var grace: TimeInterval { TimeInterval(graceDays) * 86_400 }

    /// What a rule of one really allows, for the owner, in the same words
    /// on every screen that shows it (audit H1). At a rule of one every key
    /// share IS the Estate Key, so one key holder who rebuilt the app could
    /// use it early. The app's own gate does not stop a rebuilt app. The
    /// second lock on every envelope, the recipient's own phone, still holds,
    /// and that is what limits what they could read.
    static func oneKeyCaution(custodianCount: Int) -> String {
        let who = custodianCount <= 1 ? "your key holder" : "each key holder"
        let fix = custodianCount <= 1
            ? "To close this gap, add a second key holder and ask for both keys."
            : "To close this gap, ask for two keys or more."
        return "With a rule of one, you trust \(who) fully. Seal opens nothing early, but someone who rebuilt the app could use their key before the warnings end. They could read the envelopes you wrote to them, or give the key to someone you wrote to, who could then read theirs. Each envelope still needs the phone of the person it was written for. \(fix)"
    }

    /// Under the silence picker when the silence is short (1.3).
    static let shortSilenceCaution = "A short quiet time is for people who need it, like a reporter or somebody traveling somewhere risky. A hospital stay or a lost phone can start a claim too. You are still warned every day, and opening Seal once stops it."

    /// The same rule turned into the shape `kind` needs. Used when the
    /// owner switches the kind on the rule screen, so the numbers are never
    /// left in a shape `validate` refuses.
    func shaped(as newKind: Kind) -> ReleasePolicy {
        var p = self
        p.kind = newKind
        switch newKind {
        case .quiet:
            if !Self.allowedSilenceDays.contains(p.silenceDays) {
                p.silenceDays = Self.defaultSilenceDays
                p.warningDays = Self.defaultWarningDays
                p.graceDays = Self.defaultGraceDays
            }
        case .breakGlass:
            p.silenceDays = 0
            p.warningDays = 0
            p.graceDays = 0
        case .rightAway:
            break
        }
        return p
    }

    /// One line a 60 year old can read back and agree with.
    func summary(custodianCount: Int) -> String {
        switch kind {
        case .rightAway:
            return "Opens right away for the person you wrote to, with their own key. No key holders."
        case .breakGlass:
            return custodianCount <= 1
                ? "Your one key holder, on any day, the moment they tap their key. You are told after."
                : "Any \(threshold) of your \(custodianCount) key holders together, on any day, the moment they tap their keys. You are told after."
        case .quiet:
            break
        }
        return custodianCount == 1
            ? "Your one key holder, after \(silenceDays) days of silence, \(warningDays) days of warnings and \(graceDays) days of grace."
            : "Any \(threshold) of your \(custodianCount) key holders, after \(silenceDays) days of silence, \(warningDays) days of warnings and \(graceDays) days of grace."
    }
}


extension ReleasePolicy {
    private enum Keys: String, CodingKey {
        case silenceDays, warningDays, graceDays, threshold, objectionBehavior, custodyConfirmMonths, kind
    }

    /// By hand since 1.3, only so a quiet rule encodes without `kind` and
    /// stays byte for byte what every older phone and the web page read.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(silenceDays, forKey: .silenceDays)
        try c.encode(warningDays, forKey: .warningDays)
        try c.encode(graceDays, forKey: .graceDays)
        try c.encode(threshold, forKey: .threshold)
        try c.encode(objectionBehavior, forKey: .objectionBehavior)
        try c.encode(custodyConfirmMonths, forKey: .custodyConfirmMonths)
        if kind != .quiet { try c.encode(kind, forKey: .kind) }
    }

    /// `custodyConfirmMonths` was added 2026-09-16; a policy in an older
    /// estate, event or capsule has no key for it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        silenceDays = try c.decode(Int.self, forKey: .silenceDays)
        warningDays = try c.decode(Int.self, forKey: .warningDays)
        graceDays = try c.decode(Int.self, forKey: .graceDays)
        threshold = try c.decode(Int.self, forKey: .threshold)
        objectionBehavior = try c.decode(ObjectionBehavior.self, forKey: .objectionBehavior)
        custodyConfirmMonths = try c.decodeIfPresent(Int.self, forKey: .custodyConfirmMonths) ?? ReleasePolicy.legacyCustodyConfirmMonths
        // An unknown kind throws, so the whole body fails to decode, the
        // same as an unknown objection behaviour. schema.js does the same.
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .quiet
    }
}
