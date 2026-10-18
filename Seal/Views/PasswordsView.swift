// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

//  PasswordsView.swift
//  Seal
//
//  YOUR PASSWORDS, TO USE TODAY. Every secret in every envelope, in every
//  rule, in one list: search it, copy one, close it. The owner already
//  keeps the logins here for the people who come after; this lets them
//  use the same list day to day instead of keeping a second copy
//  somewhere else.
//
//  One Face ID check opens the whole list, always, whatever the card lock
//  setting (AppLock.confirmReveal), because this shows every secret at
//  once. It locks again when the app goes to the background. Values stay
//  hidden until "Show"; Copy does not need them shown. Copying goes
//  through SecretClipboard: this phone only, cleared in 90 seconds.
//
//  Nothing here writes. "Change it" opens the envelope in the normal
//  editor, where a new value un-seals it like any other edit. The same
//  secret in two envelopes is one row that names both people.

struct PasswordsView: View {
    @Bindable var engines: EstateEngines
    /// Close this and open the editor for that envelope, in its rule.
    let onEdit: (Envelope, EstateEngine) -> Void
    let onClose: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var unlocked = false
    @State private var asking = false
    @State private var search = ""
    @State private var revealed: Set<String> = []
    /// The row last copied and what the copy said, shown under that row.
    @State private var copiedRow: String?
    @State private var copiedLine = ""

    /// One envelope a secret is in, and the rule it belongs to.
    private struct Place {
        let envelope: Envelope
        let engine: EstateEngine
    }

    private struct Row: Identifiable {
        let card: SealedCard
        var places: [Place]
        var id: String { card.confirmationKey }
    }

    private var allRows: [Row] {
        var order: [String] = []
        var byKey: [String: Row] = [:]
        for engine in engines.all {
            for item in engine.allSecrets {
                let key = item.card.confirmationKey
                if byKey[key] == nil {
                    order.append(key)
                    byKey[key] = Row(card: item.card, places: [])
                }
                byKey[key]?.places.append(Place(envelope: item.envelope, engine: engine))
            }
        }
        return order.compactMap { byKey[$0] }
            .sorted { $0.card.title.localizedCaseInsensitiveCompare($1.card.title) == .orderedAscending }
    }

    /// Search looks at the name, the note, the kind and who it is for,
    /// never at the secret itself.
    private var rows: [Row] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return allRows }
        return allRows.filter { row in
            row.card.title.localizedCaseInsensitiveContains(query)
                || (row.card.note ?? "").localizedCaseInsensitiveContains(query)
                || row.card.typeLine.localizedCaseInsensitiveContains(query)
                || forLine(row).localizedCaseInsensitiveContains(query)
        }
    }

    private func recipientName(_ place: Place) -> String {
        let envelope = place.envelope
        if !envelope.isAddressed { return envelope.draftRecipientName ?? "someone" }
        return place.engine.estate?.recipients.first { $0.rootHash == envelope.recipientHash }?.displayName ?? "someone"
    }

    /// "For Karen", "For Karen and Sam".
    private func forLine(_ row: Row) -> String {
        var names: [String] = []
        for place in row.places {
            let name = recipientName(place)
            if !names.contains(name) { names.append(name) }
        }
        return "For " + OwnerNotices.joinedNames(names)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                if unlocked {
                    list
                } else {
                    lockedView
                }
            }
            .navigationTitle("Passwords")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose).foregroundStyle(SealTheme.brass)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await unlock() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                unlocked = false
                revealed = []
                copiedRow = nil
            }
        }
    }

    private func unlock() async {
        guard !unlocked, !asking else { return }
        asking = true
        unlocked = await AppLock.confirmReveal()
        asking = false
    }

    private var lockedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(SealTheme.brass)
            Text("Locked").font(.headline).foregroundStyle(.white)
            Button("Unlock") { Task { await unlock() } }
                .buttonStyle(.bordered).tint(SealTheme.brass)
                .disabled(asking)
                .parentTapTarget()
        }
        .padding(24)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Everything you saved in your envelopes. Copy what you need. The copy stays on this phone and clears itself in \(Int(SealedCard.clipboardLifetime)) seconds.")
                    .font(.callout).foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                if allRows.isEmpty {
                    Text("No passwords saved yet. Add one to an envelope and it shows up here.")
                        .font(.callout).foregroundStyle(.white.opacity(0.5))
                } else if rows.isEmpty {
                    Text("Nothing matches \"\(search)\".")
                        .font(.callout).foregroundStyle(.white.opacity(0.5))
                }
                ForEach(rows) { row in rowView(row) }
            }
            .padding(20)
            .frame(maxWidth: 520).frame(maxWidth: .infinity)
            .containerRelativeFrame(.horizontal)
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
    }

    /// The value is shown as plain text with no text selection on purpose:
    /// the system's Copy would skip SecretClipboard's rules (this phone
    /// only, cleared in 90 seconds).
    private func rowView(_ row: Row) -> some View {
        let shown = revealed.contains(row.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "key.fill").foregroundStyle(SealTheme.brass).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.card.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    Text("\(forLine(row)). \(row.card.typeLine)")
                        .font(.caption2).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
            }
            if shown {
                Text(row.card.displayValue)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                if let note = row.card.note, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Button {
                    copiedLine = SecretClipboard.copy(row.card)
                    copiedRow = row.id
                } label: {
                    Label(row.card.cardType.copyLabel, systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(SealTheme.brass)
                .parentTapTarget()
                Button {
                    if shown { revealed.remove(row.id) } else { revealed.insert(row.id) }
                } label: {
                    Label(shown ? "Hide" : "Show", systemImage: shown ? "eye.slash" : "eye").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(.white.opacity(0.7))
                .parentTapTarget()
                changeButton(row)
            }
            if copiedRow == row.id {
                Text(copiedLine).font(.caption).foregroundStyle(SealTheme.brass)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }

    /// One envelope: straight to the editor. Several: pick whose.
    @ViewBuilder
    private func changeButton(_ row: Row) -> some View {
        if row.places.count == 1, let place = row.places.first {
            Button {
                onEdit(place.envelope, place.engine)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.bordered).tint(.white.opacity(0.7))
            .accessibilityLabel("Change it")
            .parentTapTarget()
        } else {
            Menu {
                Text("It is in \(row.places.count) envelopes. Change it in each one.")
                ForEach(Array(row.places.enumerated()), id: \.offset) { _, place in
                    Button("For \(recipientName(place))") { onEdit(place.envelope, place.engine) }
                }
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.bordered).tint(.white.opacity(0.7))
            .accessibilityLabel("Change it")
            .parentTapTarget()
        }
    }
}
