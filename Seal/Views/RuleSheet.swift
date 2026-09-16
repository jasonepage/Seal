// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

//  RuleSheet.swift
//  Seal
//
//  WHEN IT OPENS. One sheet for everything about rules (RELEASE.md section
//  13), reached from an envelope's "When it opens" card in the editor, or
//  from the inbox menu as "Your rules".
//
//  A rule is one box of keys: its name, its numbers, and the people who
//  hold a key for it. Each rule is a card here. With an envelope in hand,
//  the card the envelope is on says so, and any other card offers "Use
//  this rule", which moves the envelope into that box after one plain
//  warning: both boxes need sealing again. Without an envelope (from the
//  inbox menu) the same cards manage the rules alone.
//
//  Numbers open the existing rule screen (PolicyView). Key holders are
//  ticked from the people met in person; the handover itself (the tap on
//  this phone, the printed page) stays on the person's page under Keys.
//
//  Nothing here touches the crypto or the record. A move is
//  EstateEngines.move, and this sheet only asks first.

struct RuleSheet: View {
    @Bindable var engines: EstateEngines
    @Bindable var friendStore: FriendStore
    /// The rule the envelope in hand is on, or nil when no envelope is.
    var current: EstateEngine? = nil
    /// Called with the rule to move the envelope to, after the owner
    /// confirms. The caller does the move and may throw.
    var onMove: ((EstateEngine) throws -> Void)? = nil
    let onClose: () -> Void

    @State private var policyFor: RuleRef?
    @State private var holdersOpen: Set<String> = []
    @State private var confirmMoveTo: RuleRef?
    @State private var showAdd = false
    @State private var renaming: RuleRef?
    @State private var deleting: RuleRef?
    @State private var nameDraft = ""
    @State private var problem: String?
    @Environment(\.parentMode) private var parentMode

    struct RuleRef: Identifiable {
        let engine: EstateEngine
        var id: String { engine.storeHash }
    }

    private var several: Bool { engines.rules.count > 1 }

    /// People met in person who can hold a key. Somebody who deleted their
    /// Seal account is not offered.
    private var candidates: [FriendStore.StoredFriend] {
        friendStore.friends.filter { friendStore.goneDate($0.id) == nil }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(current == nil
                             ? "A rule is one set of keys: how long a silence, how many warnings, and who holds a key. Every envelope is on one rule."
                             : "This envelope opens under the rule marked below. Pick another to move it there.")
                            .font(.callout).foregroundStyle(.white.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(engines.all, id: \.storeHash) { engine in
                            ruleCard(engine)
                        }
                        if engines.canAdd { addRow }
                        Text("Every rule is its own set of keys. Your key holders tap once per rule, and each rule shows on their phone as its own line. Up to three.")
                            .font(.caption).foregroundStyle(.white.opacity(0.4))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(20)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle(current == nil ? "Your rules" : "When it opens")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose).foregroundStyle(SealTheme.brass)
                }
            }
            .sheet(item: $policyFor) { ref in
                PolicyView(estateEngine: ref.engine, onClose: { policyFor = nil })
                    .environment(\.parentMode, parentMode)
                    .parentTypeScale()
            }
            .alert("Name the new rule", isPresented: $showAdd) {
                TextField(RuleSlot.suggestedSecondName, text: $nameDraft)
                Button("Add") {
                    if let engine = engines.addRule(named: nameDraft) { policyFor = RuleRef(engine: engine) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It starts with a short rule: the shortest silence, one week of warnings, no extra quiet days. You can change the numbers next, then pick who holds a key for it.")
            }
            .alert("Rename this rule", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $nameDraft)
                Button("Rename") {
                    if let ref = renaming { engines.rename(ref.engine.slot.id, to: nameDraft) }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            } message: {
                Text("Your key holders see the new name after your next seal.")
            }
            .confirmationDialog(
                "Delete this rule? It has no envelopes and was never sealed, so nothing is lost.",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete rule", role: .destructive) {
                    if let ref = deleting { engines.remove(ref.engine.slot.id) }
                    deleting = nil
                }
            }
            .confirmationDialog(
                confirmMoveTo.map { "Move this envelope to \($0.engine.slot.name)? It goes into a different set of keys. Both sets need sealing again before the change counts." } ?? "",
                isPresented: Binding(get: { confirmMoveTo != nil }, set: { if !$0 { confirmMoveTo = nil } }),
                titleVisibility: .visible
            ) {
                Button("Move it") {
                    if let ref = confirmMoveTo {
                        do { try onMove?(ref.engine) } catch { problem = error.localizedDescription }
                    }
                    confirmMoveTo = nil
                }
            }
            .alert("Could not move it", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(problem ?? "") }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - One rule

    private func ruleCard(_ engine: EstateEngine) -> some View {
        let estate = engine.estate
        let isCurrent = current === engine
        let holders = estate?.custodians ?? []
        let refusal = engines.removeRefusal(engine.slot.id)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isCurrent ? "checkmark.circle.fill" : "clock.badge")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isCurrent ? SealTheme.brass : .white.opacity(0.5))
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text(engine.slot.name).font(.headline).foregroundStyle(.white)
                Spacer()
                Menu {
                    Button {
                        nameDraft = engine.slot.name
                        renaming = RuleRef(engine: engine)
                    } label: { Label("Rename", systemImage: "pencil") }
                    if !engine.slot.isDefault {
                        Button(role: .destructive) { deleting = RuleRef(engine: engine) } label: {
                            Label("Delete this rule", systemImage: "trash")
                        }
                        .disabled(refusal != nil)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(.white.opacity(0.6))
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("More for \(engine.slot.name)")
            }

            if isCurrent, current != nil {
                Text("This envelope's rule.")
                    .font(.caption.weight(.semibold)).foregroundStyle(SealTheme.brass)
            }

            if let estate {
                Text(holders.isEmpty
                     ? "After \(estate.policy.silenceDays) days of silence, \(estate.policy.warningDays) days of warnings and \(estate.policy.graceDays) days of grace. No key holders yet."
                     : estate.policy.summary(custodianCount: holders.count))
                    .font(.callout).foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Who holds a key, as names, then the two doors.
            if !holders.isEmpty {
                Text("Keys: " + holders.map(\.displayName).joined(separator: ", "))
                    .font(.footnote).foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button { policyFor = RuleRef(engine: engine) } label: {
                    Label("Numbers", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity)
                }
                .buttonStyle(SealSecondaryButtonStyle())
                .parentTapTarget()
                Button {
                    if holdersOpen.contains(engine.storeHash) { holdersOpen.remove(engine.storeHash) } else { holdersOpen.insert(engine.storeHash) }
                } label: {
                    Label("Key holders", systemImage: "key").frame(maxWidth: .infinity)
                }
                .buttonStyle(SealSecondaryButtonStyle())
                .parentTapTarget()
            }

            if holdersOpen.contains(engine.storeHash) {
                holderToggles(engine)
            }

            if let refusal, !engine.slot.isDefault, several {
                Text("To delete this rule: \(refusal.line)")
                    .font(.caption2).foregroundStyle(.white.opacity(0.35))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if current != nil, !isCurrent {
                Button { confirmMoveTo = RuleRef(engine: engine) } label: {
                    Text("Use this rule for the envelope").frame(maxWidth: .infinity)
                }
                .buttonStyle(SealPrimaryButtonStyle())
                .parentTapTarget()
            }
        }
        .padding(16)
        .background(.white.opacity(isCurrent ? 0.07 : 0.04), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(isCurrent ? SealTheme.brass.opacity(0.3) : .clear, lineWidth: 1))
    }

    /// Tick the people who hold a key for this rule. Ticking adds them;
    /// unticking takes them off. The handover (their tap on this phone,
    /// the printed page) is on their page under Keys.
    private func holderToggles(_ engine: EstateEngine) -> some View {
        let holders = Set((engine.estate?.custodians ?? []).map(\.rootHash))
        return VStack(alignment: .leading, spacing: 8) {
            if candidates.isEmpty {
                Text("You have not added anybody in person yet. Open People, meet them, and come back here.")
                    .font(.callout).foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(candidates) { friend in
                let hash = friend.identity.credentialIDHash
                let on = holders.contains(hash)
                Button {
                    if on { engine.removeCustodian(hash) } else { engine.addCustodian(friend.identity) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(on ? SealTheme.brass : .white.opacity(0.4))
                        IdentityRing(displayName: friend.identity.displayName, tier: friend.identity.tier, size: 30)
                        Text(friend.identity.displayName).font(.callout).foregroundStyle(.white)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8).padding(.horizontal, 10)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .parentTapTarget()
                .accessibilityLabel("\(friend.identity.displayName), \(on ? "holds a key" : "does not hold a key") for \(engine.slot.name)")
            }
            Text("Then hand each of them a key in person and record it from their name under Keys. Taking someone off issues fresh shares at the next seal.")
                .font(.caption).foregroundStyle(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private var addRow: some View {
        Button {
            nameDraft = engines.rules.count == 1 ? RuleSlot.suggestedSecondName : ""
            showAdd = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "plus.circle").font(.title3).foregroundStyle(.white.opacity(0.7)).frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Make a new rule").font(.headline).foregroundStyle(.white)
                    Text("For the bills and the medical papers, say, so they can open sooner than the letters.")
                        .font(.caption).foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
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
