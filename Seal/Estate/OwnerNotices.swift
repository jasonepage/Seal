// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import UserNotifications
import os

//  OwnerNotices.swift
//  Seal
//
//  THE REMINDER THE OWNER NEEDS, BEFORE THEIR OWN COUNTDOWN STARTS.
//
//  The whole ongoing job of owning a sealed estate is "open the app now and
//  then". If the owner forgets for the length of their silence window, the
//  key holders are told the owner has gone quiet, and a claim can be
//  opened. Nothing in the app reminded the owner. CustodianNotices speaks to
//  the key holders only. This file speaks to the owner.
//
//  It works differently from CustodianNotices, and on purpose. A key holder
//  is told when a state MOVED, and the app can see that move because it is
//  in the log. The owner's problem is the opposite: nothing moves, and by
//  the time the app runs again the owner has opened it, which is itself the
//  heartbeat. So this cannot post at the moment of silence. Instead, every
//  time the owner's heartbeat lands, it SCHEDULES three reminders for the
//  future, at about half way through the silence window, about four fifths
//  of the way, and a few days before the end. If the owner opens the app
//  before any of them fire, the heartbeat moves, and the three are replaced
//  with three new ones measured from the new heartbeat. A reminder that
//  fires is one the owner really did leave alone that long.
//
//  Each reminder has a fixed identifier per estate and level, so adding it
//  again replaces it instead of stacking a copy. The anchor it was last
//  scheduled from is kept per identity in the keychain, so a refresh that
//  found nothing new does not churn the schedule, and it is wiped on sign
//  out (ContentView.wipeLocalAndEngines), which also clears the pending
//  reminders themselves. Demo mode schedules nothing.
//
//  The copy is calm. This is somebody who is alive and busy, not somebody
//  in trouble, and the second sentence of every line is the thing to do.
enum OwnerNotices {

    private static let log = Logger(subsystem: "io.github.jasonepage.Seal", category: "notices")

    private static func key(_ ownerHash: String) -> String { "seal.ownernotices.\(ownerHash)" }

    /// The three moments, as a fraction of the silence window, or as days
    /// before its end for the last one.
    enum Level: String, CaseIterable {
        case half, most, last

        /// Seconds after the heartbeat this level fires.
        func offset(silenceDays: Int) -> TimeInterval {
            let day: TimeInterval = 86_400
            let window = TimeInterval(silenceDays) * day
            switch self {
            case .half: return window * 0.5
            case .most: return window * 0.8
            case .last: return window - TimeInterval(Self.lastDays(silenceDays: silenceDays)) * day
            }
        }

        /// How many days before the end the last reminder lands. A 30 day
        /// window gets 3, everything longer gets 5.
        static func lastDays(silenceDays: Int) -> Int { silenceDays <= 30 ? 3 : 5 }
    }

    /// What was scheduled last time, so a quiet refresh does nothing.
    private struct Record: Codable {
        var anchorEpoch: TimeInterval
        var silenceDays: Int
        var identifiers: [String]
    }

    private static func loadRecord(ownerHash: String) -> Record? {
        guard let data = KeychainStore.load(key(ownerHash)) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private static func saveRecord(_ record: Record, ownerHash: String) {
        if let data = try? JSONEncoder().encode(record) {
            KeychainStore.save(data, for: key(ownerHash))
        }
    }

    /// Sign out: forget what was scheduled and take the reminders off the
    /// phone. Synchronous on purpose, because the caller is.
    static func wipe(ownerHash: String) {
        if let record = loadRecord(ownerHash: ownerHash), !record.identifiers.isEmpty {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: record.identifiers)
        }
        KeychainStore.delete(key(ownerHash))
        KeychainStore.delete(newDeviceKey(ownerHash))
    }

    private static func identifier(estateID: String, level: Level) -> String {
        "seal.owner.checkin.\(estateID).\(level.rawValue)"
    }

    // MARK: - The line

    /// Read on a lock screen by somebody who has not thought about this app
    /// in weeks. The first sentence says what is going on, the second says
    /// what to do, and neither one is alarming.
    static func line(for level: Level, silenceDays: Int) -> String {
        switch level {
        case .half:
            return "A quick hello from Seal. Open the app when you have a moment. That is all it takes to show you are still here."
        case .most:
            return "It has been a while since you opened Seal. One open, any time this week, keeps everything just as it is."
        case .last:
            let days = Level.lastDays(silenceDays: silenceDays)
            return "In about \(days) days your quiet period ends and your key holders are told you have gone silent. Opening Seal today keeps that from happening. Nothing opens for a long time after that, and opening the app at any point stops it."
        }
    }

    // MARK: - Scheduling

    /// Called after every heartbeat. Reads the owner's snapshot and the
    /// policy that governs it, and (re)schedules the reminders that are
    /// still in the future. Levels already in the past are dropped, not
    /// posted: the owner is holding the phone right now, which is the
    /// check-in itself.
    static func schedule(engine: EstateEngine, ownerHash: String) async {
        guard !DemoFixtures.isActive else { return }
        guard let estate = engine.estate, estate.epochPublished,
              let snapshot = engine.ownerSnapshot else { return }

        let anchor = snapshot.silenceAnchor
        let silenceDays = snapshot.policy.silenceDays
        let previous = loadRecord(ownerHash: ownerHash)
        if let previous, previous.anchorEpoch == anchor.timeIntervalSince1970,
           previous.silenceDays == silenceDays {
            return   // nothing moved since the last time this ran
        }

        let center = UNUserNotificationCenter.current()
        if let previous, !previous.identifiers.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: previous.identifiers)
        }

        // The record is written FIRST, so a failure to add a request does not
        // turn every later refresh into another attempt to add it.
        var record = Record(anchorEpoch: anchor.timeIntervalSince1970, silenceDays: silenceDays, identifiers: [])
        var pending: [(id: String, level: Level, fireIn: TimeInterval)] = []
        for level in Level.allCases {
            let fireAt = anchor.addingTimeInterval(level.offset(silenceDays: silenceDays))
            let fireIn = fireAt.timeIntervalSince(engine.now)
            guard fireIn > 60 else { continue }   // the trigger refuses a non positive interval
            let id = identifier(estateID: estate.id, level: level)
            record.identifiers.append(id)
            pending.append((id, level, fireIn))
        }
        saveRecord(record, ownerHash: ownerHash)
        guard !pending.isEmpty else { return }

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else {
            log.info("owner notices: \(pending.count, privacy: .public) held back, notifications are not allowed")
            return
        }

        for item in pending {
            let content = UNMutableNotificationContent()
            content.title = "Seal"
            content.body = line(for: item.level, silenceDays: silenceDays)
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: item.fireIn, repeats: false)
            let request = UNNotificationRequest(identifier: item.id, content: content, trigger: trigger)
            do {
                try await center.add(request)
                log.info("owner notices: scheduled \(item.id, privacy: .public) in \(Int(item.fireIn / 86_400), privacy: .public) days")
            } catch {
                log.error("owner notices: could not schedule \(item.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - A key holder has a new device

    //  The other thing the owner has to do while alive, and the one thing
    //  the app cannot do for them in the background. A key holder who
    //  endorses a new device holds a share that device cannot open
    //  (EstateEngine.custodiansWithNewPhones). The repair is a new epoch,
    //  which is a seal, and a seal also publishes every draft and rule
    //  change waiting on this phone, so it waits for the owner's tap. The
    //  Keys tab already shows the card with the button; this is the line
    //  for an owner who does not open that tab, or whose phone noticed on
    //  a push while it sat in a pocket.
    //
    //  Posted at once, not scheduled, and once per change: the keychain
    //  keeps which people it last spoke about, per estate and epoch, so a
    //  second refresh says nothing and a seal (which clears the list) takes
    //  the line off the lock screen. Recipients never get a line: their
    //  wraps are repaired quietly (EstateEngine.coverNewRecipientDevices).

    private static func newDeviceKey(_ ownerHash: String) -> String { "seal.ownernotices.newdevice.\(ownerHash)" }

    /// The prefix SealApp's notification delegate routes to the Keys tab.
    static let newDeviceIdentifierPrefix = "seal.owner.newdevice."

    private static func newDeviceIdentifier(estateID: String) -> String {
        newDeviceIdentifierPrefix + estateID
    }

    /// "Riley", "Riley and Sam", "Riley, Sam, and Ana".
    static func joinedNames(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + ", and " + (names.last ?? "")
        }
    }

    static func newDeviceLine(names: [String]) -> String {
        let who = joinedNames(names)
        return names.count == 1
            ? "\(who) has a new device. Their piece of your key does not work on it yet. Open Seal and tap Seal again to give them a fresh one."
            : "\(who) have new devices. Their pieces of your key do not work on them yet. Open Seal and tap Seal again to give them fresh ones."
    }

    /// Called after every heartbeat, which has just refreshed
    /// `custodiansWithNewPhones`.
    static func postNewKeyHolderDevices(engine: EstateEngine, ownerHash: String) async {
        guard !DemoFixtures.isActive else { return }
        guard let estate = engine.estate, estate.epochPublished else { return }
        let center = UNUserNotificationCenter.current()
        let id = newDeviceIdentifier(estateID: estate.id)
        let people = engine.custodiansWithNewPhones
        guard !people.isEmpty else {
            // Sealed since, or the device went away: nothing to ask for.
            if KeychainStore.load(newDeviceKey(ownerHash)) != nil {
                KeychainStore.delete(newDeviceKey(ownerHash))
                center.removeDeliveredNotifications(withIdentifiers: [id])
            }
            return
        }
        let signature = "\(estate.id)|\(estate.epoch)|" + people.map(\.rootHash).sorted().joined(separator: ",")
        if let saved = KeychainStore.load(newDeviceKey(ownerHash)),
           String(decoding: saved, as: UTF8.self) == signature {
            return   // already said
        }
        // Written FIRST, as with the reminders above: the banner below
        // brings the app forward and refreshes again, and that refresh must
        // find this already said.
        KeychainStore.save(Data(signature.utf8), for: newDeviceKey(ownerHash))

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else {
            log.info("owner notices: new device line held back, notifications are not allowed")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Seal"
        content.body = newDeviceLine(names: people.map(\.displayName))
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        do {
            try await center.add(request)
            log.info("owner notices: posted new device line for \(people.count, privacy: .public) key holder(s)")
        } catch {
            log.error("owner notices: could not post new device line: \(error.localizedDescription, privacy: .public)")
        }
    }
}
