// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

//  InterviewDrafting.swift
//  Seal
//
//  TURNING ANSWERS INTO A DRAFT.
//
//  ============================================================
//  THE RULE OF THIS FILE, WHICH IS NOT NEGOTIABLE:
//
//  SECRETS ARE NEVER SENT TO A MODEL AND NEVER REWRITTEN.
//  A password, a code, a combination or the location of a safe deposit key
//  is copied from the answer to the secret entry exactly as the owner typed
//  it. No model sees it, no model summarises it, no model "tidies" it.
//  Only answers whose target is `.letter` are ever passed to the model, and
//  that is enforced below by filtering on the target, not by convention.
//
//  AND: nothing here makes a network call of any kind. The only inference
//  is Apple's Foundation Models framework, which runs on the phone. If the
//  phone cannot run it there is no model, and PlainDrafter runs instead.
//  ============================================================
//
//  Nothing in here seals, signs, publishes or saves. It returns a value.

// MARK: - The draft

/// One secret as the interview built it. Kind and label come from the
/// question; the value is the answer, untouched.
struct InterviewDraftSecret: Hashable {
    let kind: SealedCardType
    let label: String
    let value: String
}

/// What the interview hands back. A plain value, owned by the caller.
struct InterviewDraft: Hashable {
    var title: String
    var letter: String
    var secrets: [InterviewDraftSecret]
    /// True when the on-device helper wrote the letter. False when the
    /// plain drafter did, either because there is no model on this phone or
    /// because the model failed and we fell back quietly.
    var usedHelper: Bool = false
    /// True when a model was available and we still ended up with the plain
    /// draft, so the UI can say "Drafted without the helper."
    var helperFellBack: Bool = false

    static let empty = InterviewDraft(title: "", letter: "", secrets: [])
}

// MARK: - The protocol

protocol InterviewDrafter {
    func draft(from answers: [InterviewAnswer], recipientName: String) async -> InterviewDraft
}

// MARK: - Shared pieces

enum InterviewDraftingShared {

    /// Answers that may reach a model. Everything else is a secret.
    static func letterAnswers(_ answers: [InterviewAnswer]) -> [InterviewAnswer] {
        answers.filter { $0.target.isLetter && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static func titleAnswer(_ answers: [InterviewAnswer]) -> String? {
        let found = answers.first { $0.target.isTitle }?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let found, !found.isEmpty else { return nil }
        return String(found.prefix(SealedCard.maxTitleCharacters))
    }

    /// Secrets, byte for byte. This is the only place secrets are built and
    /// it touches no model.
    static func secrets(_ answers: [InterviewAnswer]) -> [InterviewDraftSecret] {
        var out: [InterviewDraftSecret] = []
        for answer in answers {
            guard let kind = answer.target.secretKind,
                  let label = answer.target.secretLabel,
                  !answer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let parts = splitToCardSize(answer.text)
            if parts.count == 1 {
                out.append(InterviewDraftSecret(kind: kind, label: label, value: parts[0]))
            } else {
                for (index, part) in parts.enumerated() {
                    out.append(InterviewDraftSecret(kind: kind,
                                                    label: "\(label) (part \(index + 1))",
                                                    value: part))
                }
            }
        }
        return out
    }

    /// A sealed card holds up to `SealedCard.maxValueBytes`. Rather than
    /// drop or trim a long answer, which is the one thing this product must
    /// never do to a secret, split it on character boundaries into several
    /// entries. Put back together in order, the bytes are the same.
    static func splitToCardSize(_ value: String) -> [String] {
        guard value.utf8.count > SealedCard.maxValueBytes else { return [value] }
        var parts: [String] = []
        var current = ""
        var currentBytes = 0
        for character in value {
            let size = String(character).utf8.count
            if currentBytes + size > SealedCard.maxValueBytes, !current.isEmpty {
                parts.append(current)
                current = ""
                currentBytes = 0
            }
            current.append(character)
            currentBytes += size
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    static func fallbackTitle(recipientName: String) -> String {
        String("For \(recipientName)".prefix(SealedCard.maxTitleCharacters))
    }

    /// One line of greeting, then the answers as paragraphs in the order
    /// they were asked.
    static func plainLetter(from answers: [InterviewAnswer], recipientName: String) -> String {
        let paragraphs = letterAnswers(answers).map {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !paragraphs.isEmpty else { return "" }
        let greeting = "Dear \(recipientName),"
        return ([greeting] + paragraphs).joined(separator: "\n\n")
    }
}

// MARK: - The plain drafter

/// No model. The answers, in order, as paragraphs. This is most of the
/// feature (docs/PRODUCT.md section 11) and it has to be good on its own.
struct PlainDrafter: InterviewDrafter {
    func draft(from answers: [InterviewAnswer], recipientName: String) async -> InterviewDraft {
        InterviewDraft(
            title: InterviewDraftingShared.titleAnswer(answers)
                ?? InterviewDraftingShared.fallbackTitle(recipientName: recipientName),
            letter: InterviewDraftingShared.plainLetter(from: answers, recipientName: recipientName),
            secrets: InterviewDraftingShared.secrets(answers),
            usedHelper: false,
            helperFellBack: false)
    }
}

// MARK: - Is there a model on this phone?

enum InterviewHelper {

    /// True only when Apple Intelligence is on this phone, downloaded and
    /// ready. Anything else is a no, and the plain path runs.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
            return false
        } else {
            return false
        }
        #else
        return false
        #endif
    }

    /// The drafter to use on this phone.
    static func drafter() -> any InterviewDrafter {
        #if canImport(FoundationModels)
        if #available(iOS 26, *), isAvailable {
            return OnDeviceDrafter()
        }
        #endif
        return PlainDrafter()
    }

    /// How long the phone gets before we stop waiting and use the plain
    /// draft instead. Generous; a first run loads the model.
    static let timeoutSeconds: Double = 20
}

#if canImport(FoundationModels)

// MARK: - Structured output

@available(iOS 26, *)
@Generable
struct DraftedLetter {
    @Guide(description: "A short name for this envelope, six words at most, no quotation marks.")
    var title: String

    @Guide(description: "The letter itself, first person, under 300 words.")
    var body: String
}

@available(iOS 26, *)
@Generable
struct DraftedFollowUp {
    @Guide(description: "One short question, twenty words at most, ending in a question mark.")
    var question: String
}

// MARK: - The on-device drafter

/// Apple's Foundation Models framework. A system framework on iOS 26, so it
/// is not a new dependency, and it runs on the phone. It is handed the
/// letter answers and nothing else, ever.
@available(iOS 26, *)
struct OnDeviceDrafter: InterviewDrafter {

    static let instructions = """
    You help someone write a short letter to a person they love, to be read \
    after the writer has died. Write in the first person, as the writer, in \
    their own voice.

    Rules you follow exactly:
    Use plain words a person of any age reads easily.
    Keep every fact you are given and add none. Invent nothing: no names, no \
    dates, no places, no events that are not in the notes.
    Do not add advice, comfort or sayings of your own.
    Keep close to the writer's own wording. You are tidying, not rewriting.
    Under 300 words.
    Never use an em dash.
    Return a short title and the letter body.
    """

    func draft(from answers: [InterviewAnswer], recipientName: String) async -> InterviewDraft {
        // The plain draft is built first and is the answer if anything at
        // all goes wrong below.
        var fallback = await PlainDrafter().draft(from: answers, recipientName: recipientName)

        // ONLY letter answers go past this line.
        let material = InterviewDraftingShared.letterAnswers(answers)
        guard !material.isEmpty else { return fallback }

        let notes = material.map { "Question: \($0.questionText)\nAnswer: \($0.text)" }
            .joined(separator: "\n\n")
        let prompt = """
        The letter is to \(recipientName).

        Here are the writer's notes, in the order they were spoken.

        \(notes)

        Turn these notes into one short letter from the writer to \
        \(recipientName). Keep every fact. Add nothing.
        """

        do {
            let result = try await Self.respond(instructions: Self.instructions,
                                                prompt: prompt,
                                                as: DraftedLetter.self)
            let body = Self.houseStyle(result.body)
            guard !body.isEmpty else {
                fallback.helperFellBack = true
                return fallback
            }
            let modelTitle = Self.houseStyle(result.title)
            let title = InterviewDraftingShared.titleAnswer(answers)
                ?? (modelTitle.isEmpty
                    ? InterviewDraftingShared.fallbackTitle(recipientName: recipientName)
                    : String(modelTitle.prefix(SealedCard.maxTitleCharacters)))
            return InterviewDraft(
                title: title,
                letter: body,
                // Untouched, from the plain path. Secrets never go near the model.
                secrets: InterviewDraftingShared.secrets(answers),
                usedHelper: true,
                helperFellBack: false)
        } catch {
            fallback.helperFellBack = true
            return fallback
        }
    }

    /// The house style says no em dashes, and a model reaches for one every
    /// few sentences. A comma reads the same out loud. The owner sees the
    /// result in the editor and changes it if the comma is wrong.
    static func houseStyle(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\u{2014}", with: ", ")
            .replacingOccurrences(of: "\u{2013}", with: ", ")
            .replacingOccurrences(of: " , ", with: ", ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: One call, with a timeout

    /// Runs one structured request with a watchdog. A cancelled session
    /// throws, which lands in the caller's catch and returns the plain
    /// draft. No error is shown to the owner: a helper that did not help is
    /// not an error, it is just a plain draft.
    static func respond<Content: Generable>(instructions: String,
                                            prompt: String,
                                            as type: Content.Type) async throws -> Content {
        let session = LanguageModelSession { instructions }
        let work = Task { () throws -> Content in
            try await session.respond(to: prompt, generating: type).content
        }
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(InterviewHelper.timeoutSeconds))
            work.cancel()
        }
        defer { watchdog.cancel() }
        return try await work.value
    }
}
#endif

// MARK: - The follow-up question

/// ONE extra question, asked only after "What have you never said to them?"
/// and only when there is a model on the phone. PRODUCT.md says this is
/// where a model earns its place: not on the list, on the question it asks
/// next.
///
/// It is told, in its instructions, that it may ask about the person and the
/// letter only. It must never ask about a password, a code or where anything
/// is kept, and it never sees one: the only thing handed to it is the one
/// letter answer below.
enum InterviewFollowUp {

    static let maximumWords = 20

    static let instructions = """
    Someone is writing a letter to a person they love, to be read after the \
    writer has died. They have just written one thing they never said aloud.

    Ask ONE short question that helps them say more about that person or that \
    feeling. Twenty words at most. Plain words. Warm, never clinical, never \
    an interviewer's follow-up.

    You ask about the person and the letter only. Never ask about passwords, \
    codes, combinations, accounts, money, documents, or where anything is \
    kept. Never give advice. Never use an em dash. Return only the question.
    """

    /// Nil when there is no model, the answer is empty, the model fails, or
    /// the question comes back unusable. The caller simply moves on.
    static func ask(about answer: String, recipientName: String) async -> String? {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, InterviewHelper.isAvailable else { return nil }
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            let prompt = """
            The letter is to \(recipientName). Here is what the writer just \
            said they never told them.

            \(trimmed)

            Ask one short question about \(recipientName) or about what was \
            just said.
            """
            do {
                let result = try await OnDeviceDrafter.respond(instructions: instructions,
                                                              prompt: prompt,
                                                              as: DraftedFollowUp.self)
                return clean(result.question)
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }

    /// Cap at twenty words and refuse anything that strayed toward the
    /// secrets. Belt and braces on top of the instructions. Single words are
    /// matched as whole words, so "opinion" is not read as "pin".
    static func clean(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "\u{2014}", with: ", ")
        text = text.replacingOccurrences(of: "\u{2013}", with: ", ")
        guard !text.isEmpty else { return nil }

        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard words.count <= maximumWords else { return nil }

        let bannedWords: Set<String> = [
            "password", "passwords", "passcode", "pin", "pins", "code", "codes",
            "combination", "combinations", "account", "accounts", "login",
            "logins", "bank", "safe", "vault", "wallet", "key", "keys",
        ]
        let tokens = Set(words.map { word -> String in
            word.lowercased().filter { $0.isLetter || $0.isNumber }
        })
        if !tokens.isDisjoint(with: bannedWords) { return nil }

        let lower = text.lowercased()
        let bannedPhrases = ["log in", "safe deposit", "where it is kept", "where they are kept"]
        if bannedPhrases.contains(where: { lower.contains($0) }) { return nil }

        return text
    }
}
