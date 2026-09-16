// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

//  CheckInShared.swift
//  SealWidget (the reader)
//
//  The widget's whole view of the world: two numbers the app wrote into
//  the App Group after the last heartbeat. It cannot read anything else,
//  and it must never try. Keys mirror Seal/CheckIn/CheckInShared.swift.

enum CheckInShared {
    static let groupID = "group.io.github.jasonepage.Seal"
    static let lastCheckInKey = "seal.checkin.lastEpoch"
    static let silenceDaysKey = "seal.checkin.silenceDays"
    static let widgetKind = "SealCheckInWidget"

    struct Reading {
        let lastCheckIn: Date
        let silenceDays: Int
    }

    /// Nil until the app has sealed once and written the numbers.
    static func read() -> Reading? {
        guard let d = UserDefaults(suiteName: groupID) else { return nil }
        let epoch = d.double(forKey: lastCheckInKey)
        let days = d.integer(forKey: silenceDaysKey)
        guard epoch > 0, days > 0 else { return nil }
        return Reading(lastCheckIn: Date(timeIntervalSince1970: epoch), silenceDays: days)
    }
}
