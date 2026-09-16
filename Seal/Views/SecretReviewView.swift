// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

//  SecretReviewView.swift
//  Seal
//
//  "ARE YOUR SAVED PASSWORDS STILL RIGHT?"
//
//  Every secret on this phone, one row each, with how long since the
//  owner last said it was right. Two buttons per row. "Still right" writes
//  today's date on the owner's copy and costs nothing: no edit, no
//  re-seal. "Update" opens that envelope in the normal editor, where
//  changing the value marks the envelope unsealed like any other change.
//
//  At the bottom, how often to ask again. Done records the review and
//  reschedules the reminder (SecretReview).

struct SecretReviewView: View {
    @Bindable var estateEngine: EstateEngine
    let ownerHash: String
    /// Close this and open the editor for that envelope.
    let onEdit: (Envelope) -> Void
    let onClose: () -> Void

    @State private var settings: SecretReview.Settings
    @State private var revealed: Set<String> = []

    init(estateEngine: EstateEngine, ownerHash: String, onEdit: @escaping (Envelope) -> Void, onClose: @escaping () -> Void) {
        self.estateEngine = estateEngine
        self.ownerHash = ownerHash
        self.onEdit = onEdit
        self.onClose = onClose
        _settings = State(initialValue: SecretReview.load(ownerHash: ownerHash))
    }

    private struct Row: Identifiable {
        let envelope: Envelope
        let card: SealedCard
        var id: String { envelope.id + "|" + card.confirmationKey }
    }

    private var rows: [Row] {
        estateEngine.allSecrets.map { Row(envelope: $0.envelope, card: $0.card) }
            .sorted { $0.envelope.confirmedAt($0.card) < $1.envelope.confirmedAt($1.card) }
    }

    private func recipientName(_ envelope: Envelope) -> String {
        if !envelope.isAddressed { return envelope.draftRecipientName ?? "someone" }
        return estateEngine.estate?.recipients.first { $0.rootHash == envelope.recipientHash }?.displayName ?? "someone"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Passwords change. Banks change. Read each one and tap Still right, or Update if it has changed. Saying a secret is still right costs nothing and does not need a new seal.")
                            .font(.callout).foregroundStyle(.white.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                        if rows.isEmpty {
                            Text("No secrets saved yet.").font(.callout).foregroundStyle(.white.opacity(0.5))
                        }
                        ForEach(rows) { row in secretRow(row) }
                        intervalBlock
                    }
                    .padding(20)
                    .frame(maxWidth: 520).frame(maxWidth: .infinity)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle("Still right?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        settings.lastReviewedAt = estateEngine.now
                        settings.scheduledFor = nil   // force a fresh schedule from today
                        SecretReview.save(settings, ownerHash: ownerHash)
                        onClose()
                    }
                    .foregroundStyle(SealTheme.brass)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func secretRow(_ row: Row) -> some View {
        let key = row.card.confirmationKey
        let since = row.envelope.confirmedAt(row.card)
        let checkedToday = estateEngine.now.timeIntervalSince(since) < 86_400
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.fill").foregroundStyle(SealTheme.brass).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.card.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    Text("For \(recipientName(row.envelope)). \(row.card.typeLine)")
                        .font(.caption2).foregroundStyle(.white.opacity(0.5))
                    Text(SecretAge.line(since: since, now: estateEngine.now))
                        .font(.caption).foregroundStyle(checkedToday ? SealTheme.brass : .white.opacity(0.6))
                }
                Spacer()
            }
            if revealed.contains(key) {
                Text(row.card.displayValue)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button("Show it") {
                    Task { if await AppLock.confirmSeal(ownerHash: ownerHash) { revealed.insert(key) } }
                }
                .font(.caption).foregroundStyle(SealTheme.brass)
                .parentTapTarget(40)
            }
            HStack(spacing: 10) {
                Button {
                    estateEngine.confirmSecret(envelopeID: row.envelope.id, key: key)
                } label: {
                    Label(checkedToday ? "Still right" : "Still right", systemImage: checkedToday ? "checkmark.circle.fill" : "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(SealTheme.brass)
                .disabled(checkedToday)
                .parentTapTarget()
                Button {
                    onEdit(row.envelope)
                } label: {
                    Label("Update", systemImage: "pencil").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(.white.opacity(0.7))
                .parentTapTarget()
            }
        }
        .padding(14)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }

    private var intervalBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask me again every").font(.headline).foregroundStyle(.white).padding(.top, 8)
            Picker("Ask me again every", selection: $settings.intervalMonths) {
                ForEach(SecretReview.allowedMonths, id: \.self) { months in
                    Text(months == 12 ? "year" : "\(months) months").tag(months)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: settings.intervalMonths) { _, _ in
                settings.scheduledFor = nil
                SecretReview.save(settings, ownerHash: ownerHash)
            }
            Text("A reminder on this phone. It never names a secret.")
                .font(.caption).foregroundStyle(.white.opacity(0.45))
        }
    }
}
