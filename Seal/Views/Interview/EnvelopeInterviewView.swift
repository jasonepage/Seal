// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

//  EnvelopeInterviewView.swift
//  Seal
//
//  THE INTERVIEW (docs/PRODUCT.md section 11).
//
//  One question per screen, big, with a box to answer in and a Skip button
//  that is as easy to reach as Next. At the end it builds a draft and hands
//  it back through `onDraft`. It does not seal, sign, publish or save
//  anything, and it never touches the engine: the caller creates the
//  envelope and opens the normal editor on it, so the owner changes every
//  word before anything is sealed.
//
//  Who the envelope is for was chosen already, in the recipient picker.
//
//  Nothing here goes anywhere. The answers live in `@State` and nowhere
//  else. Close the sheet and they are gone, which the first screen says out
//  loud.
//
//  Brass is used twice and only twice: beside the promise on the first
//  screen, and on the button that opens the finished draft. Those are the
//  trust moments. Next, Back and Skip are plain.

struct EnvelopeInterviewView: View {

    /// The person this envelope is for, by name, for the greeting and the
    /// fallback title.
    let recipientName: String
    let onCancel: () -> Void
    let onDraft: (InterviewDraft) -> Void

    private enum Stage { case intro, asking, drafting, ready }

    @State private var stage: Stage = .intro
    @State private var questions: [InterviewQuestion] = InterviewQuestions.all
    @State private var answers: [String: String] = [:]
    @State private var index = 0
    @State private var followUpHandled = false
    @State private var askingFollowUp = false
    @State private var draft: InterviewDraft?
    @State private var confirmClose = false

    @FocusState private var answerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    private var current: InterviewQuestion { questions[min(index, questions.count - 1)] }
    private var isLastQuestion: Bool { index >= questions.count - 1 }
    private var hasAnythingTyped: Bool {
        answers.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var answerBinding: Binding<String> {
        let id = current.id
        return Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        switch stage {
                        case .intro: introScreen
                        case .asking: questionScreen
                        case .drafting: draftingScreen
                        case .ready: readyScreen
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle("Help me write it")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if hasAnythingTyped && stage != .ready { confirmClose = true } else { onCancel() }
                    }
                    .foregroundStyle(.white.opacity(0.8))
                }
            }
            .confirmationDialog("Close and start again later?", isPresented: $confirmClose, titleVisibility: .visible) {
                Button("Close and lose my answers", role: .destructive) { onCancel() }
                Button("Keep going", role: .cancel) {}
            } message: {
                Text("Your answers are not saved anywhere. Closing this loses them.")
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(hasAnythingTyped && stage != .ready)
    }

    // MARK: - The promise

    private var introScreen: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(InterviewQuestions.Intro.title)
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            // The one trust moment on this screen, so the one piece of brass.
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "lock.fill")
                    .font(.title2)
                    .foregroundStyle(SealTheme.brass)
                Text(InterviewQuestions.Intro.promise)
                    .font(.callout)
                    .foregroundStyle(SealTheme.brass.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))

            ForEach([InterviewQuestions.Intro.control,
                     InterviewQuestions.Intro.temporary,
                     InterviewQuestions.Intro.skipping], id: \.self) { line in
                Text(line)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("This envelope is for \(recipientName).")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            Button(InterviewQuestions.Intro.start) {
                move(to: .asking)
            }
            .buttonStyle(SealPrimaryButtonStyle())
            .parentTapTarget(60)
        }
    }

    // MARK: - One question

    private var questionScreen: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Question \(index + 1) of \(questions.count)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Question \(index + 1) of \(questions.count)")

            Text(current.text)
                .font(.system(.title, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            if let hint = current.hint {
                Text(hint)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }

            answerBox

            // Talking beats typing for the question this screen is asking,
            // and it is the microphone Seal can make a promise about, unlike
            // the one on the system keyboard right above it (Dictation.swift).
            // It draws nothing at all on a phone that cannot transcribe on
            // device, so there is no dead control to explain.
            DictationButton(text: answerBinding,
                            promise: "Your voice stays on this phone. Seal does not send it anywhere.")

            if askingFollowUp {
                HStack(spacing: 10) {
                    ProgressView().tint(.white.opacity(0.6))
                    Text("One moment.")
                        .font(.callout).foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            controls
        }
        .id(index)
        .transition(reduceMotion ? .identity : .opacity)
    }

    private var answerBox: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: answerBinding)
                .scrollContentBackground(.hidden)
                .font(.body)
                .foregroundStyle(.white)
                .frame(minHeight: 160)
                .padding(10)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                .focused($answerFocused)
            if (answers[current.id] ?? "").isEmpty {
                Text(current.placeholder)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.3))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 18)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Back, Skip, Next

    private var controls: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(spacing: 12) {
                    nextButton
                    skipButton
                    backButton
                }
            } else {
                VStack(spacing: 12) {
                    nextButton
                    HStack(spacing: 12) {
                        backButton
                        skipButton
                    }
                }
            }
        }
        .disabled(askingFollowUp)
    }

    /// Brass on the last one, because that tap is the moment the promise is
    /// kept: a draft made on this phone out of words that never left it.
    @ViewBuilder
    private var nextButton: some View {
        if isLastQuestion {
            Button("Make the draft") {
                answerFocused = false
                advance()
            }
            .buttonStyle(SealPrimaryButtonStyle())
            .parentTapTarget(60)
        } else {
            Button("Next") {
                answerFocused = false
                advance()
            }
            .buttonStyle(SealSecondaryButtonStyle())
            .parentTapTarget(60)
        }
    }

    private var backButton: some View {
        Button("Back") {
            answerFocused = false
            withMotion { if index > 0 { index -= 1 } else { stage = .intro } }
        }
        .buttonStyle(SealSecondaryButtonStyle())
        .parentTapTarget(60)
    }

    private var skipButton: some View {
        Button("Skip") {
            answerFocused = false
            answers[current.id] = ""
            advance()
        }
        .buttonStyle(SealSecondaryButtonStyle())
        .parentTapTarget(60)
    }

    // MARK: - Making the draft

    private var draftingScreen: some View {
        VStack(alignment: .leading, spacing: 18) {
            ProgressView().tint(.white.opacity(0.7))
            Text(InterviewQuestions.Drafting.working)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text("This happens on your phone. It takes a moment the first time.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var readyScreen: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(InterviewQuestions.Drafting.ready)
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text(InterviewQuestions.Drafting.readyBody)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
            if draft?.helperFellBack == true {
                Text(InterviewQuestions.Drafting.withoutHelper)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(InterviewQuestions.Drafting.open) {
                if let draft { onDraft(draft) }
            }
            .buttonStyle(SealPrimaryButtonStyle())
            .parentTapTarget(60)
        }
    }

    // MARK: - Moving through it

    private func withMotion(_ change: () -> Void) {
        if reduceMotion {
            change()
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { change() }
        }
    }

    private func move(to newStage: Stage) {
        withMotion { stage = newStage }
    }

    /// Next, with the one follow-up question folded in.
    private func advance() {
        let question = current
        let typed = (answers[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // The flag says WHICH question gets the follow-up. The target says
        // whether the answer may go near a model at all. Both, always, so a
        // future question flagged by mistake on a secret still never does.
        if question.allowsFollowUp && question.target.isLetter && !followUpHandled {
            followUpHandled = true
            if !typed.isEmpty && InterviewHelper.isAvailable {
                askingFollowUp = true
                let name = recipientName
                let answerText = answers[question.id] ?? ""
                Task {
                    let extra = await InterviewFollowUp.ask(about: answerText, recipientName: name)
                    await MainActor.run {
                        askingFollowUp = false
                        if let extra { insertFollowUp(extra) }
                        stepForward()
                    }
                }
                return
            }
        }
        stepForward()
    }

    /// The one extra screen the helper earns. Its answer is letter material
    /// like any other.
    private func insertFollowUp(_ text: String) {
        let extra = InterviewQuestion(
            id: "follow-up",
            text: text,
            hint: "Your phone asked this, from what you just wrote. Skip it if it does not fit.",
            placeholder: "A sentence is plenty.",
            target: .letter)
        let at = min(index + 1, questions.count)
        questions.insert(extra, at: at)
    }

    private func stepForward() {
        if isLastQuestion {
            makeDraft()
        } else {
            withMotion { index += 1 }
        }
    }

    /// The answers, in the order they were asked, empty ones dropped.
    private func orderedAnswers() -> [InterviewAnswer] {
        questions.compactMap { question in
            guard let text = answers[question.id],
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return InterviewAnswer(questionID: question.id,
                                   questionText: question.text,
                                   target: question.target,
                                   text: text)
        }
    }

    private func makeDraft() {
        move(to: .drafting)
        let collected = orderedAnswers()
        let name = recipientName
        Task {
            let result = await InterviewHelper.drafter().draft(from: collected, recipientName: name)
            await MainActor.run {
                draft = result
                move(to: .ready)
            }
        }
    }
}
