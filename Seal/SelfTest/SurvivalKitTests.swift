// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

//  SurvivalKitTests.swift
//  Seal
//
//  The printed page must say the true numbers and nothing it was not
//  given. It is built from two names, the rule and a date, so the test is
//  mostly about the words.

enum SurvivalKitTests {

    static var suites: [SelfTest.Suite] { [
        .init(name: "survivalkit.words") { try words($0) },
        .init(name: "survivalkit.renders") { try renders($0) },
    ] }

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func words(_ t: SelfTest.Context) throws {
        var policy = ReleasePolicy(threshold: 2)
        policy.silenceDays = 180; policy.warningDays = 30; policy.graceDays = 7
        let c = SurvivalKit.content(ownerName: "Nathan", custodianName: "Karen Page", policy: policy,
                                    custodianCount: 3, printedOn: t0)
        let text = c.allText
        t.check(text.contains("Nathan"), "names the owner")
        t.check(text.contains("Karen Page"), "names the key holder")
        t.check(text.contains("180 days"), "says the silence days")
        t.check(text.contains("30 days"), "says the warning days")
        t.check(text.contains("7 days"), "says the grace days")
        t.check(text.contains("2 of 3 key holders"), "says the threshold in plain words")
        t.check(!text.contains("verify_capsule.py"), "the verifier is not on the page (cut 2026-09-16)")
        t.check(text.contains(SurvivalKit.howItWorksURL), "points at how it works")
        t.check(!text.contains("\u{2014}"), "no em dash")
        t.check(!text.lowercased().contains("custodian"), "the user facing word is key holder")

        let one = SurvivalKit.content(ownerName: "Nathan", custodianName: "Karen", policy: ReleasePolicy(threshold: 1),
                                      custodianCount: 1, printedOn: t0)
        t.check(one.allText.contains("only key holder"), "one of one reads right")
        let anyOne = SurvivalKit.content(ownerName: "", custodianName: "", policy: ReleasePolicy(threshold: 1),
                                         custodianCount: 3, printedOn: t0)
        t.check(anyOne.allText.contains("Any one key holder is enough"), "one of three reads right")
        t.check(anyOne.allText.contains("the owner"), "an empty owner name falls back to plain words")
    }

    static func renders(_ t: SelfTest.Context) throws {
        let c = SurvivalKit.content(ownerName: "Nathan", custodianName: "Karen", policy: ReleasePolicy(threshold: 2),
                                    custodianCount: 3, printedOn: t0)
        let pdf = SurvivalKit.render(c)
        t.check(pdf.count > 2_000, "the PDF has bytes in it: \(pdf.count)")
        t.check(pdf.starts(with: Data("%PDF".utf8)), "it is a PDF")
        t.check(SurvivalKit.qrImage(SurvivalKit.howItWorksURL, size: 96) != nil, "the QR code renders")
    }
}
