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
                             ? "A rule decides when envelopes open. Each envelope uses one rule."
                             : "This envelope uses the rule marked below. Pick another to change it.")
                            .font(.callout).foregroundStyle(.white.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(engines.ordered, id: \.storeHash) { engine in
                            ruleCard(engine)
                        }
                        Text("Your key holders tap once for each rule they hold a key for.")
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
            .confirmationDialog(
                confirmMoveTo.map { "Use \($0.engine.estate?.policy.kind.label ?? $0.engine.slot.name) for this envelope? Both rules need sealing again before the change counts." } ?? "",
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
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isCurrent ? "checkmark.circle.fill" : "clock.badge")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isCurrent ? SealTheme.brass : .white.opacity(0.5))
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text(estate?.policy.kind.label ?? engine.slot.name).font(.headline).foregroundStyle(.white)
                Spacer()
            }

            if isCurrent, current != nil {
                Text("This envelope's rule.")
                    .font(.caption.weight(.semibold)).foregroundStyle(SealTheme.brass)
            }

            if let estate {
                Text(holders.isEmpty && estate.policy.kind == .quiet
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

            // A right away rule has no numbers to set and no key holders.
            if !(estate?.opensRightAway ?? false) {
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
        // A right away rule has no key holders (PRODUCT.md section 17).
        let rightAway = engine.estate?.opensRightAway ?? false
        return VStack(alignment: .leading, spacing: 8) {
            if rightAway {
                Text("This rule opens right away for the people you wrote to, so it has no key holders.")
                    .font(.callout).foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            } else if candidates.isEmpty {
                Text("You have not added anybody in person yet. Open People, meet them, and come back here.")
                    .font(.callout).foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(rightAway ? [] : candidates) { friend in
                let hash = friend.identity.credentialIDHash
                let on = holders.contains(hash)
                Button {
                    if on { engine.removeCustodian(hash) } else { engine.addCustodian(friend.identity) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(on ? SealTheme.brass : .white.opacity(0.4))
                        IdentityRing(displayName: friend.identity.displayName, tier: friend.identity.tier, size: 30,
                                     photo: PersonPhotos.shared.image(for: friend.identity.credentialIDHash))
                        Text(friend.identity.displayName).font(.callout).foregroundStyle(.white)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8).padding(.horizontal, 10)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .parentTapTarget()
                .accessibilityLabel("\(friend.identity.displayName), \(on ? "holds a key" : "does not hold a key") for \(engine.ruleLabel)")
            }
            Text("Then hand each of them a key in person and record it from their name under Keys. If you take someone off, the others get new key pieces the next time you seal.")
                .font(.caption).foregroundStyle(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

}
