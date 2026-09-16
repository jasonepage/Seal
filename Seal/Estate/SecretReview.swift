// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import CryptoKit
import UserNotifications
import os

//  SecretReview.swift
//  Seal
//
//  SECRETS THAT GO STALE.
//
//  A password sealed in 2026 is wrong by 2029 and nobody knows. So each
//  secret remembers when the owner last said "still right", the editor
//  shows that age in plain words, and every six months (the owner can
//  change this) a local notification asks them to look the list over.
//
//  THE ONE RULE: confirming a secret changes nothing in the sealed data
//  and therefore never needs a re-seal. The confirmation date lives on the
//  owner's working copy of the envelope (`Envelope.secretConfirmations`),
//  keyed by a hash of the secret itself, and is NOT part of
//  `Envelope.Payload`. If the owner taps "Update" instead, they edit the
//  envelope the normal way, which marks it unsealed like any other edit,
//  and re-sealing is free.
//
//  The key is a hash of the secret's type, title and value. Change the
//  value and it is a different key, so a corrected secret starts its age
//  again on its own. The notification text never names a secret.

extension SealedCard {
    /// Stable name for "this exact secret" on the owner's phone. Not
    /// published anywhere.
    var confirmationKey: String {
        var bytes = Data()
        for field in [cardType.rawValue, title, value] {
            let d = Data(field.utf8)
            var n = UInt32(d.count).bigEndian
            bytes.append(Data(bytes: &n, count: 4))
            bytes.append(d)
        }
        return Data(SHA256.hash(data: bytes)).map { String(format: "%02x", $0) }.joined()
    }
}

extension Envelope {
    /// When the owner last said this secret is right. A secret the owner
    /// never confirmed by name is as old as the envelope's last save,
    /// which is the last time it was certainly looked at.
    func confirmedAt(_ card: SealedCard) -> Date {
        secretConfirmations[card.confirmationKey] ?? updatedAt
    }

    /// Any secret not yet in the map was just added or just changed, and
    /// adding it is confirming it. Called by the engine on every save.
    mutating func stampNewSecrets(now: Date) {
        for card in secrets where secretConfirmations[card.confirmationKey] == nil {
            secretConfirmations[card.confirmationKey] = now
        }
        // Drop entries for secrets that no longer exist, so the map never
        // grows past the list it describes.
        let live = Set(secrets.map(\.confirmationKey))
        secretConfirmations = secretConfirmations.filter { live.contains($0.key) }
    }
}

enum SecretAge {
    /// "Checked today", "Checked 3 weeks ago", "Checked 7 months ago".
    static func line(since: Date, now: Date) -> String {
        "Checked \(ago(since: since, now: now))"
    }

    static func ago(since: Date, now: Date) -> String {
        let days = max(0, Int(now.timeIntervalSince(since) / 86_400))
        switch days {
        case 0: return "today"
        case 1: return "yesterday"
        case 2..<14: return "\(days) days ago"
        case 14..<60: return "\(days / 7) weeks ago"
        case 60..<365: return "\(days / 30) months ago"
        case 365..<730: return "a year ago"
        default: return "\(days / 365) years ago"
        }
    }
}

// MARK: - The review schedule

/// Per owner: how often to ask, and when they last looked. Keychain JSON
/// like every other store; wiped by ContentView.wipeLocalAndEngines.
enum SecretReview {

    private static let log = Logger(subsystem: "io.github.jasonepage.Seal", category: "notices")

    static let allowedMonths = [3, 6, 12]
    static let defaultMonths = 6

    struct Settings: Codable, Equatable {
        var intervalMonths: Int = defaultMonths
        var lastReviewedAt: Date? = nil
        /// What was last scheduled, so a quiet refresh does nothing.
        var scheduledFor: Date? = nil

        private enum Keys: String, CodingKey { case intervalMonths, lastReviewedAt, scheduledFor }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            intervalMonths = try c.decodeIfPresent(Int.self, forKey: .intervalMonths) ?? SecretReview.defaultMonths
            lastReviewedAt = try c.decodeIfPresent(Date.self, forKey: .lastReviewedAt)
            scheduledFor = try c.decodeIfPresent(Date.self, forKey: .scheduledFor)
        }
    }

    private static func key(_ ownerHash: String) -> String { "seal.secretreview.\(ownerHash)" }
    private static func identifier(_ ownerHash: String) -> String { "seal.owner.secretreview.\(ownerHash)" }

    static func load(ownerHash: String) -> Settings {
        guard let data = KeychainStore.load(key(ownerHash)),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    static func save(_ settings: Settings, ownerHash: String) {
        if let data = try? JSONEncoder().encode(settings) {
            KeychainStore.save(data, for: key(ownerHash))
        }
    }

    static func wipe(ownerHash: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier(ownerHash)])
        KeychainStore.delete(key(ownerHash))
    }

    /// The interval in seconds. A month is taken as 30 days, which is
    /// close enough for "every six months".
    static func interval(months: Int) -> TimeInterval { TimeInterval(months) * 30 * 86_400 }

    /// When the next review is owed, measured from the last one, or from
    /// `fallback` (the estate's creation) if there has never been one.
    static func nextDue(_ settings: Settings, fallback: Date) -> Date {
        (settings.lastReviewedAt ?? fallback).addingTimeInterval(interval(months: settings.intervalMonths))
    }

    static func isDue(_ settings: Settings, fallback: Date, now: Date) -> Bool {
        now >= nextDue(settings, fallback: fallback)
    }

    /// The notification. Never names a secret, an envelope or a person.
    static let line = "Are your saved passwords still right? Open Seal and look them over. It takes a minute."

    /// Called after every heartbeat. Schedules the one reminder at the
    /// next due date, replacing the old one. Nothing is scheduled for a
    /// phone with no secrets, or when the due date is already past (the
    /// app is open, and the home screen says it instead).
    static func schedule(ownerHash: String, hasSecrets: Bool, estateCreatedAt: Date, now: Date) async {
        guard !DemoFixtures.isActive else { return }
        var settings = load(ownerHash: ownerHash)
        let center = UNUserNotificationCenter.current()
        guard hasSecrets else {
            if settings.scheduledFor != nil {
                center.removePendingNotificationRequests(withIdentifiers: [identifier(ownerHash)])
                settings.scheduledFor = nil
                save(settings, ownerHash: ownerHash)
            }
            return
        }
        let due = nextDue(settings, fallback: estateCreatedAt)
        if settings.scheduledFor == due { return }
        let fireIn = due.timeIntervalSince(now)
        settings.scheduledFor = due
        save(settings, ownerHash: ownerHash)
        center.removePendingNotificationRequests(withIdentifiers: [identifier(ownerHash)])
        guard fireIn > 60 else { return }

        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "Seal"
        content.body = line
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier(ownerHash), content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: fireIn, repeats: false))
        do {
            try await center.add(request)
            log.info("secret review: scheduled in \(Int(fireIn / 86_400), privacy: .public) days")
        } catch {
            log.error("secret review: could not schedule: \(error.localizedDescription, privacy: .public)")
        }
    }
}
