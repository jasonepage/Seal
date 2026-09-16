// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

//  FirstStepsEditorView.swift
//  Seal
//
//  THE OWNER'S SIDE OF "WHAT TO DO FIRST" (FirstSteps.swift).
//
//  Two screens. `FirstStepsEditorSheet` is the list: numbered, drag to
//  reorder, swipe to delete, "Add a step" and a menu of common steps to
//  start from. `FirstStepEditSheet` is one step: a title, a note, and
//  optionally which of the envelope's secrets it needs.
//
//  Nothing here touches the engine. The editor hands back the list and
//  EnvelopeEditorView saves the envelope the way it saves everything else,
//  which marks it unsealed so the next seal publishes it.

struct FirstStepsEditorSheet: View {
    @Binding var steps: [FirstStep]
    /// The envelope's secrets, so a step can point at one by index.
    let secrets: [SealedCard]
    let recipientName: String
    let onClose: () -> Void

    @State private var editing: FirstStep?
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if steps.isEmpty {
                        Text("Nothing yet. Add a step, or pick one of the common ones below.")
                            .foregroundStyle(.white.opacity(0.5))
                            .listRowBackground(Color.white.opacity(0.05))
                    }
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        Button { editing = step } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Text("\(index + 1).")
                                    .font(.headline).foregroundStyle(SealTheme.brass)
                                    .frame(minWidth: 28, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(step.isBlank ? "Untitled step" : step.trimmedTitle)
                                        .font(.headline).foregroundStyle(.white)
                                    if !step.trimmedNote.isEmpty {
                                        Text(step.trimmedNote)
                                            .font(.callout).foregroundStyle(.white.opacity(0.6))
                                            .lineLimit(2)
                                    }
                                    if let s = step.secretIndex, secrets.indices.contains(s) {
                                        Label("Uses the secret: \(secrets[s].title)", systemImage: "lock.fill")
                                            .font(.caption).foregroundStyle(SealTheme.brass.opacity(0.8))
                                    }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.white.opacity(0.3))
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.white.opacity(0.05))
                    }
                    .onMove { from, to in steps.move(fromOffsets: from, toOffset: to) }
                    .onDelete { offsets in steps.remove(atOffsets: offsets) }
                } header: {
                    Text("\(recipientName) sees these first, in this order. Drag to reorder. Swipe left to remove one.")
                        .foregroundStyle(.white.opacity(0.6))
                        .textCase(nil)
                }

                Section {
                    Button { adding = true } label: {
                        Label("Add a step", systemImage: "plus")
                    }
                    .foregroundStyle(SealTheme.brass)
                    .listRowBackground(Color.white.opacity(0.05))
                    Menu {
                        ForEach(FirstStep.starters) { starter in
                            Button(starter.title) {
                                steps.append(FirstStep(title: starter.title))
                                editing = steps.last
                            }
                        }
                    } label: {
                        Label("Pick a common step", systemImage: "list.bullet")
                    }
                    .foregroundStyle(SealTheme.brass)
                    .listRowBackground(Color.white.opacity(0.05))
                } footer: {
                    Text("Short and plain works best. \"Call Mike at the credit union.\" \"The car title is in the blue folder in the garage.\" These are sealed with the letter and opened with it.")
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .scrollContentBackground(.hidden)
            .background(SealTheme.ink)
            .navigationTitle("What to do first")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        // Blank rows are dropped here, so the owner never
                        // seals an empty numbered line.
                        steps.removeAll(where: \.isBlank)
                        onClose()
                    }
                    .foregroundStyle(SealTheme.brass)
                }
                ToolbarItem(placement: .topBarLeading) { EditButton().foregroundStyle(SealTheme.brass) }
            }
            .sheet(item: $editing) { step in
                FirstStepEditSheet(step: step, secrets: secrets) { updated in
                    if let updated, let i = steps.firstIndex(where: { $0.id == updated.id }) {
                        steps[i] = updated
                    }
                    editing = nil
                }
            }
            .sheet(isPresented: $adding) {
                FirstStepEditSheet(step: FirstStep(title: ""), secrets: secrets) { updated in
                    if let updated, !updated.isBlank { steps.append(updated) }
                    adding = false
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - One step

struct FirstStepEditSheet: View {
    @State var step: FirstStep
    let secrets: [SealedCard]
    let onDone: (FirstStep?) -> Void

    private var hint: String {
        FirstStep.starters.first { $0.title == step.trimmedTitle }?.hint
            ?? "Where it is, who to ask for, what to say."
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("The step").font(.headline).foregroundStyle(.white)
                        TextField("Call the bank", text: $step.title)
                            .padding(14).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                        Text("A note (optional)").font(.headline).foregroundStyle(.white)
                        TextEditor(text: $step.note)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 110)
                            .padding(10).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                            .overlay(alignment: .topLeading) {
                                if step.note.isEmpty {
                                    Text(hint).foregroundStyle(.white.opacity(0.3)).padding(18).allowsHitTesting(false)
                                }
                            }
                        if !secrets.isEmpty {
                            Text("Does this step need one of the secrets?").font(.headline).foregroundStyle(.white)
                            Picker("Secret", selection: $step.secretIndex) {
                                Text("No").tag(Int?.none)
                                ForEach(Array(secrets.enumerated()), id: \.offset) { index, card in
                                    Text(card.title).tag(Int?.some(index))
                                }
                            }
                            .pickerStyle(.menu).tint(SealTheme.brass)
                            Text("The secret itself stays behind the Face ID check. The step only points at it by name.")
                                .font(.caption).foregroundStyle(.white.opacity(0.45))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(20)
                    .frame(maxWidth: 520).frame(maxWidth: .infinity)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle("A step")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onDone(nil) }.foregroundStyle(SealTheme.brass) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        step.title = String(step.trimmedTitle.prefix(FirstStep.maxTitleCharacters))
                        step.note = String(step.trimmedNote.prefix(FirstStep.maxNoteCharacters))
                        onDone(step)
                    }
                    .foregroundStyle(SealTheme.brass)
                    .disabled(step.isBlank)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
