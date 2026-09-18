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

    static let allowedSilenceDays = [30, 90, 180, 365]
    static let defaultSilenceDays = 90
    static let defaultWarningDays = 21
    static let defaultGraceDays = 14
    static let allowedCustodyConfirmMonths = [6, 12, 24]
    static let defaultCustodyConfirmMonths = 12

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

    enum PolicyError: LocalizedError, Equatable {
        case silenceNotAllowed(Int)
        case warningTooShort
        case graceNegative
        case thresholdOutOfRange(threshold: Int, custodians: Int)

        var errorDescription: String? {
            switch self {
            case .silenceNotAllowed(let d):
                "Silence must be one of \(ReleasePolicy.allowedSilenceDays.map(String.init).joined(separator: ", ")) days, not \(d)."
            case .warningTooShort: "Warnings must run for at least one day."
            case .graceNegative: "The grace period cannot be negative."
            case .thresholdOutOfRange(let m, let n):
                "The rule needs between 1 and \(n) custodians to agree. \(m) is not possible."
            }
        }
    }

    func validate(custodianCount: Int) throws {
        guard Self.allowedSilenceDays.contains(silenceDays) else { throw PolicyError.silenceNotAllowed(silenceDays) }
        guard warningDays >= 1 else { throw PolicyError.warningTooShort }
        guard graceDays >= 0 else { throw PolicyError.graceNegative }
        guard threshold >= 1, threshold <= custodianCount else {
            throw PolicyError.thresholdOutOfRange(threshold: threshold, custodians: custodianCount)
        }
    }

    var silence: TimeInterval { TimeInterval(silenceDays) * 86_400 }
    var warning: TimeInterval { TimeInterval(warningDays) * 86_400 }
    var grace: TimeInterval { TimeInterval(graceDays) * 86_400 }

    /// One line a 60 year old can read back and agree with.
    func summary(custodianCount: Int) -> String {
        custodianCount == 1
            ? "Your one key holder, after \(silenceDays) days of silence, \(warningDays) days of warnings and \(graceDays) days of grace."
            : "Any \(threshold) of your \(custodianCount) key holders, after \(silenceDays) days of silence, \(warningDays) days of warnings and \(graceDays) days of grace."
    }
}


extension ReleasePolicy {
    private enum Keys: String, CodingKey {
        case silenceDays, warningDays, graceDays, threshold, objectionBehavior, custodyConfirmMonths
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
        custodyConfirmMonths = try c.decodeIfPresent(Int.self, forKey: .custodyConfirmMonths) ?? ReleasePolicy.defaultCustodyConfirmMonths
    }
}
