// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

//  InterviewQuestions.swift
//  Seal
//
//  THE QUESTION SET, AS DATA (docs/PRODUCT.md section 11).
//
//  The way this product fails is an empty vault. Every ceremony works, the
//  release machine runs, the envelopes open, and there is nothing in them.
//  This list is the cure, and PRODUCT.md is blunt that the list alone gets
//  most of the way: "The questions are what unsticks somebody."
//
//  So this file carries no model, no network and no cleverness. It is the
//  questions, in order, written to be answered out loud by a sixty-eight
//  year old who has never written a letter like this before. Read them
//  aloud before changing one. If a question cannot be answered out loud in
//  a sentence, it is the wrong question.
//
//  Who the envelope is for is NOT in here. That is the recipient picker,
//  which already exists, and the interview starts after a name is chosen.
//
//  Every question can be skipped. A skipped question leaves no trace.

// MARK: - Where an answer goes

/// Which part of the envelope an answer becomes.
enum InterviewTarget: Hashable {
    /// Becomes a paragraph of the letter, in question order.
    case letter
    /// Becomes the envelope title.
    case title
    /// Becomes one secret of this kind, with this label, copied exactly.
    case secret(kind: SealedCardType, label: String)

    var isLetter: Bool { if case .letter = self { return true }; return false }
    var isTitle: Bool { if case .title = self { return true }; return false }

    var secretKind: SealedCardType? {
        if case .secret(let kind, _) = self { return kind }
        return nil
    }

    var secretLabel: String? {
        if case .secret(_, let label) = self { return label }
        return nil
    }
}

// MARK: - A question

struct InterviewQuestion: Identifiable, Hashable {
    let id: String
    /// The question, big, one to a screen.
    let text: String
    /// A short line under it. Optional, and short: a hint that needs two
    /// sentences is a question that needs rewriting.
    let hint: String?
    /// Faint text inside the empty answer box.
    let placeholder: String
    let target: InterviewTarget
    /// True for the one question the on-device helper may follow up on.
    /// Exactly one question carries this.
    var allowsFollowUp: Bool = false
}

// MARK: - An answer

struct InterviewAnswer: Identifiable, Hashable {
    let questionID: String
    /// The question as it was asked, so the drafting step has the context
    /// without reaching back into the list.
    let questionText: String
    let target: InterviewTarget
    /// Exactly what the owner typed. Never corrected, never trimmed on the
    /// way to a secret.
    let text: String

    var id: String { questionID }
}

// MARK: - The list

enum InterviewQuestions {

    /// Eleven questions. Three of them are the secrets, which is the part
    /// people buy this for. The last one is warm on purpose: a form is a
    /// bad place to stop.
    static let all: [InterviewQuestion] = [
        InterviewQuestion(
            id: "know-first",
            text: "What do you want them to know first?",
            hint: "The first thing they read. A sentence or two is plenty.",
            placeholder: "Start anywhere. You can fix it later.",
            target: .letter),

        InterviewQuestion(
            id: "never-said",
            text: "What have you never said to them?",
            hint: "Take your time. Nobody sees this but you.",
            placeholder: "Say it the way you would say it out loud.",
            target: .letter,
            allowsFollowUp: true),

        InterviewQuestion(
            id: "sorry-or-thanks",
            text: "Is there something you want to thank them for, or say sorry for?",
            hint: "If there is nothing, skip it.",
            placeholder: "Say the thing you would say at the table.",
            target: .letter),

        InterviewQuestion(
            id: "logins",
            text: "What do they need to be able to log into?",
            hint: "Saved exactly as you type it. Seal never fixes a password.",
            placeholder: "The bank, the email, the phone. Account, user name, password.",
            target: .secret(kind: .password, label: "Logins and passwords")),

        InterviewQuestion(
            id: "papers",
            text: "Where are the papers?",
            hint: "The deeds, the policies, the papers from the lawyer, the safe deposit key.",
            placeholder: "Which room, which drawer, which box.",
            target: .secret(kind: .location, label: "Where the papers are")),

        InterviewQuestion(
            id: "codes",
            text: "Is there a code or a combination they need?",
            hint: "A safe, a gate, a lock box, a phone.",
            placeholder: "Saved exactly as you type it.",
            target: .secret(kind: .combination, label: "Codes and combinations")),

        InterviewQuestion(
            id: "only-you-know",
            text: "Anything else only you know?",
            hint: "The thing that goes missing if you do not write it down.",
            placeholder: "Who to ask. What was paid. Where it came from.",
            target: .secret(kind: .statement, label: "Only you know this")),

        InterviewQuestion(
            id: "title",
            text: "If this envelope had a name, what would it be?",
            hint: "Something short. You can change it on the next screen.",
            placeholder: "Read this first",
            target: .title),

        InterviewQuestion(
            id: "do-first",
            text: "What should they do first when they open this?",
            hint: "Who to call, what to sort out, what can wait.",
            placeholder: "Call my brother before you do anything else.",
            target: .letter),

        InterviewQuestion(
            id: "hold-on-to",
            text: "What do you hope they hold on to?",
            hint: "A habit, a story, a thing you taught them.",
            placeholder: "Keep going to the lake in August.",
            target: .letter),

        InterviewQuestion(
            id: "walked-in",
            text: "Last one. If they walked into the room right now, what would you say?",
            hint: "However it comes out is right.",
            placeholder: "Say it plainly.",
            target: .letter),
    ]

    /// The question the helper may ask a follow-up to, if there is one.
    static var followUpAnchorID: String? {
        all.first { $0.allowsFollowUp }?.id
    }

    /// The screen shown before the first question. Kept here with the
    /// questions so the whole script reads in one file.
    enum Intro {
        static let title = "A few questions, then a draft."

        // Says "write or say" because this screen now offers a microphone.
        // The old wording promised only about typing while a microphone sat
        // one tap away, which is the exact shape of a promise that is true
        // and reads as a lie the moment somebody uses the other input.
        static let promise = "Nothing you write or say here leaves your phone. There is no account, no server and no upload in this part of Seal. Your voice is turned into words on the phone itself, or not at all."

        static let control = "At the end you get a draft in the normal editor. You change every word of it. Nothing is sealed, signed or sent until you tap Seal yourself."

        static let temporary = "Your answers are not saved anywhere. If you close this, they are gone and you start again."

        static let skipping = "Any question can be skipped. Most people skip a few."

        static let start = "Start"
    }

    /// The short line shown while the draft is being put together.
    enum Drafting {
        static let working = "Putting your draft together."
        static let ready = "Your draft is ready."
        static let readyBody = "Nothing is sealed. The next screen is the editor, and every word of it is yours to change."
        static let withoutHelper = "Drafted without the helper."
        static let open = "Open the draft"
    }
}
