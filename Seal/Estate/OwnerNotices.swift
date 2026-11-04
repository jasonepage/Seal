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

    // MARK: - The "I'm still here" button (1.3)

    //  Each check-in reminder carries one button. Like Siri and the widget
    //  (CheckInIntent.swift), it only opens the app: the check-in is signed
    //  by a key that works only while the phone is unlocked, and opening
    //  the app IS the check-in. So the button is marked foreground and
    //  authentication required. iOS asks for Face ID or the passcode if the
    //  phone is locked, Seal comes up, and the home screen says it is done.
    //  Nothing is written in the background, nothing goes around the app
    //  lock, and no new code signs anything.

    /// Every check-in reminder's identifier starts with this. SealApp's
    /// notification delegate routes a tap on one, or on its button, to the
    /// same flag the Siri check-in sets.
    static let checkInIdentifierPrefix = "seal.owner.checkin."
    static let checkInCategory = "seal.owner.checkin"
    static let checkInAction = "seal.owner.checkin.now"

    /// Called once at launch. Seal has no other notification categories,
    /// so setting the whole list here replaces nothing.
    static func registerCategories() {
        let here = UNNotificationAction(identifier: checkInAction,
                                        title: "I'm still here",
                                        options: [.foreground, .authenticationRequired])
        let category = UNNotificationCategory(identifier: checkInCategory,
                                              actions: [here],
                                              intentIdentifiers: [],
                                              options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

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
        if let claim = loadClaimRecord(ownerHash: ownerHash), !claim.identifiers.isEmpty {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: claim.identifiers)
        }
        KeychainStore.delete(claimKey(ownerHash))
    }

    private static func identifier(estateID: String, level: Level) -> String {
        "\(checkInIdentifierPrefix)\(estateID).\(level.rawValue)"
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

    /// The days right after the quiet period ends (1.3). The phone cannot
    /// know whether a key holder has started a claim yet, so it says only
    /// what is true either way.
    static let afterSilenceLine = "Your quiet time is over, so a key holder can now start opening your envelopes. If you are here, open Seal once. That stops everything."

    /// How many daily lines follow the end of the quiet period. A claim
    /// started right away is the case that most needs a loud phone.
    static let afterSilenceDays = 7

    // MARK: - Scheduling

    /// Called after every heartbeat. Reads the owner's snapshot and the
    /// policy that governs it, and (re)schedules the reminders that are
    /// still in the future. Levels already in the past are dropped, not
    /// posted: the owner is holding the phone right now, which is the
    /// check-in itself.
    static func schedule(engine: EstateEngine, ownerHash: String) async {
        guard !DemoFixtures.isActive else { return }
        // Only a quiet rule has a silence to remind anyone about. Break glass
        // has none, and a right away rule never releases (PRODUCT.md
        // section 17); their check-in lines would be false.
        guard let estate = engine.estate, estate.epochPublished, estate.policy.kind == .quiet,
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
        var pending: [(id: String, body: String, fireIn: TimeInterval)] = []
        for level in Level.allCases {
            let fireAt = anchor.addingTimeInterval(level.offset(silenceDays: silenceDays))
            let fireIn = fireAt.timeIntervalSince(engine.now)
            guard fireIn > 60 else { continue }   // the trigger refuses a non positive interval
            let id = identifier(estateID: estate.id, level: level)
            record.identifiers.append(id)
            pending.append((id, line(for: level, silenceDays: silenceDays), fireIn))
        }
        // One line a day for a week after the quiet period ends (1.3). These
        // are scheduled now, while the app runs, so they fire even if the
        // push about a claim is late or never wakes the app. The next
        // heartbeat replaces them like the three above.
        let silenceEnds = anchor.addingTimeInterval(snapshot.policy.silence)
        for day in 0..<afterSilenceDays {
            let fireAt = silenceEnds.addingTimeInterval(TimeInterval(day) * 86_400 + 3_600)
            let fireIn = fireAt.timeIntervalSince(engine.now)
            guard fireIn > 60 else { continue }
            let id = "\(checkInIdentifierPrefix)\(estate.id).after.\(day)"
            record.identifiers.append(id)
            pending.append((id, afterSilenceLine, fireIn))
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
            content.body = item.body
            content.sound = .default
            content.categoryIdentifier = checkInCategory
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

    // MARK: - A claim on the owner's own envelopes (1.3)

    //  THE PROMISE THIS KEEPS. Key holders, the rule screen and the printed
    //  page all say the owner "is warned every day" once a claim starts.
    //  Before 1.3 nothing on the owner's phone did that: the reminders above
    //  fire before the quiet period ends, and the claim itself reached this
    //  phone only as a silent push. Now any refresh that finds a live claim
    //  on one of the owner's own rules (a push wake, an open) says so at
    //  once and schedules one line a day until keys can be tapped. Opening
    //  the app stops the claim, and the next refresh takes the rest of the
    //  lines off the phone.
    //
    //  The schedule matters more than the first line. A silent push can be
    //  late, throttled, or never reach an app that was swiped away. Once the
    //  lines are scheduled they fire whether or not the app runs again.
    //
    //  The identifiers sit under the check-in prefix, so each line carries
    //  the "I'm still here" button and a tap on it is a check-in.

    private static func claimKey(_ ownerHash: String) -> String { "seal.ownernotices.claim.\(ownerHash)" }

    private struct ClaimRecord: Codable {
        var claimID: String
        var identifiers: [String]
    }

    private static func loadClaimRecord(ownerHash: String) -> ClaimRecord? {
        guard let data = KeychainStore.load(claimKey(ownerHash)) else { return nil }
        return try? JSONDecoder().decode(ClaimRecord.self, from: data)
    }

    /// At most this many daily lines, so a long warning period cannot crowd
    /// out the phone's 64 pending notifications.
    private static let claimDailyCap = 21

    static let claimStartedLine = "A key holder has started opening your envelopes. If you are here, open Seal. One open stops it, and you do not need your key."

    static func claimDailyLine(daysLeft: Int) -> String {
        let when = daysLeft <= 1 ? "as soon as tomorrow" : "in about \(daysLeft) days"
        return "Your key holders are still waiting to open your envelopes. If you are here, open Seal once to stop it. Keys can be tapped \(when)."
    }

    /// Called after every refresh, for each of the owner's rules.
    static func postClaimWarnings(engine: EstateEngine, ownerHash: String) async {
        guard !DemoFixtures.isActive else { return }
        let center = UNUserNotificationCenter.current()
        let previous = loadClaimRecord(ownerHash: ownerHash)

        guard let estate = engine.estate, estate.epochPublished,
              let snapshot = engine.ownerSnapshot, let claim = snapshot.claim,
              let state = engine.ownerState, state.claimIsLive else {
            // No live claim: take any lines still waiting off the phone.
            if let previous {
                center.removePendingNotificationRequests(withIdentifiers: previous.identifiers)
                KeychainStore.delete(claimKey(ownerHash))
            }
            return
        }
        // Already told, already scheduled.
        if previous?.claimID == claim.id { return }
        if let previous {
            center.removePendingNotificationRequests(withIdentifiers: previous.identifiers)
        }

        let now = engine.now
        let tapsFrom = ReleaseMachine.timeline(snapshot, now: now)?.claimOpensAt
        let base = "\(checkInIdentifierPrefix)claim.\(estate.id).\(claim.id)"
        // Break glass (PRODUCT.md section 17): there is nothing to stop and no
        // countdown, so one plain line and no daily ones.
        if snapshot.policy.kind == .breakGlass {
            let line = "A key holder started your break glass rule. It opens as soon as enough of them tap their keys."
            let record = ClaimRecord(claimID: claim.id, identifiers: ["\(base).now"])
            if let data = try? JSONEncoder().encode(record) { KeychainStore.save(data, for: claimKey(ownerHash)) }
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = "Seal"
            content.body = line
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: "\(base).now", content: content, trigger: nil))
            return
        }
        var items: [(id: String, body: String, fireIn: TimeInterval?)] = [("\(base).now", claimStartedLine, nil)]
        if let tapsFrom {
            for day in 1...claimDailyCap {
                let fireAt = now.addingTimeInterval(TimeInterval(day) * 86_400)
                guard fireAt < tapsFrom else { break }
                let daysLeft = Int((tapsFrom.timeIntervalSince(fireAt) / 86_400).rounded(.up))
                items.append(("\(base).\(day)", claimDailyLine(daysLeft: daysLeft), fireAt.timeIntervalSince(now)))
            }
        }

        // The record is written FIRST, as everywhere in this file, so six
        // refreshes an hour cannot turn one claim into six alerts.
        let record = ClaimRecord(claimID: claim.id, identifiers: items.map { $0.id })
        if let data = try? JSONEncoder().encode(record) {
            KeychainStore.save(data, for: claimKey(ownerHash))
        }

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else {
            log.info("owner notices: claim lines held back, notifications are not allowed")
            return
        }

        for item in items {
            let content = UNMutableNotificationContent()
            content.title = "Seal"
            content.body = item.body
            content.sound = .default
            content.categoryIdentifier = checkInCategory
            // A no-op until the time-sensitive entitlement is added; see
            // CustodianNotices for why it is left in.
            content.interruptionLevel = .timeSensitive
            let trigger = item.fireIn.map { UNTimeIntervalNotificationTrigger(timeInterval: max($0, 61), repeats: false) }
            let request = UNNotificationRequest(identifier: item.id, content: content, trigger: trigger)
            do {
                try await center.add(request)
            } catch {
                log.error("owner notices: could not add \(item.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        log.info("owner notices: claim \(claim.id, privacy: .public) announced, \(items.count - 1, privacy: .public) daily lines")
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
