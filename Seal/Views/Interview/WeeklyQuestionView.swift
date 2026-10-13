// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

//  WeeklyQuestionView.swift
//  Seal
//
//  ONE QUESTION, ONE PERSON, ONE TAP (PRODUCT.md section 13).
//
//  The weekly screen. One question with the name on it, the dictation
//  button, skip. Up to two follow-ups from the on-device helper. Then the
//  drafted paragraph, with the Seal button right under it, because a
//  paragraph that waits for another screen never gets sealed.
//
//  This view writes nothing itself. It hands the paragraph (or nothing,
//  for a skip) and the owner's choice to the caller, which appends it
//  through `updateEnvelope` and runs the one shared seal path. Opening the
//  screen is the week's heartbeat; the caller does that too.

struct WeeklyQuestionView: View {

    /// What the owner decided.
    enum Outcome {
        /// Nothing written. Still counts as this week's question.
        case skipped
        /// A paragraph for the envelope, and whether to seal right now.
        case answered(paragraph: String, sealNow: Bool)
    }

    let recipientName: String
    let question: InterviewQuestion
    /// False while setup is unfinished (no key holders, no rule, never
    /// sealed). Then there is one button, "Done", and a line saying where
    /// the paragraph went. The seal step is the setup card's job.
    let canSeal: Bool
    let onDone: (Outcome) -> Void

    private enum Stage { case asking, followUp, drafting, review }

    @State private var stage: Stage = .asking
    @State private var answer = ""
    @State private var followUps: [(question: String, answer: String)] = []
    @State private var followUpIndex = 0
    @State private var askingFollowUp = false
    @State private var paragraph = ""
    @State private var helperFellBack = false

    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let maximumFollowUps = 2

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        switch stage {
                        case .asking: askingScreen
                        case .followUp: followUpScreen
                        case .drafting: draftingScreen
                        case .review: reviewScreen
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle(InterviewQuestions.Weekly.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { onDone(.skipped) }
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - The question

    private var askingScreen: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("For \(recipientName)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(SealTheme.brass)
                .fixedSize(horizontal: false, vertical: true)

            Text(question.text)
                .font(.system(.title, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            if let hint = question.hint {
                Text(hint)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }

            answerBox(text: $answer, placeholder: question.placeholder)

            DictationButton(text: $answer,
                            promise: "Your voice stays on this phone. Seal does not send it anywhere.")

            if askingFollowUp { thinking }

            Text(InterviewQuestions.Weekly.stays)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                Button("Next") { focused = false; afterAnswer() }
                    .buttonStyle(SealPrimaryButtonStyle())
                    .parentTapTarget(60)
                    .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || askingFollowUp)
                Button("Skip this week") { focused = false; onDone(.skipped) }
                    .buttonStyle(SealSecondaryButtonStyle())
                    .parentTapTarget(60)
                    .disabled(askingFollowUp)
            }
        }
        .transition(reduceMotion ? .identity : .opacity)
    }

    // MARK: - A follow-up

    private var followUpBinding: Binding<String> {
        Binding(get: { followUps.indices.contains(followUpIndex) ? followUps[followUpIndex].answer : "" },
                set: { if followUps.indices.contains(followUpIndex) { followUps[followUpIndex].answer = $0 } })
    }

    private var followUpScreen: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("For \(recipientName)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(SealTheme.brass)
                .fixedSize(horizontal: false, vertical: true)

            Text(followUps.indices.contains(followUpIndex) ? followUps[followUpIndex].question : "")
                .font(.system(.title, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            Text("Your phone asked this, from what you just said. Skip it if it does not fit.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            answerBox(text: followUpBinding, placeholder: "A sentence is plenty.")

            DictationButton(text: followUpBinding,
                            promise: "Your voice stays on this phone. Seal does not send it anywhere.")

            if askingFollowUp { thinking }

            VStack(spacing: 12) {
                Button("Next") { focused = false; afterFollowUp() }
                    .buttonStyle(SealPrimaryButtonStyle())
                    .parentTapTarget(60)
                    .disabled(askingFollowUp)
                Button("Skip") { focused = false; followUpBinding.wrappedValue = ""; afterFollowUp() }
                    .buttonStyle(SealSecondaryButtonStyle())
                    .parentTapTarget(60)
                    .disabled(askingFollowUp)
            }
        }
        .id(followUpIndex)
        .transition(reduceMotion ? .identity : .opacity)
    }

    // MARK: - Drafting and review

    private var draftingScreen: some View {
        VStack(alignment: .leading, spacing: 18) {
            ProgressView().tint(.white.opacity(0.7))
            Text(InterviewQuestions.Drafting.working)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text("This happens on your phone.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var reviewScreen: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Added to \(recipientName)'s envelope")
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            Text("Read it once. You can change every word in the editor later.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $paragraph)
                .scrollContentBackground(.hidden)
                .font(.body)
                .foregroundStyle(.white)
                .frame(minHeight: 180)
                .padding(10)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))

            if helperFellBack {
                Text("Your words, as you said them. This phone could not tidy them.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The tap lives here, not on another screen. A paragraph that
            // waits for a separate trip to the home screen never publishes,
            // because the release machine only ever opens sealed envelopes.
            if canSeal {
                VStack(spacing: 12) {
                    Button(InterviewQuestions.Weekly.sealNow) {
                        onDone(.answered(paragraph: paragraph, sealNow: true))
                    }
                    .buttonStyle(SealPrimaryButtonStyle())
                    .parentTapTarget(60)
                    .disabled(paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button(InterviewQuestions.Weekly.notNow) {
                        onDone(.answered(paragraph: paragraph, sealNow: false))
                    }
                    .buttonStyle(SealSecondaryButtonStyle())
                    .parentTapTarget(60)
                }

                Text("Not now keeps it on this phone only, unsealed, until you tap Seal on the home screen.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button("Done") {
                    onDone(.answered(paragraph: paragraph, sealNow: false))
                }
                .buttonStyle(SealPrimaryButtonStyle())
                .parentTapTarget(60)
                .disabled(paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Text("Saved in \(recipientName)'s envelope on this phone. It can be sealed once you have key holders and a rule; the card on the home screen shows what is left.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .transition(reduceMotion ? .identity : .opacity)
    }

    // MARK: - Pieces

    private func answerBox(text: Binding<String>, placeholder: String) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: text)
                .scrollContentBackground(.hidden)
                .font(.body)
                .foregroundStyle(.white)
                .frame(minHeight: 160)
                .padding(10)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                .focused($focused)
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.3))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 18)
                    .allowsHitTesting(false)
            }
        }
    }

    private var thinking: some View {
        HStack(spacing: 10) {
            ProgressView().tint(.white.opacity(0.6))
            Text("One moment.")
                .font(.callout).foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func move(to newStage: Stage) {
        if reduceMotion { stage = newStage } else { withAnimation(.easeInOut(duration: 0.2)) { stage = newStage } }
    }

    // MARK: - Moving through it

    /// Everything said so far, for the next follow-up and for the draft.
    private var saidSoFar: String {
        ([answer] + followUps.map(\.answer))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private func afterAnswer() {
        askNextFollowUpOrDraft()
    }

    private func afterFollowUp() {
        followUpIndex += 1
        askNextFollowUpOrDraft()
    }

    /// Up to two follow-ups, only while there is a model and the owner is
    /// still giving answers. A skipped follow-up ends the asking: pressing
    /// on after a skip is the nagging this feature promises not to do.
    private func askNextFollowUpOrDraft() {
        let lastWasSkipped = followUps.last.map { $0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        guard followUps.count < Self.maximumFollowUps, !lastWasSkipped, InterviewHelper.isAvailable else {
            makeParagraph()
            return
        }
        askingFollowUp = true
        let name = recipientName
        let context = saidSoFar
        Task {
            let extra = await InterviewFollowUp.ask(about: context, recipientName: name)
            await MainActor.run {
                askingFollowUp = false
                if let extra {
                    followUps.append((question: extra, answer: ""))
                    followUpIndex = followUps.count - 1
                    move(to: .followUp)
                } else {
                    makeParagraph()
                }
            }
        }
    }

    private func makeParagraph() {
        move(to: .drafting)
        var notes = [InterviewAnswer(questionID: question.id, questionText: question.text, target: .letter, text: answer)]
        for f in followUps where !f.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            notes.append(InterviewAnswer(questionID: "follow-up", questionText: f.question, target: .letter, text: f.answer))
        }
        let name = recipientName
        Task {
            let result = await WeeklyParagraph.draft(from: notes, recipientName: name)
            await MainActor.run {
                paragraph = result.text
                helperFellBack = result.helperFellBack
                move(to: .review)
            }
        }
    }
}
