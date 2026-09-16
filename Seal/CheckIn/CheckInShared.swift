// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import WidgetKit

//  CheckInShared.swift
//  Seal (the app side)
//
//  THE TWO NUMBERS THE WIDGET IS ALLOWED TO KNOW.
//
//  The widget lives in another process and must never read the keychain,
//  the estate, an envelope, a name or a secret. So the app writes exactly
//  two values into an App Group after every heartbeat: when the owner
//  last checked in, and how many days of silence the rule allows. That is
//  all the widget shows, and all it can show. Nothing about who the key
//  holders are, how many envelopes exist, or whether a claim is running
//  goes through here.
//
//  SealWidget/CheckInShared.swift is the reader, kept as a separate copy
//  because the widget is its own target. The keys below must stay the
//  same in both files.
//
//  This file also carries the small flag the App Intent leaves for the app
//  ("the person asked to check in, say so when it is done"), which is
//  plain UserDefaults in the app's own container.

enum CheckInShared {

    /// The App Group both targets belong to. Must match the entitlements
    /// of the app and of the widget extension (docs/IMPROVEMENTS_PROMPT.md
    /// phase 2 gives the Xcode steps).
    static let groupID = "group.io.github.jasonepage.Seal"

    static let lastCheckInKey = "seal.checkin.lastEpoch"
    static let silenceDaysKey = "seal.checkin.silenceDays"

    /// The widget's kind string, for reloading its timeline.
    static let widgetKind = "SealCheckInWidget"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: groupID) }

    /// Called after a heartbeat lands. Writes the two numbers and asks the
    /// widget to redraw.
    static func record(lastCheckIn: Date, silenceDays: Int) {
        guard let d = defaults else { return }
        d.set(lastCheckIn.timeIntervalSince1970, forKey: lastCheckInKey)
        d.set(silenceDays, forKey: silenceDaysKey)
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
    }

    /// Sign out: the widget goes back to "not set up".
    static func wipe() {
        guard let d = defaults else { return }
        d.removeObject(forKey: lastCheckInKey)
        d.removeObject(forKey: silenceDaysKey)
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
    }
}

/// The App Intent cannot reach the signing key, so it opens the app and
/// leaves this flag. The home screen picks it up after the heartbeat and
/// tells the person it is done. See CheckInIntent.swift for why.
enum CheckInRequest {
    private static let key = "seal.checkin.requested"

    static func flag() { UserDefaults.standard.set(true, forKey: key) }

    /// True once, then cleared.
    static func consume() -> Bool {
        let was = UserDefaults.standard.bool(forKey: key)
        if was { UserDefaults.standard.removeObject(forKey: key) }
        return was
    }
}
