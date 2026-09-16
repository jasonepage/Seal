// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

//  SecretReviewTests.swift
//  Seal
//
//  The rule under test: saying a secret is still right changes nothing in
//  the sealed data. Plus the small pieces around it.

enum SecretReviewTests {

    static var suites: [SelfTest.Suite] { [
        .init(name: "secretreview.confirmDoesNotTouchPayload", run: confirmDoesNotTouchPayload),
        .init(name: "secretreview.keysAndStamps", run: keysAndStamps),
        .init(name: "secretreview.ageLines", run: ageLines),
        .init(name: "secretreview.schedule", run: schedule),
    ] }

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let day: TimeInterval = 86_400

    static func confirmDoesNotTouchPayload(_ t: SelfTest.Context) throws {
        var envelope = Envelope.new(recipientHash: "R", title: "For Karen", now: t0, revealOrder: 0)
        envelope.secrets = [try SealedCard.validated(cardType: .password, title: "Bank", value: "hunter2")]
        envelope.sealed = true
        let before = try EstateEvent.encodeBody(envelope.payload)
        let key = envelope.secrets[0].confirmationKey
        // What EstateEngine.confirmSecret does, on the model.
        envelope.secretConfirmations[key] = t0.addingTimeInterval(200 * day)
        let after = try EstateEvent.encodeBody(envelope.payload)
        t.equal(after, before, "confirming leaves the sealed payload byte for byte the same")
        t.check(envelope.sealed, "confirming does not unseal")
        t.equal(envelope.confirmedAt(envelope.secrets[0]), t0.addingTimeInterval(200 * day), "the confirmation date is read back")

        // The working copy keeps the date across a save; an older save
        // without the key still loads.
        let saved = try JSONEncoder().encode(envelope)
        let loaded = try JSONDecoder().decode(Envelope.self, from: saved)
        t.equal(loaded.secretConfirmations, envelope.secretConfirmations, "confirmations round trip in the keychain shape")
        let old = try JSONDecoder().decode(Envelope.self, from: try JSONEncoder().encode(Envelope.new(recipientHash: "R", title: "x", now: t0, revealOrder: 0)))
        t.check(old.secretConfirmations.isEmpty, "an envelope without confirmations decodes as none")
    }

    static func keysAndStamps(_ t: SelfTest.Context) throws {
        let a = try SealedCard.validated(cardType: .password, title: "Bank", value: "hunter2")
        let a2 = try SealedCard.validated(cardType: .password, title: "Bank", value: "hunter2", note: "different note")
        let b = try SealedCard.validated(cardType: .password, title: "Bank", value: "hunter3")
        t.equal(a.confirmationKey, a2.confirmationKey, "the note is not part of the key")
        t.check(a.confirmationKey != b.confirmationKey, "a changed value is a different secret")
        t.equal(a.confirmationKey.count, 64, "the key is a hex SHA-256")

        var envelope = Envelope.new(recipientHash: "R", title: "x", now: t0, revealOrder: 0)
        envelope.secrets = [a, b]
        envelope.stampNewSecrets(now: t0)
        t.equal(envelope.secretConfirmations.count, 2, "both new secrets are stamped")
        envelope.secrets = [b]
        envelope.stampNewSecrets(now: t0.addingTimeInterval(day))
        t.equal(envelope.secretConfirmations.count, 1, "a removed secret's stamp is dropped")
        t.equal(envelope.secretConfirmations[b.confirmationKey], t0, "a kept secret keeps its old stamp")
        t.equal(envelope.confirmedAt(a), envelope.updatedAt, "an unstamped secret is as old as the last save")
    }

    static func ageLines(_ t: SelfTest.Context) throws {
        t.equal(SecretAge.line(since: t0, now: t0), "Checked today", "today")
        t.equal(SecretAge.line(since: t0, now: t0.addingTimeInterval(day)), "Checked yesterday", "yesterday")
        t.equal(SecretAge.line(since: t0, now: t0.addingTimeInterval(5 * day)), "Checked 5 days ago", "days")
        t.equal(SecretAge.line(since: t0, now: t0.addingTimeInterval(21 * day)), "Checked 3 weeks ago", "weeks")
        t.equal(SecretAge.line(since: t0, now: t0.addingTimeInterval(210 * day)), "Checked 7 months ago", "months")
        t.equal(SecretAge.line(since: t0, now: t0.addingTimeInterval(400 * day)), "Checked a year ago", "a year")
        t.equal(SecretAge.line(since: t0, now: t0.addingTimeInterval(800 * day)), "Checked 2 years ago", "years")
        t.equal(SecretAge.line(since: t0.addingTimeInterval(day), now: t0), "Checked today", "a clock that went backwards is today, not negative")
        t.check(!SecretReview.line.contains("\u{2014}"), "no em dash in the reminder")
    }

    static func schedule(_ t: SelfTest.Context) throws {
        var s = SecretReview.Settings()
        t.equal(s.intervalMonths, 6, "the default is six months")
        t.check(!SecretReview.isDue(s, fallback: t0, now: t0.addingTimeInterval(100 * day)), "not due after 100 days")
        t.check(SecretReview.isDue(s, fallback: t0, now: t0.addingTimeInterval(181 * day)), "due after six months of thirty days")
        s.lastReviewedAt = t0.addingTimeInterval(150 * day)
        t.check(!SecretReview.isDue(s, fallback: t0, now: t0.addingTimeInterval(181 * day)), "a review resets the clock")
        s.intervalMonths = 3
        t.check(SecretReview.isDue(s, fallback: t0, now: t0.addingTimeInterval(241 * day)), "a shorter interval is honoured")
        let empty = try JSONDecoder().decode(SecretReview.Settings.self, from: Data("{}".utf8))
        t.equal(empty.intervalMonths, 6, "settings decode from an empty record")
    }
}
