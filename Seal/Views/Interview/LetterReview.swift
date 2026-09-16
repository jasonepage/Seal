// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

//  LetterReview.swift
//  Seal
//
//  "WOULD THIS ACTUALLY HELP THEM?"
//
//  docs/PRODUCT.md section 11: the way Seal fails is an empty vault that
//  opens perfectly. The near miss is a full vault that opens and still
//  leaves the reader stuck, because the letter says "the folder in the
//  study" and never says which folder, or "call Marco" with no way to
//  reach Marco. This asks the phone's own model to read the letter as that
//  reader would and to point at what they could not act on.
//
//  ============================================================
//  THE RULES OF THIS FILE, SAME AS InterviewDrafting.swift:
//
//  SECRETS NEVER REACH THE MODEL. The only thing handed over is the letter
//  string, and that is enforced by the type of `Material`, which can only
//  be built from `Envelope.letter`. Not the secrets, not the photos, not the
//  voice note, not the title. On top of that, anything LetterSecretScan
//  finds in the letter (a recovery phrase or a private key typed into the
//  wrong box) is cut out of the copy the model sees, so even a secret the
//  owner chose to keep in the letter stays on the phone.
//
//  ON DEVICE ONLY. Apple's Foundation Models framework, behind the same
//  canImport and iOS 26 checks as the drafter. A phone that cannot run it
//  gets no feature. There is no server and there never is one here.
//
//  IT SUGGESTS, IT NEVER EDITS. It returns questions. The owner changes
//  every word themselves or ignores the list. Nothing here writes to the
//  envelope.
//
//  IT NEVER COMMENTS ON THE WISDOM of what is being left to whom. That is
//  in the instructions, and `clean` throws away anything that strays.
//
//  Sealing is never gated on any of this.
//  ============================================================

enum LetterReview {

    /// The letter, and only the letter. The initialiser takes an Envelope
    /// and reads one field of it, so there is no way to hand this a secret.
    struct Material {
        let letter: String
        let recipientName: String

        init(envelope: Envelope, recipientName: String) {
            // Cut out anything that looks like a secret typed into the letter
            // before the model sees a copy. Deterministic (LetterSecretScan).
            var text = envelope.letter
            for finding in LetterSecretScan.scan(text) {
                text = LetterSecretScan.removing(finding, from: text)
            }
            self.letter = text
            self.recipientName = recipientName
        }
    }

    /// One thing the reader could not act on.
    struct Gap: Hashable, Identifiable {
        /// The writer's own words, quoted back so they can find the spot.
        let quote: String
        /// One short question the writer could answer in the letter.
        let question: String
        var id: String { quote + "|" + question }
    }

    static let maximumGaps = 5
    static let maximumQuestionWords = 20

    /// True when the phone can run this at all. Same test as the drafter.
    static var isAvailable: Bool { InterviewHelper.isAvailable }

    /// Nil when there is no model, the letter is empty, the model failed or
    /// timed out. An empty list means the model found nothing to ask. The
    /// caller shows the list or nothing; it never shows an error, because a
    /// helper that did not help is not an error.
    static func review(_ material: Material) async -> [Gap]? {
        let letter = material.letter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !letter.isEmpty, isAvailable else { return nil }
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            let prompt = """
            The letter is to \(material.recipientName). Here it is.

            \(letter)

            List what \(material.recipientName) could not act on after reading \
            it. For each one, quote the writer's exact words and ask one short \
            question the writer could answer. If everything can be acted on, \
            return an empty list.
            """
            do {
                let result = try await OnDeviceDrafter.respond(instructions: instructions,
                                                              prompt: prompt,
                                                              as: ReviewedLetter.self)
                return clean(result.gaps.map { Gap(quote: $0.quote, question: $0.question) }, letter: letter)
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }

    static let instructions = """
    You read a letter that is written to be opened after the writer has died. \
    The reader is grieving and has only this letter.

    Your one job is to find things the reader could not act on:
    A thing referred to with no way to find it, like "the folder in the study" \
    with no word on which folder.
    A person named with no way to reach them.
    An instruction with no place, like "take the box to the bank" with no bank.
    A document, list or account that the letter promises but never says where \
    it is or what it is called.

    For each one, give the writer's exact words from the letter and ONE short \
    question the writer could answer, twenty words at most, in plain words.

    Rules you follow exactly:
    Never comment on what is being left, to whom, or whether it is fair, \
    wise or enough. That is not your business.
    Never suggest wording and never rewrite anything.
    Never invent a name, a place or a fact that is not in the letter.
    Never ask for a password, a code or a combination itself. You may ask \
    where something is or how to reach someone.
    At most five questions. Fewer is better. None is fine.
    Never use an em dash.
    """

    /// House style: no em dashes. A comma reads the same out loud. Kept
    /// here rather than borrowed from OnDeviceDrafter so `clean` compiles
    /// and runs on a phone with no model, which the self-tests are.
    static func tidy(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\u{2014}", with: ", ")
            .replacingOccurrences(of: "\u{2013}", with: ", ")
            .replacingOccurrences(of: " , ", with: ", ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Belt and braces on top of the instructions. A quote must really be
    /// in the letter, a question must be short and end in a question mark,
    /// nothing may ask for a secret's value, and nothing may pass judgement.
    static func clean(_ raw: [Gap], letter: String) -> [Gap] {
        let lowerLetter = letter.lowercased()
        var seen: Set<String> = []
        var out: [Gap] = []
        for gap in raw {
            let quote = tidy(gap.quote).trimmingCharacters(in: .punctuationCharacters)
            var question = tidy(gap.question)
            guard !quote.isEmpty, !question.isEmpty else { continue }
            guard lowerLetter.contains(quote.lowercased()) else { continue }
            if !question.hasSuffix("?") { question += "?" }
            let words = question.split(whereSeparator: { $0.isWhitespace })
            guard words.count <= maximumQuestionWords else { continue }
            let lower = question.lowercased()
            let judging = ["should you", "is it fair", "is it wise", "you might reconsider", "deserve", "instead of", "rather than", "why not", "consider leaving", "consider giving"]
            if judging.contains(where: { lower.contains($0) }) { continue }
            let askingForSecret = ["what is the password", "what is the code", "what is the combination", "what is the pin", "what is the passcode", "what are the words"]
            if askingForSecret.contains(where: { lower.contains($0) }) { continue }
            guard seen.insert(quote.lowercased()).inserted else { continue }
            out.append(Gap(quote: quote, question: question))
            if out.count == maximumGaps { break }
        }
        return out
    }
}

#if canImport(FoundationModels)

@available(iOS 26, *)
@Generable
struct ReviewedGap {
    @Guide(description: "The writer's exact words from the letter, copied without change, twelve words at most.")
    var quote: String

    @Guide(description: "One short question the writer could answer, twenty words at most, ending in a question mark.")
    var question: String
}

@available(iOS 26, *)
@Generable
struct ReviewedLetter {
    @Guide(description: "Things the reader could not act on. Empty if there are none. Five at most.")
    var gaps: [ReviewedGap]
}

#endif
