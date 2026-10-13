// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

//  WeeklyQuestionTests.swift
//  Seal
//
//  The rotation and the schedule, pure (PRODUCT.md section 13, build
//  order step 6). No keychain, no notifications, a fixed clock.

enum WeeklyQuestionTests {

    static var suites: [SelfTest.Suite] { [
        .init(name: "weekly.set") { try set($0) },
        .init(name: "weekly.weekOne") { try weekOne($0) },
        .init(name: "weekly.rotation") { try rotation($0) },
        .init(name: "weekly.sixMonths") { try sixMonths($0) },
        .init(name: "weekly.oneRecipient") { try oneRecipient($0) },
        .init(name: "weekly.skipCounts") { try skipCounts($0) },
        .init(name: "weekly.when") { try when($0) },
        .init(name: "weekly.settingsDecode") { try settingsDecode($0) },
    ] }

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let day: TimeInterval = 86_400
    static let week: TimeInterval = 7 * 86_400

    static let three = [
        WeeklyQuestion.Candidate(envelopeID: "karen", createdAt: t0),
        WeeklyQuestion.Candidate(envelopeID: "emma", createdAt: t0.addingTimeInterval(60)),
        WeeklyQuestion.Candidate(envelopeID: "jason", createdAt: t0.addingTimeInterval(120)),
    ]

    static func set(_ t: SelfTest.Context) throws {
        let set = InterviewQuestions.weekly
        t.equal(set.count, 14, "fourteen weekly questions")
        t.check(set.allSatisfy { $0.target.isLetter }, "every weekly question is a letter question, never a secret")
        t.equal(Set(set.map(\.id)).count, set.count, "ids are unique")
        t.check(InterviewQuestions.weeklyQuestion(id: InterviewQuestions.weekOneID) != nil, "week one exists in the set")
        t.check(InterviewQuestions.weeklyQuestion(id: InterviewQuestions.refreshableID) != nil, "the refreshable one exists in the set")
        for q in set {
            t.check(!q.text.contains("\u{2014}") && !(q.hint ?? "").contains("\u{2014}"), "no em dash in \(q.id)")
        }
        for s in [InterviewQuestions.Weekly.notification, InterviewQuestions.Weekly.reminder, InterviewQuestions.Weekly.stays] {
            t.check(!s.contains("\u{2014}"), "no em dash in weekly copy")
        }
        t.check(!InterviewQuestions.Weekly.notification.lowercased().contains("karen"), "the notification names nobody")
    }

    static func weekOne(_ t: SelfTest.Context) throws {
        let s = WeeklyQuestion.Settings()
        let p = WeeklyQuestion.pick(three, settings: s, now: t0)
        t.equal(p?.envelopeID, "karen", "week one goes to the first envelope")
        t.equal(p?.questionID, InterviewQuestions.weekOneID, "week one is always know-first")
    }

    static func rotation(_ t: SelfTest.Context) throws {
        var s = WeeklyQuestion.Settings()
        var now = t0
        var order: [String] = []
        for _ in 0..<6 {
            guard let p = WeeklyQuestion.pick(three, settings: s, now: now) else { t.fail("no pick"); return }
            order.append(p.envelopeID)
            WeeklyQuestion.markOpened(p, settings: &s, now: now)
            now = now.addingTimeInterval(week)
        }
        t.equal(order, ["karen", "emma", "jason", "karen", "emma", "jason"], "envelopes take turns, longest wait first")
        t.check(s.pending == nil, "opening clears the pending pick")
    }

    static func sixMonths(_ t: SelfTest.Context) throws {
        // Two recipients, 28 weeks: no person hears the same question twice.
        let two = Array(three.prefix(2))
        var s = WeeklyQuestion.Settings()
        var now = t0
        var seen: [String: [String]] = [:]
        for _ in 0..<28 {
            guard let p = WeeklyQuestion.pick(two, settings: s, now: now) else { t.fail("no pick"); return }
            seen[p.envelopeID, default: []].append(p.questionID)
            WeeklyQuestion.markOpened(p, settings: &s, now: now)
            now = now.addingTimeInterval(week)
        }
        for (env, qs) in seen {
            t.equal(Set(qs).count, qs.count, "no repeat for \(env) in 28 weeks with two recipients")
            t.equal(qs.count, 14, "\(env) heard all fourteen")
        }
    }

    static func oneRecipient(_ t: SelfTest.Context) throws {
        let one = [three[0]]
        var s = WeeklyQuestion.Settings()
        var now = t0
        var qs: [String] = []
        for _ in 0..<15 {
            guard let p = WeeklyQuestion.pick(one, settings: s, now: now) else { t.fail("no pick"); return }
            qs.append(p.questionID)
            WeeklyQuestion.markOpened(p, settings: &s, now: now)
            now = now.addingTimeInterval(week)
        }
        t.equal(Set(qs.prefix(14)).count, 14, "fourteen distinct questions first")
        t.check(qs.count == 15, "week fifteen still asks something (the accepted repeat)")
        t.equal(qs[14], qs[0], "the repeat is the least recently asked, which is week one's")
    }

    static func skipCounts(_ t: SelfTest.Context) throws {
        var s = WeeklyQuestion.Settings()
        let p = WeeklyQuestion.pick(three, settings: s, now: t0)!
        s.pending = p
        t.check(WeeklyQuestion.isDue(s, now: t0), "a pending pick is due at its time")
        t.check(!WeeklyQuestion.isDue(s, now: t0.addingTimeInterval(-60)), "not before")
        // Skipping is markOpened with no answer: same record, no trace of content.
        WeeklyQuestion.markOpened(p, settings: &s, now: t0)
        t.equal(s.lastAsked(envelopeID: "karen", questionID: p.questionID), t0, "a skipped question is still asked")
        t.check(s.pending == nil, "and nothing is waiting")
        let again = WeeklyQuestion.pick(three, settings: s, now: t0.addingTimeInterval(week))
        t.equal(again?.envelopeID, "emma", "the next week moves on")
    }

    static func when(_ t: SelfTest.Context) throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        // t0 is Friday 2027-01-15 08:00 UTC.
        var s = WeeklyQuestion.Settings()   // Tuesday, 8
        let first = WeeklyQuestion.nextDue(s, now: t0, calendar: cal)
        let parts = cal.dateComponents([.weekday, .hour, .minute], from: first)
        t.equal(parts.weekday, 3, "lands on Tuesday")
        t.equal(parts.hour, 8, "at eight")
        t.equal(parts.minute, 0, "on the hour")
        t.check(first > t0 && first < t0.addingTimeInterval(week), "within a week")
        // Opened on that Tuesday: the next one is the Tuesday after, not the same day.
        s.asked["karen"] = ["know-first": first]
        let second = WeeklyQuestion.nextDue(s, now: first.addingTimeInterval(60), calendar: cal)
        t.equal(second.timeIntervalSince(first), week, "exactly a week later")
        // Opened late, on Saturday: still the following Tuesday, not the one in three days.
        s.asked["karen"] = ["know-first": first.addingTimeInterval(4 * day)]
        let third = WeeklyQuestion.nextDue(s, now: first.addingTimeInterval(4 * day), calendar: cal)
        t.equal(third.timeIntervalSince(first), 2 * week, "a late answer does not bring the next one closer than six days")
    }

    static func settingsDecode(_ t: SelfTest.Context) throws {
        let empty = try JSONDecoder().decode(WeeklyQuestion.Settings.self, from: Data("{}".utf8))
        t.equal(empty.weekday, 3, "default weekday is Tuesday")
        t.equal(empty.hour, 8, "default hour is eight")
        t.check(empty.pending == nil && empty.asked.isEmpty, "empty record")
        var s = WeeklyQuestion.Settings()
        s.pending = .init(envelopeID: "k", questionID: "q", offeredAt: t0)
        s.asked = ["k": ["q": t0]]
        let round = try JSONDecoder().decode(WeeklyQuestion.Settings.self, from: JSONEncoder().encode(s))
        t.equal(round, s, "round trips")
    }
}
