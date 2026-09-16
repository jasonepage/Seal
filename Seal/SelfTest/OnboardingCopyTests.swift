// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

//  OnboardingCopyTests.swift
//  Seal
//
//  THE SCRIPT, READ BY A MACHINE. The onboarding is a drawing with words
//  on it, and the words carry house rules that are easy to break with one
//  careless edit: no em dash, never "custodian" where a person reads it,
//  never the word "will", and at a threshold of 1 never a sentence that
//  tells the one key holder their key does nothing. Every check runs the
//  whole script at thresholds of 1, 2 and 3 and at 1, 2 and 3 key holders,
//  with real and default numbers, with a price and without one.
//
//  Pure: no view is built, no store is asked, no clock, no keychain.

enum OnboardingCopyTests {

    static var suites: [SelfTest.Suite] { [
        .init(name: "onboarding.bannedWords") { try bannedWords($0) },
        .init(name: "onboarding.pathShape") { try pathShape($0) },
        .init(name: "onboarding.uniqueIDs") { try uniqueIDs($0) },
        .init(name: "onboarding.priceSentence") { try priceSentence($0) },
        .init(name: "onboarding.thresholdOne") { try thresholdOne($0) },
        .init(name: "onboarding.figureLabels") { try figureLabels($0) },
    ] }

    /// A stand-in price. Letters on purpose: no number is typed into the
    /// app or its tests.
    static let fakePrice = "PRICE"

    /// Thresholds 1 to 3, key holder counts 1 to 3 (never fewer than the
    /// threshold), each as a real rule and as defaults, plus the edges the
    /// rule screen allows: one warning day and no grace days.
    static var numberSets: [OnboardingNumbers] {
        var out: [OnboardingNumbers] = []
        for threshold in 1...3 {
            for count in threshold...3 {
                for exact in [true, false] {
                    out.append(OnboardingNumbers(silenceDays: 90, warningDays: 21, graceDays: 14,
                                                 threshold: threshold, custodianCount: count, exact: exact))
                }
            }
        }
        out.append(OnboardingNumbers(silenceDays: 30, warningDays: 1, graceDays: 0,
                                     threshold: 1, custodianCount: 1, exact: true, custodyConfirmMonths: 6))
        out.append(OnboardingNumbers(silenceDays: 365, warningDays: 7, graceDays: 1,
                                     threshold: 2, custodianCount: 2, exact: true, custodyConfirmMonths: 24))
        return out
    }

    /// Everything a person can read on one screen.
    static func lines(_ s: OnboardingScreen) -> [String] {
        [s.title, s.body] + s.steps
    }

    /// Every screen of every path at every number set, with and without a
    /// price, plus the shared screens and the role buttons.
    static func everyLine() -> [(place: String, text: String)] {
        var out: [(String, String)] = []
        for s in OnboardingScript.shared() {
            for l in lines(s) { out.append(("shared/\(s.id)", l)) }
        }
        for r in OnboardingRole.allCases {
            out.append(("role/\(r.rawValue)/menu", r.menuTitle))
            out.append(("role/\(r.rawValue)/chooser", r.chooserTitle))
            out.append(("role/\(r.rawValue)/sub", r.chooserSub))
            out.append(("role/\(r.rawValue)/done", r.doneLabel))
        }
        for n in numberSets {
            for r in OnboardingRole.allCases {
                for price in [fakePrice, nil] {
                    for s in OnboardingScript.screens(for: r, numbers: n, price: price) {
                        let tag = "\(r.rawValue)/\(s.id) t\(n.threshold) c\(n.custodianCount) \(n.exact ? "real" : "default") \(price == nil ? "noprice" : "price")"
                        for l in lines(s) { out.append((tag, l)) }
                        out.append((tag + " label", s.figure.accessibilityLabel(n)))
                    }
                }
            }
        }
        return out
    }

    static func containsWholeWord(_ word: String, in text: String) -> Bool {
        text.range(of: "\\b\(word)\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: The checks

    static func bannedWords(_ t: SelfTest.Context) throws {
        let emDash = "\u{2014}"
        for (whereItIs, text) in everyLine() {
            t.check(!text.contains(emDash), "no em dash", whereItIs)
            t.check(text.range(of: "custodian", options: .caseInsensitive) == nil, "never custodian", whereItIs)
            t.check(!containsWholeWord("will", in: text), "never the word will", "\(whereItIs): \(text)")
            t.check(!text.contains("  "), "no double space", "\(whereItIs): \(text)")
            // "1 days" and "0 days" as whole numbers; "21 days" and "30
            // days" are fine.
            t.check(text.range(of: "(^|[^0-9])1 days", options: .regularExpression) == nil, "no 1 days", whereItIs)
            t.check(text.range(of: "(^|[^0-9])0 (day|days|more)", options: .regularExpression) == nil, "no 0 days", whereItIs)
        }
    }

    static func pathShape(_ t: SelfTest.Context) throws {
        for n in numberSets {
            for r in OnboardingRole.allCases {
                let screens = OnboardingScript.screens(for: r, numbers: n)
                t.check(screens.count >= 3, "at least three screens", "\(r.rawValue) t\(n.threshold) c\(n.custodianCount)")
                guard let last = screens.last else { continue }
                if r.isSealer {
                    t.check(last.figure.isSteps, "a sealer path ends on the steps", r.rawValue)
                    t.check(last.steps.count >= 3, "the checklist has steps", r.rawValue)
                } else {
                    t.check(last.figure.isKeep, "a key holder or recipient path ends on keep", r.rawValue)
                }
                for s in screens {
                    t.check(!s.title.isEmpty && !s.body.isEmpty, "title and body present", "\(r.rawValue)/\(s.id)")
                }
            }
        }
        t.equal(OnboardingScript.shared().count, OnboardingScript.sharedCount, "sharedCount matches the shared screens")
        t.check(OnboardingScript.screens(for: .couple, numbers: .defaults).contains { $0.id == "c.two" },
                "the couple path has its two phones screen")
    }

    static func uniqueIDs(_ t: SelfTest.Context) throws {
        var ids = OnboardingScript.shared().map(\.id)
        for r in OnboardingRole.allCases {
            ids += OnboardingScript.screens(for: r, numbers: .defaults).map(\.id)
        }
        t.equal(Set(ids).count, ids.count, "screen ids are unique across every path")
        // The ids must not move with the numbers, or the Chapters menu
        // would point at the wrong screen.
        for n in numberSets {
            var again = OnboardingScript.shared().map(\.id)
            for r in OnboardingRole.allCases {
                again += OnboardingScript.screens(for: r, numbers: n).map(\.id)
            }
            t.equal(again, ids, "ids do not depend on the numbers")
        }
    }

    static func priceSentence(_ t: SelfTest.Context) throws {
        let with = OnboardingScript.priceSentence(fakePrice)
        t.check(with.contains(fakePrice), "the price sentence shows the price")
        t.check(with.contains("once"), "the price sentence says once")
        let without = OnboardingScript.priceSentence(nil)
        t.check(without.contains("shown before you pay"), "the nil sentence says the price is shown before paying")
        t.check(without.rangeOfCharacter(from: .decimalDigits) == nil, "the nil sentence has no number in it")
        t.check(!without.contains(fakePrice), "the nil sentence has no price")
        let empty = OnboardingScript.priceSentence("")
        t.equal(empty, without, "an empty price reads like no price")

        for r in [OnboardingRole.sealer, .couple] {
            let priced = OnboardingScript.screens(for: r, numbers: .defaults, price: fakePrice)
            t.check(priced.contains { $0.id.hasSuffix(".price") && $0.body.contains(fakePrice) },
                    "the price screen carries the price", r.rawValue)
            let unpriced = OnboardingScript.screens(for: r, numbers: .defaults, price: nil)
            t.check(unpriced.contains { $0.id.hasSuffix(".price") && $0.body.contains("shown before you pay") },
                    "the price screen reads right without a price", r.rawValue)
            for s in unpriced {
                t.check(!s.body.contains(fakePrice), "no price leaks without one", "\(r.rawValue)/\(s.id)")
            }
        }
        for r in [OnboardingRole.keyHolder, .recipient] {
            for s in OnboardingScript.screens(for: r, numbers: .defaults, price: fakePrice) {
                t.check(!s.body.contains(fakePrice) && !s.body.lowercased().contains("purchase"),
                        "a key holder or recipient never sees a price", "\(r.rawValue)/\(s.id)")
            }
        }
    }

    /// At a threshold of 1 the reassuring sentence is the untrue one.
    static func thresholdOne(_ t: SelfTest.Context) throws {
        for n in numberSets where n.threshold == 1 {
            for s in OnboardingScript.screens(for: .keyHolder, numbers: n) {
                for l in lines(s) {
                    let lower = l.lowercased()
                    t.check(!lower.contains("does nothing"), "no key does nothing at a threshold of 1", "\(s.id) c\(n.custodianCount): \(l)")
                    t.check(!lower.contains("cannot open anything"), "no cannot open anything at a threshold of 1", "\(s.id) c\(n.custodianCount): \(l)")
                    t.check(!lower.contains("one key alone sees nothing."), "no one key alone sees nothing at a threshold of 1", "\(s.id): \(l)")
                }
            }
            for r in [OnboardingRole.sealer, .couple] {
                for s in OnboardingScript.screens(for: r, numbers: n) where s.id.hasSuffix(".curve") {
                    t.check(!s.title.hasPrefix("One key alone sees nothing"), "the sealer curve title is honest at a threshold of 1", "\(r.rawValue)/\(s.id)")
                }
            }
        }
        // And above 1 the arithmetic sentence is back.
        for n in numberSets where n.threshold >= 2 {
            let k = OnboardingScript.screens(for: .keyHolder, numbers: n)
            t.check(k.contains { $0.body.contains("does nothing") }, "above a threshold of 1 the key holder is told one key does nothing", "t\(n.threshold) c\(n.custodianCount)")
        }
    }

    static func figureLabels(_ t: SelfTest.Context) throws {
        for n in numberSets {
            for r in OnboardingRole.allCases {
                for s in OnboardingScript.shared() + OnboardingScript.screens(for: r, numbers: n) {
                    let label = s.figure.accessibilityLabel(n)
                    t.check(label.count > 20, "every figure has a label in words", "\(r.rawValue)/\(s.id)")
                }
            }
        }
    }
}
