// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import UserNotifications
import os

//  CustodyReminders.swift
//  Seal
//
//  THE KEY HOLDER'S PHONE ASKS. Once per interval (the owner's rule), one
//  local notification: "Do you still have the key Karen gave you? Open
//  Seal and tap it to say so." Scheduled after every refresh of the
//  guarded estates, at the due date, replacing the previous one. If the
//  due date has already passed and this phone has not yet said so for
//  this anchor, it is posted now, once. The anchor (the last confirmation
//  or the epoch) is remembered per estate in the keychain so a refresh
//  that changed nothing posts nothing. Wiped on sign out.

enum CustodyReminders {

    private static let log = Logger(subsystem: "io.github.jasonepage.Seal", category: "notices")

    private static func key(_ ownerHash: String) -> String { "seal.custodyreminders.\(ownerHash)" }
    nonisolated private static func identifier(_ estateID: String) -> String { "seal.custody.remind.\(estateID)" }

    /// estateID to the anchor epoch the reminder was last scheduled from.
    private static func load(ownerHash: String) -> [String: TimeInterval] {
        guard let data = KeychainStore.load(key(ownerHash)),
              let map = try? JSONDecoder().decode([String: TimeInterval].self, from: data) else { return [:] }
        return map
    }

    private static func save(_ map: [String: TimeInterval], ownerHash: String) {
        if let data = try? JSONEncoder().encode(map) { KeychainStore.save(data, for: key(ownerHash)) }
    }

    static func wipe(ownerHash: String) {
        let ids = load(ownerHash: ownerHash).keys.map(identifier)
        if !ids.isEmpty { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids) }
        KeychainStore.delete(key(ownerHash))
    }

    static func line(ownerName: String) -> String {
        let name = ownerName.isEmpty ? "someone" : ownerName
        return "Do you still have the key \(name) gave you? Open Seal and tap it to say so. It takes a minute and opens nothing."
    }

    static func schedule(engine: EstateEngine, ownerHash: String) async {
        guard !DemoFixtures.isActive else { return }
        var record = load(ownerHash: ownerHash)
        let center = UNUserNotificationCenter.current()
        var changed = false
        var toAdd: [(id: String, body: String, fireIn: TimeInterval?)] = []

        for g in engine.guarded where g.isCustodian {
            guard let s = engine.guardedSnapshots[g.estateID], s.releasedAt == nil else { continue }
            let anchor = engine.myLastCustodyConfirmation(estateID: g.estateID) ?? engine.custodySince(estateID: g.estateID)
            let anchorEpoch = anchor.timeIntervalSince1970
            if record[g.estateID] == anchorEpoch { continue }
            record[g.estateID] = anchorEpoch
            changed = true
            let due = anchor.addingTimeInterval(CustodyConfirmation.interval(months: s.policy.custodyConfirmMonths))
            let fireIn = due.timeIntervalSince(engine.now)
            toAdd.append((identifier(g.estateID), line(ownerName: g.ownerName), fireIn > 60 ? fireIn : nil))
        }
        if changed { save(record, ownerHash: ownerHash) }
        guard !toAdd.isEmpty else { return }

        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        for item in toAdd {
            center.removePendingNotificationRequests(withIdentifiers: [item.id])
            let content = UNMutableNotificationContent()
            content.title = "Seal"
            content.body = item.body
            content.sound = .default
            let trigger = item.fireIn.map { UNTimeIntervalNotificationTrigger(timeInterval: $0, repeats: false) }
            do {
                try await center.add(UNNotificationRequest(identifier: item.id, content: content, trigger: trigger))
                log.info("custody reminder: \(item.id, privacy: .public) in \(Int((item.fireIn ?? 0) / 86_400), privacy: .public) days")
            } catch {
                log.error("custody reminder: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
