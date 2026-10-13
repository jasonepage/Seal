// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import UserNotifications
import os

//  WeeklyQuestion.swift
//  Seal
//
//  ONE QUESTION A WEEK (PRODUCT.md section 13).
//
//  Once a week the phone shows one notification that names nobody. Tapping
//  it opens one question about one person. The answer is drafted on the
//  phone and goes into that person's envelope as a draft paragraph; the
//  owner taps Seal right there, or not. Opening the question, even to skip
//  it, is the week's heartbeat.
//
//  This file is the schedule and the rotation. It is pure except for the
//  keychain record and the two local notifications, both modelled on
//  SecretReview. No model, no network, no cryptography. The screen and
//  the append live elsewhere.
//
//  THE RULES, IN CODE:
//  - Week one is always "know-first" for the first envelope in the vault.
//  - After that, the envelope that has waited longest gets the next turn.
//  - For that envelope, a question not asked in six months is eligible;
//    "do-first" is eligible again after a year on purpose. Never-asked
//    questions come first, in list order. If nothing is eligible, the
//    least recently asked question is used (the one-recipient case).
//  - Secret questions are never in the weekly set. See `InterviewQuestions.weekly`.
//  - One notification a week, one reminder two days later if it was not
//    opened, then silence until next week.
//  - Nothing runs for a released set, a demo, or a vault with no envelopes.

enum WeeklyQuestion {

    private static let log = Logger(subsystem: "io.github.jasonepage.Seal", category: "notices")

    static let day: TimeInterval = 86_400
    /// A question is not asked of the same person again inside this.
    static let repeatAfter: TimeInterval = 180 * day
    /// Except this one (`InterviewQuestions.refreshableID`).
    static let refreshAfter: TimeInterval = 365 * day
    /// The reminder, if the question was not opened.
    static let reminderAfter: TimeInterval = 2 * day

    // MARK: - The record

    /// One question, offered to one envelope, on one date. Kept until it
    /// is opened so the notification and the screen agree on which one.
    struct Pick: Codable, Equatable {
        var envelopeID: String
        var questionID: String
        var offeredAt: Date
    }

    /// Per owner. Keychain JSON like every other store; wiped by
    /// ContentView.wipeLocalAndEngines.
    struct Settings: Codable, Equatable {
        /// 1 = Sunday ... 7 = Saturday, as `Calendar` counts them. Tuesday.
        var weekday: Int = 3
        var hour: Int = 8
        /// envelopeID -> questionID -> when it was last asked.
        var asked: [String: [String: Date]] = [:]
        /// The question waiting right now, if any.
        var pending: Pick? = nil
        /// What was last scheduled, so a quiet refresh does nothing.
        var scheduledFor: Date? = nil

        private enum Keys: String, CodingKey { case weekday, hour, asked, pending, scheduledFor }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            weekday = try c.decodeIfPresent(Int.self, forKey: .weekday) ?? 3
            hour = try c.decodeIfPresent(Int.self, forKey: .hour) ?? 8
            asked = try c.decodeIfPresent([String: [String: Date]].self, forKey: .asked) ?? [:]
            pending = try c.decodeIfPresent(Pick.self, forKey: .pending)
            scheduledFor = try c.decodeIfPresent(Date.self, forKey: .scheduledFor)
        }

        /// When this envelope was last asked anything. Nil if never.
        func lastAsked(envelopeID: String) -> Date? {
            asked[envelopeID]?.values.max()
        }

        func lastAsked(envelopeID: String, questionID: String) -> Date? {
            asked[envelopeID]?[questionID]
        }

        var hasEverAsked: Bool { !asked.isEmpty }
    }

    private static func key(_ ownerHash: String) -> String { "seal.weekly.\(ownerHash)" }
    private static func identifier(_ ownerHash: String) -> String { "seal.owner.weekly.\(ownerHash)" }
    private static func reminderIdentifier(_ ownerHash: String) -> String { "seal.owner.weekly.reminder.\(ownerHash)" }

    static func load(ownerHash: String) -> Settings {
        guard let data = KeychainStore.load(key(ownerHash)),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    static func save(_ settings: Settings, ownerHash: String) {
        if let data = try? JSONEncoder().encode(settings) {
            _ = KeychainStore.save(data, for: key(ownerHash))
        }
    }

    static func wipe(ownerHash: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [identifier(ownerHash), reminderIdentifier(ownerHash)])
        KeychainStore.delete(key(ownerHash))
    }

    // MARK: - Rotation (pure)

    /// What the rotation needs to know about an envelope. Built from
    /// `Envelope` by the caller so this stays testable without an estate.
    struct Candidate: Equatable {
        var envelopeID: String
        var createdAt: Date
    }

    /// Which envelope gets this week. The one that has waited longest;
    /// never-asked envelopes first, oldest first, so week one goes to the
    /// first person the owner wrote to.
    static func nextEnvelope(_ candidates: [Candidate], settings: Settings) -> Candidate? {
        guard !candidates.isEmpty else { return nil }
        let never = candidates.filter { settings.lastAsked(envelopeID: $0.envelopeID) == nil }
        if let first = never.min(by: { $0.createdAt < $1.createdAt }) { return first }
        return candidates.min { a, b in
            let la = settings.lastAsked(envelopeID: a.envelopeID) ?? .distantPast
            let lb = settings.lastAsked(envelopeID: b.envelopeID) ?? .distantPast
            if la != lb { return la < lb }
            return a.createdAt < b.createdAt
        }
    }

    /// Which question for that envelope. Week one is `weekOneID`. Then a
    /// never-asked question in list order; then one asked long enough ago;
    /// then, only when every question is inside its window, the least
    /// recently asked.
    static func nextQuestion(for envelopeID: String, settings: Settings, now: Date) -> InterviewQuestion? {
        let set = InterviewQuestions.weekly
        guard !set.isEmpty else { return nil }
        if !settings.hasEverAsked, let first = InterviewQuestions.weeklyQuestion(id: InterviewQuestions.weekOneID) {
            return first
        }
        if let never = set.first(where: { settings.lastAsked(envelopeID: envelopeID, questionID: $0.id) == nil }) {
            return never
        }
        let eligible = set.filter { q in
            guard let at = settings.lastAsked(envelopeID: envelopeID, questionID: q.id) else { return true }
            let window = q.id == InterviewQuestions.refreshableID ? refreshAfter : repeatAfter
            return now.timeIntervalSince(at) >= window
        }
        if let q = eligible.min(by: { a, b in
            (settings.lastAsked(envelopeID: envelopeID, questionID: a.id) ?? .distantPast)
                < (settings.lastAsked(envelopeID: envelopeID, questionID: b.id) ?? .distantPast)
        }) { return q }
        return set.min { a, b in
            (settings.lastAsked(envelopeID: envelopeID, questionID: a.id) ?? .distantPast)
                < (settings.lastAsked(envelopeID: envelopeID, questionID: b.id) ?? .distantPast)
        }
    }

    /// The pick for this week, or the one already waiting.
    static func pick(_ candidates: [Candidate], settings: Settings, now: Date) -> Pick? {
        if let pending = settings.pending, candidates.contains(where: { $0.envelopeID == pending.envelopeID }) {
            return pending
        }
        guard let envelope = nextEnvelope(candidates, settings: settings),
              let question = nextQuestion(for: envelope.envelopeID, settings: settings, now: now) else { return nil }
        return Pick(envelopeID: envelope.envelopeID, questionID: question.id, offeredAt: now)
    }

    /// The owner opened the question. Answered or skipped, it is asked:
    /// a skipped week leaves no paragraph and no second nag, and it still
    /// counts, because the heartbeat measures being alive, not output.
    static func markOpened(_ pick: Pick, settings: inout Settings, now: Date) {
        var row = settings.asked[pick.envelopeID] ?? [:]
        row[pick.questionID] = now
        settings.asked[pick.envelopeID] = row
        settings.pending = nil
    }

    // MARK: - When (pure)

    /// The next weekday-and-hour strictly after `after`, in the phone's
    /// calendar. Minutes and seconds are zero.
    static func nextSlot(after: Date, weekday: Int, hour: Int, calendar: Calendar = .current) -> Date {
        var parts = DateComponents()
        parts.weekday = weekday
        parts.hour = hour
        parts.minute = 0
        parts.second = 0
        return calendar.nextDate(after: after, matching: parts, matchingPolicy: .nextTime, direction: .forward) ?? after.addingTimeInterval(7 * day)
    }

    /// When the next question is owed. A week after the last one was
    /// opened, landing on the chosen weekday; or the next slot from now
    /// if nothing has been asked yet.
    static func nextDue(_ settings: Settings, now: Date, calendar: Calendar = .current) -> Date {
        let floor: Date
        if let last = settings.asked.values.flatMap({ $0.values }).max() {
            floor = max(now, last.addingTimeInterval(6 * day))
        } else {
            floor = now
        }
        return nextSlot(after: floor, weekday: settings.weekday, hour: settings.hour, calendar: calendar)
    }

    /// True when a question is waiting to be opened now.
    static func isDue(_ settings: Settings, now: Date) -> Bool {
        if let pending = settings.pending { return now >= pending.offeredAt }
        return false
    }

    // MARK: - The notification

    /// Called after every heartbeat, like SecretReview. Decides this
    /// week's pick if one is owed, stores it, and schedules the one
    /// notification (plus one reminder) at the next due date. Nothing is
    /// scheduled for a released set, a demo, or a vault with no envelopes.
    static func schedule(engine: EstateEngine, ownerHash: String, now: Date) async {
        guard !DemoFixtures.isActive else { return }
        let center = UNUserNotificationCenter.current()
        var settings = load(ownerHash: ownerHash)

        let candidates = (engine.estate?.envelopes ?? []).map { Candidate(envelopeID: $0.id, createdAt: $0.createdAt) }
        let active = engine.estate?.epochPublished == true
            && engine.ownerSnapshot?.releasedAt == nil
            && engine.ownerSnapshot?.keyPublishedAt == nil
            && !candidates.isEmpty
        guard active else {
            if settings.scheduledFor != nil || settings.pending != nil {
                center.removePendingNotificationRequests(withIdentifiers: [identifier(ownerHash), reminderIdentifier(ownerHash)])
                settings.scheduledFor = nil
                settings.pending = nil
                save(settings, ownerHash: ownerHash)
            }
            return
        }

        // A pending pick whose envelope is gone is dropped.
        if let p = settings.pending, !candidates.contains(where: { $0.envelopeID == p.envelopeID }) {
            settings.pending = nil
        }

        let due = settings.pending?.offeredAt ?? nextDue(settings, now: now)
        if settings.pending == nil {
            // Decide now so the notification and the screen agree.
            settings.pending = pick(candidates, settings: settings, now: due)
        }
        if settings.scheduledFor == due { return }
        settings.scheduledFor = due
        save(settings, ownerHash: ownerHash)
        center.removePendingNotificationRequests(withIdentifiers: [identifier(ownerHash), reminderIdentifier(ownerHash)])

        let fireIn = due.timeIntervalSince(now)
        guard fireIn > 60 else { return }   // the app is open; the home screen says it
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }

        for (id, body, delay) in [(identifier(ownerHash), InterviewQuestions.Weekly.notification, fireIn),
                                  (reminderIdentifier(ownerHash), InterviewQuestions.Weekly.reminder, fireIn + reminderAfter)] {
            let content = UNMutableNotificationContent()
            content.title = "Seal"
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: id, content: content,
                                                trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false))
            do { try await center.add(request) } catch {
                log.error("weekly question: could not schedule: \(error.localizedDescription, privacy: .public)")
            }
        }
        log.info("weekly question: scheduled in \(Int(fireIn / 86_400), privacy: .public) days")
    }

    /// The owner opened this week's question. Clears the reminder, records
    /// the ask, saves. The caller runs the heartbeat.
    static func opened(ownerHash: String, now: Date) {
        var settings = load(ownerHash: ownerHash)
        guard let pending = settings.pending else { return }
        markOpened(pending, settings: &settings, now: now)
        settings.scheduledFor = nil
        save(settings, ownerHash: ownerHash)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [reminderIdentifier(ownerHash)])
    }
}
