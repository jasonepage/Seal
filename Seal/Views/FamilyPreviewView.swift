// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

//  FamilyPreviewView.swift
//  Seal
//
//  "WHAT YOUR FAMILY SEES."
//
//  The owner writes into a form, taps Seal, and hopes. This is the other
//  side of that hope: exactly what one recipient sees at release, their
//  name, their envelopes in the reveal order, the letter, the photos, the
//  voice message, and the secrets behind the same Face ID check.
//
//  It is `RevealPager`, the real recipient screen, fed from local state.
//  Same view, so it cannot drift from what a recipient gets. The only
//  differences are the media loader (the owner's own copies, opened on
//  this phone) and the banner at the top saying this is a preview.
//
//  It touches no engine method that writes, no clock and no network,
//  exactly like SealOnboardingView. The one exception is the reorder
//  sheet, which the owner opens on purpose and which saves through
//  EstateEngine.reorderEnvelopes.

struct FamilyPreviewView: View {
    let recipientHash: String
    let recipientName: String
    let ownerName: String
    @Bindable var estateEngine: EstateEngine
    let onClose: () -> Void

    @State private var showOrder = false

    private var envelopes: [Envelope] {
        estateEngine.estate?.envelopes(for: recipientHash) ?? []
    }

    private var banner: String {
        let unsealed = envelopes.filter { !$0.sealed }.count
        let first = "This is what \(recipientName) sees on their phone after your envelopes open. Nothing is opened or sent by looking."
        guard unsealed > 0 else { return first }
        return first + (unsealed == 1
            ? " One envelope is not sealed yet and is shown as it stands."
            : " \(unsealed) envelopes are not sealed yet and are shown as they stand.")
    }

    var body: some View {
        RevealPager(
            pages: envelopes.map { envelope in
                RevealPage(payload: envelope.payload) { item in
                    guard let data = estateEngine.mediaPlaintext(item, in: envelope) else {
                        throw EstateEngine.EngineError.notReady("That file is not on this phone.")
                    }
                    return data
                }
            },
            ownerName: ownerName,
            emptyLine: "You have not written \(recipientName) an envelope yet.",
            banner: banner,
            onClose: onClose,
            onReorder: { showOrder = true })
        .sheet(isPresented: $showOrder) {
            EnvelopeOrderView(recipientName: recipientName, envelopes: envelopes, estateEngine: estateEngine,
                              onClose: { showOrder = false })
        }
    }
}

// MARK: - Who to preview

/// The home screen's way in. One row per person with envelopes; tapping
/// one opens the preview for them.
struct FamilyPreviewPicker: View {
    let ownerName: String
    @Bindable var estateEngine: EstateEngine
    let onClose: () -> Void

    @State private var chosen: Recipient?

    private var people: [(recipient: Recipient, count: Int)] {
        guard let estate = estateEngine.estate else { return [] }
        return estate.recipients
            .map { ($0, estate.envelopes(for: $0.rootHash).count) }
            .filter { $0.1 > 0 }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Pick a person to see their envelopes the way they see them.")
                            .font(.callout).foregroundStyle(.white.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                        if people.isEmpty {
                            Text("Nobody has an envelope yet. Write one first.")
                                .font(.callout).foregroundStyle(.white.opacity(0.5))
                        }
                        ForEach(people, id: \.recipient.id) { item in
                            Button { chosen = item.recipient } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "person.fill").foregroundStyle(.white.opacity(0.7)).frame(width: 28)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.recipient.displayName).font(.headline).foregroundStyle(.white)
                                        Text(item.count == 1 ? "One envelope" : "\(item.count) envelopes")
                                            .font(.caption).foregroundStyle(.white.opacity(0.5))
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.white.opacity(0.3))
                                }
                                .padding(16)
                                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                            }
                            .buttonStyle(.plain)
                            .parentTapTarget()
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 520).frame(maxWidth: .infinity)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle("What your family sees")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close", action: onClose).foregroundStyle(SealTheme.brass) }
            }
            .sheet(item: $chosen) { recipient in
                FamilyPreviewView(recipientHash: recipient.rootHash, recipientName: recipient.displayName,
                                  ownerName: ownerName, estateEngine: estateEngine, onClose: { chosen = nil })
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - The order

/// Drag to reorder one person's envelopes. `Envelope.revealOrder` has been
/// in the model from the start and this is the first real screen for it.
/// Saving goes through the engine, which marks a moved envelope unsealed
/// so the next seal publishes the new order in the key table.
struct EnvelopeOrderView: View {
    let recipientName: String
    @State var envelopes: [Envelope]
    @Bindable var estateEngine: EstateEngine
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(envelopes) { envelope in
                        HStack(spacing: 12) {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.white.opacity(0.35))
                            Text(envelope.title.isEmpty ? "Untitled" : envelope.title)
                                .foregroundStyle(.white)
                        }
                        .listRowBackground(Color.white.opacity(0.05))
                    }
                    .onMove { from, to in envelopes.move(fromOffsets: from, toOffset: to) }
                } header: {
                    Text("\(recipientName) opens these top to bottom. Drag to change the order.")
                        .foregroundStyle(.white.opacity(0.6))
                        .textCase(nil)
                }
            }
            .scrollContentBackground(.hidden)
            .background(SealTheme.ink)
            .environment(\.editMode, .constant(.active))
            .navigationTitle("The order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onClose).foregroundStyle(.white.opacity(0.7)) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        estateEngine.reorderEnvelopes(envelopes.map(\.id))
                        onClose()
                    }
                    .foregroundStyle(SealTheme.brass)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
