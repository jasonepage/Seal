// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

//  FirstStepsTests.swift
//  Seal
//
//  "What to do first" rides inside the sealed payload, so what matters is
//  that it round trips, that a payload sealed before it existed still
//  opens, that the links to secrets stay honest when a secret is removed,
//  and that the estate in the keychain decodes without the newer keys.

enum FirstStepsTests {

    static var suites: [SelfTest.Suite] { [
        .init(name: "firststeps.payloadRoundTrip") { try payloadRoundTrip($0) },
        .init(name: "firststeps.oldPayloadOpens") { try oldPayloadOpens($0) },
        .init(name: "firststeps.secretLinks") { try secretLinks($0) },
        .init(name: "firststeps.oldEstateDecodes") { try oldEstateDecodes($0) },
        .init(name: "firststeps.starters") { try starters($0) },
        .init(name: "firststeps.videoInMedia") { try videoInMedia($0) },
        .init(name: "firststeps.openOnADate") { try openOnADate($0) },
    ] }

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func payloadRoundTrip(_ t: SelfTest.Context) throws {
        var envelope = Envelope.new(recipientHash: "R", title: "For Karen", now: t0, revealOrder: 0)
        envelope.secrets = [try SealedCard.validated(cardType: .password, title: "Credit union", value: "hunter2")]
        envelope.firstSteps = [
            FirstStep(title: "Call Mike at the credit union", note: "Ask for the estate desk.", secretIndex: 0),
            FirstStep(title: "The car title is in the blue folder in the garage"),
            FirstStep(title: "   "),   // a blank row the owner left behind
        ]
        let payload = envelope.payload
        t.equal(payload.firstSteps.count, 2, "blank steps are not sealed")
        let data = try EstateEvent.encodeBody(payload)
        let back = try JSONDecoder().decode(Envelope.Payload.self, from: data)
        t.equal(back, payload, "payload round trips through JSON")
        t.equal(back.firstSteps[0].secretIndex, 0, "the link to the secret survives")
        t.equal(back.firstSteps[0].note, "Ask for the estate desk.", "the note survives")

        // The working copy round trips too, including the blank row, which
        // is the owner's to fix and not the model's to drop silently.
        let saved = try JSONEncoder().encode(envelope)
        let loaded = try JSONDecoder().decode(Envelope.self, from: saved)
        t.equal(loaded, envelope, "envelope round trips through the keychain shape")
    }

    /// A payload blob sealed by a build that predates the steps has no
    /// "firstSteps" key. It must still open, as an envelope with no steps.
    static func oldPayloadOpens(_ t: SelfTest.Context) throws {
        let old = """
        {"letter":"Hello.","photos":[],"revealOrder":0,"secrets":[],"title":"For Karen","writtenAtEpoch":1800000000}
        """
        let payload = try JSONDecoder().decode(Envelope.Payload.self, from: Data(old.utf8))
        t.check(payload.firstSteps.isEmpty, "a payload without the key decodes as no steps")
        t.equal(payload.title, "For Karen", "the rest of the old payload is intact")
        t.check(payload.voiceNote == nil, "a missing voice note is still nil")
        t.check(payload.videoNote == nil, "a payload without a video decodes with none")
        t.check(payload.openNoEarlierThan == nil && !payload.isHeld(now: t0), "a payload without a date is never held")
    }

    /// "Open no earlier than" rides in the payload and only ever HOLDS an
    /// envelope on the recipient's phone. It has no way to open one: it
    /// touches no key, no table and no event.
    static func openOnADate(_ t: SelfTest.Context) throws {
        var envelope = Envelope.new(recipientHash: "R", title: "For your eighteenth", now: t0, revealOrder: 0)
        let birthday = t0.addingTimeInterval(3_000 * 86_400)
        envelope.openNoEarlierThan = birthday
        let payload = envelope.payload
        t.equal(payload.openNoEarlierThanEpoch, RecordEvent.epochSeconds(birthday), "the date is sealed as whole seconds")
        t.check(payload.isHeld(now: t0.addingTimeInterval(100 * 86_400)), "held before the date")
        t.check(payload.isHeld(now: birthday.addingTimeInterval(-1)), "held one second before")
        t.check(!payload.isHeld(now: birthday), "open on the day")
        t.check(!payload.isHeld(now: birthday.addingTimeInterval(365 * 86_400)), "open after")
        let back = try JSONDecoder().decode(Envelope.Payload.self, from: try EstateEvent.encodeBody(payload))
        t.equal(back.openNoEarlierThanEpoch, payload.openNoEarlierThanEpoch, "round trips")
        let saved = try JSONDecoder().decode(Envelope.self, from: try JSONEncoder().encode(envelope))
        t.equal(saved.openNoEarlierThan, birthday, "the working copy keeps the date")
        // Same blob ids, same content key, same secrets: nothing the date
        // could have reached into changed.
        var plain = envelope; plain.openNoEarlierThan = nil
        t.equal(plain.blobIDs, envelope.blobIDs, "the date touches no blob")
        t.equal(plain.contentKey, envelope.contentKey, "the date touches no key")
        t.check(!envelope.contentsSummary.contains("date"), "the home row does not announce it")
    }

    /// The video rides in the media list the engine encrypts and uploads.
    static func videoInMedia(_ t: SelfTest.Context) throws {
        var envelope = Envelope.new(recipientHash: "R", title: "x", now: t0, revealOrder: 0)
        let photo = MediaItem(blobID: "p", kind: .photo, sha256: Data(repeating: 1, count: 32), byteCount: 1, localName: "p")
        let voice = MediaItem(blobID: "a", kind: .voice, sha256: Data(repeating: 2, count: 32), byteCount: 1, localName: "a")
        let video = MediaItem(blobID: "v", kind: .video, sha256: Data(repeating: 3, count: 32), byteCount: 1, localName: "v")
        envelope.photos = [photo]; envelope.voiceNote = voice; envelope.videoNote = video
        t.equal(envelope.allMedia.map(\.blobID), ["p", "a", "v"], "photos, then voice, then video")
        t.check(envelope.blobIDs.contains("v"), "the video blob is in the key table's list")
        let back = try JSONDecoder().decode(Envelope.Payload.self, from: try EstateEvent.encodeBody(envelope.payload))
        t.equal(back.videoNote, video, "the video survives the payload round trip")
        t.check(envelope.contentsSummary.contains("a video"), "the summary names it: \(envelope.contentsSummary)")
    }

    static func secretLinks(_ t: SelfTest.Context) throws {
        var envelope = Envelope.new(recipientHash: "R", title: "For Karen", now: t0, revealOrder: 0)
        envelope.secrets = [
            try SealedCard.validated(cardType: .password, title: "A", value: "a"),
            try SealedCard.validated(cardType: .password, title: "B", value: "b"),
            try SealedCard.validated(cardType: .password, title: "C", value: "c"),
        ]
        envelope.firstSteps = [
            FirstStep(title: "needs A", secretIndex: 0),
            FirstStep(title: "needs B", secretIndex: 1),
            FirstStep(title: "needs C", secretIndex: 2),
            FirstStep(title: "needs nothing"),
        ]
        envelope.removeSecret(at: 1)
        t.equal(envelope.secrets.map(\.title), ["A", "C"], "the middle secret is gone")
        t.equal(envelope.firstSteps[0].secretIndex, 0, "a link below the removed secret is untouched")
        t.check(envelope.firstSteps[1].secretIndex == nil, "the link to the removed secret is dropped")
        t.equal(envelope.firstSteps[2].secretIndex, 1, "a link above the removed secret moves down by one")
        t.check(envelope.firstSteps[3].secretIndex == nil, "a step with no link stays that way")
        envelope.removeSecret(at: 9)
        t.equal(envelope.secrets.count, 2, "removing past the end does nothing")
    }

    /// The estate as a 2026-09-15 build saved it: none of the published*
    /// keys that were added on the 16th. It must load, not vanish.
    static func oldEstateDecodes(_ t: SelfTest.Context) throws {
        let old = """
        {"id":"E","ownerHash":"O","epoch":0,"policy":{"silenceDays":90,"warningDays":21,"graceDays":14,"threshold":1,"objectionBehavior":"pause"},"custodians":[],"recipients":[],"envelopes":[],"createdAt":0,"tableKeys":{},"epochPublished":false}
        """
        let estate = try JSONDecoder().decode(Estate.self, from: Data(old.utf8))
        t.equal(estate.id, "E", "an estate saved before the published* keys existed decodes")
        t.check(estate.publishedCustodianDevices.isEmpty, "missing publishedCustodianDevices is empty")
        t.equal(estate.publishedThreshold, 0, "missing publishedThreshold is zero")
        t.check(estate.publishedPolicy == nil, "missing publishedPolicy is nil")
        t.check(estate.needsNewEpoch, "an unpublished estate needs an epoch")
    }

    static func starters(_ t: SelfTest.Context) throws {
        let titles = FirstStep.starters.map(\.title)
        t.equal(Set(titles).count, titles.count, "starter titles are unique, they are the ids")
        for s in FirstStep.starters {
            t.check(!s.title.contains("\u{2014}") && !s.hint.contains("\u{2014}"), "no em dash in starter \(s.title)")
            t.check(s.title.count <= FirstStep.maxTitleCharacters, "starter title fits: \(s.title)")
        }
    }
}
