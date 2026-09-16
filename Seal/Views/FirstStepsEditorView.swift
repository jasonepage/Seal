// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

//  FirstStepsEditorView.swift
//  Seal
//
//  THE OWNER'S SIDE OF "WHAT TO DO FIRST" (FirstSteps.swift).
//
//  One screen. The list is drawn as the same timeline Karen will see.
//  Tap a step and it opens in place: the title, the note with a
//  dictation button, and which secret it needs. The common steps sit
//  under the list as chips; tap one and it drops onto the timeline,
//  already open, waiting for the note. Nothing is behind a menu.
//
//  Reordering is two arrows, not a drag, because a drag handle on a
//  phone held at arm's length is a guess. Removing is one button inside
//  the open step, with the title in it, so nobody removes the wrong one.
//
//  A step can point at a secret. If the secret is not written yet, "Add
//  a new secret" makes it right here and links it, so "Call the bank"
//  and the account number are one thought, not two screens.
//
//  Nothing here touches the engine. The envelope editor saves the
//  envelope the way it saves everything else, which marks it unsealed so
//  the next seal publishes the steps.

struct FirstStepsEditorSheet: View {
    @Binding var steps: [FirstStep]
    @Binding var secrets: [SealedCard]
    let recipientName: String
    /// The envelope editor's own path for a new secret, so a secret made
    /// from a step is stamped and validated exactly like one made from
    /// the secrets card. Returns the new secret's index.
    let onAddSecret: (SealedCard) -> Int
    let onClose: () -> Void

    @State private var openID: String?
    @State private var addingSecretFor: String?
    @FocusState private var focused: String?

    private var remainingStarters: [FirstStep.Starter] {
        let have = Set(steps.map(\.trimmedTitle))
        return FirstStep.starters.filter { !have.contains($0.title) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(steps.isEmpty
                             ? "On a hard day \(recipientName) will not want a pile of passwords. They will want to know what to do. Tap the steps that apply, then say a few words on each."
                             : "\(recipientName) sees these in this order, with a check circle beside each one.")
                            .font(.callout).foregroundStyle(.white.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)

                        if !steps.isEmpty { timeline }

                        starterChips

                        Button {
                            add(FirstStep(title: ""))
                        } label: {
                            Label("Write your own step", systemImage: "square.and.pencil").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SealSecondaryButtonStyle())
                        .parentTapTarget(56)

                        Text("Short and plain works best. \"Call Mike at the credit union.\" \"The car title is in the blue folder in the garage.\" Sealed with the letter, opened with it.")
                            .font(.caption).foregroundStyle(.white.opacity(0.4))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(20)
                    .frame(maxWidth: 560).frame(maxWidth: .infinity)
                    .containerRelativeFrame(.horizontal)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("What to do first")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        steps.removeAll(where: \.isBlank)
                        onClose()
                    }
                    .foregroundStyle(SealTheme.brass)
                }
            }
            .sheet(isPresented: Binding(get: { addingSecretFor != nil }, set: { if !$0 { addingSecretFor = nil } })) {
                SecretEditorSheet { card in
                    if let card, let stepID = addingSecretFor,
                       let i = steps.firstIndex(where: { $0.id == stepID }) {
                        steps[i].secretIndex = onAddSecret(card)
                    }
                    addingSecretFor = nil
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - The timeline

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                HStack(alignment: .top, spacing: 12) {
                    StepMarker(number: index + 1, isLast: index == steps.count - 1, current: openID == step.id)
                    if openID == step.id {
                        openStep(index: index)
                    } else {
                        closedStep(step)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private func closedStep(_ step: FirstStep) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { openID = step.id }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(step.isBlank ? "Untitled step" : step.trimmedTitle)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(step.isBlank ? .white.opacity(0.4) : .white)
                    .fixedSize(horizontal: false, vertical: true)
                if !step.trimmedNote.isEmpty {
                    Text(step.trimmedNote).font(.callout).foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Tap to add a note").font(.caption).foregroundStyle(SealTheme.brass.opacity(0.8))
                }
                if let s = step.secretIndex, secrets.indices.contains(s) {
                    SecretChip(title: "Uses \(secrets[s].title)")
                }
            }
            .padding(.top, 3)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openStep(index: Int) -> some View {
        let binding = $steps[index]
        let step = steps[index]
        return VStack(alignment: .leading, spacing: 10) {
            TextField("What to do", text: binding.title, axis: .vertical)
                .font(.body.weight(.semibold)).foregroundStyle(.white)
                .padding(12).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                .focused($focused, equals: step.id + ".title")
            TextField(hint(for: step), text: binding.note, axis: .vertical)
                .lineLimit(2...6)
                .font(.callout).foregroundStyle(.white)
                .padding(12).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                .focused($focused, equals: step.id + ".note")
            DictationButton(text: binding.note, promise: "Say it the way you would say it to \(recipientName). It stays on this phone.")
            secretPicker(index: index)
            HStack(spacing: 8) {
                Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }
                    .disabled(index == 0)
                Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }
                    .disabled(index == steps.count - 1)
                Spacer()
                Button(role: .destructive) {
                    withAnimation { steps.remove(at: index); openID = nil }
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .foregroundStyle(.orange.opacity(0.9))
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { openID = nil; focused = nil }
                } label: {
                    Text("Close").fontWeight(.semibold)
                }
                .foregroundStyle(SealTheme.brass)
            }
            .buttonStyle(.bordered)
            .tint(.white.opacity(0.6))
            .font(.subheadline)
        }
        .padding(.bottom, 18)
    }

    private func secretPicker(index: Int) -> some View {
        let step = steps[index]
        let linked = step.secretIndex.flatMap { secrets.indices.contains($0) ? secrets[$0] : nil }
        return Menu {
            Button("No secret needed") { steps[index].secretIndex = nil }
            ForEach(Array(secrets.enumerated()), id: \.offset) { i, card in
                Button {
                    steps[index].secretIndex = i
                } label: {
                    if step.secretIndex == i { Label(card.title, systemImage: "checkmark") } else { Text(card.title) }
                }
            }
            Button {
                addingSecretFor = step.id
            } label: {
                Label("Add a new secret for this step", systemImage: "plus")
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: linked == nil ? "lock.open" : "lock.fill")
                Text(linked == nil ? "Does this step need a password or a number?" : "Uses \(linked!.title)")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption)
            }
            .font(.callout)
            .foregroundStyle(linked == nil ? .white.opacity(0.7) : SealTheme.brass)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - The chips

    private var starterChips: some View {
        Group {
            if !remainingStarters.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(steps.isEmpty ? "Common steps" : "More common steps")
                        .font(.headline).foregroundStyle(.white)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(remainingStarters) { starter in
                            StarterChip(starter: starter) { add(FirstStep(title: starter.title)) }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func add(_ step: FirstStep) {
        withAnimation(.easeInOut(duration: 0.2)) {
            steps.append(step)
            openID = step.id
        }
        focused = step.id + (step.isBlank ? ".title" : ".note")
    }

    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard steps.indices.contains(target) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { steps.swapAt(index, target) }
    }

    private func hint(for step: FirstStep) -> String {
        FirstStep.starters.first { $0.title == step.trimmedTitle }?.hint ?? "Where it is, who to ask for, what to say."
    }
}
