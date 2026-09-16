// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

//  CoupleSetupView.swift
//  Seal
//
//  "SET UP WITH MY PARTNER."
//
//  A husband and wife at the kitchen table, both phones out, done in one
//  sitting, each with an envelope to the other. This is a guided path
//  over pieces that already exist. Nothing new is stored and nothing in
//  the key hierarchy moves: each partner keeps their own identity and
//  their own estate (one estate per identity), each makes the other a
//  recipient and a key holder, and each writes their own envelopes.
//
//  The same screen runs on both phones. Every step says what happens on
//  this phone and what the other person does on theirs at the same time,
//  because the one thing a couple gets wrong is assuming one phone did it
//  for both. The checks are about THIS phone's estate; the app cannot see
//  the other estate before it is sealed, and says so.
//
//  Who the partner is: picked once from the people this phone has met,
//  remembered per identity in UserDefaults (a name, not a secret), and
//  changeable.

struct CoupleSetupView: View {
    let myRoot: RootIdentity
    @Bindable var friendStore: FriendStore
    @Bindable var estateEngine: EstateEngine
    @Bindable var ceremony: CeremonyManager
    let sync: SyncEngine
    /// Open the People screen (to scan the partner's seal).
    let onOpenPeople: () -> Void
    /// Open the editor for this envelope.
    let onWriteEnvelope: (Envelope) -> Void
    /// The one seal path on the home screen (with the paywall in front).
    let onSeal: () -> Void
    let onClose: () -> Void

    @State private var partnerHash: String?
    @State private var showHandover = false
    @Environment(\.parentMode) private var parentMode

    private var partnerKey: String { "seal.couple.partner.\(myRoot.credentialIDHash)" }

    private var partner: FriendStore.StoredFriend? {
        friendStore.friends.first { $0.identity.credentialIDHash == partnerHash }
    }
    private var partnerName: String { partner?.identity.displayName ?? "your partner" }
    private var estate: Estate? { estateEngine.estate }

    // MARK: - The steps

    private enum Step: Int, CaseIterable, Identifiable {
        case meet, keyHolder, handover, envelope, third, seal
        var id: Int { rawValue }
    }

    private func isDone(_ step: Step) -> Bool {
        guard let partner else { return false }
        let hash = partner.identity.credentialIDHash
        switch step {
        case .meet: return true
        case .keyHolder: return estate?.custodians.contains { $0.rootHash == hash } ?? false
        case .handover: return estate?.custodians.first { $0.rootHash == hash }?.handoverReceiptID != nil
        case .envelope: return !(estate?.envelopes(for: hash).isEmpty ?? true)
        case .third: return (estate?.custodians.count ?? 0) >= 2
        case .seal: return estate?.epochPublished ?? false
        }
    }

    /// The third key holder is a recommendation, not a gate.
    private var firstUndone: Step? {
        Step.allCases.first { $0 != .third && !isDone($0) }
    }

    private func title(_ step: Step) -> String {
        switch step {
        case .meet: "Meet: scan each other's seal"
        case .keyHolder: "Make \(partnerName) a key holder"
        case .handover: "Hand \(partnerName) a key"
        case .envelope: "Write your envelope to \(partnerName)"
        case .third: "One more key holder each (recommended)"
        case .seal: "Seal"
        }
    }

    private func detail(_ step: Step) -> String {
        switch step {
        case .meet:
            return "On this phone: open People and scan \(partnerName)'s seal. One scan does both phones. Two minutes, side by side."
        case .keyHolder:
            return "On this phone: tap the button. On theirs: \(partnerName) does the same for you. Each of you holds a key to the other's envelopes."
        case .handover:
            return "On this phone: \(partnerName) taps their key on your phone to sign for it. Then swap phones and you sign on theirs. Two receipts, one for each key."
        case .envelope:
            return "On this phone: your letter, your voice, the passwords \(partnerName) will need. On theirs: \(partnerName) writes to you. Nobody sees the other's until the time comes."
        case .third:
            return "With only each other, one key alone can open the envelopes after the silence. A child or a sibling as a second key holder means it takes two people. Both of you should add one. You can do this later."
        case .seal:
            return "Each phone seals its own envelopes. Tap Seal on this phone, then \(partnerName) taps Seal on theirs. Done in one sitting."
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Both phones out, one evening. Each of you keeps your own envelopes and your own key holders. This walks you through doing it together so nothing is missed on either side.")
                            .font(.callout).foregroundStyle(.white.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)

                        partnerPicker

                        if partner != nil {
                            VStack(spacing: 8) {
                                ForEach(Step.allCases) { step in
                                    stepRow(step)
                                }
                            }
                            .padding(14)
                            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))

                            Text("This phone can only check its own side. \(partnerName)'s phone shows the same list from their side. When both lists are done, you are both done.")
                                .font(.caption).foregroundStyle(.white.opacity(0.45))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 520).frame(maxWidth: .infinity)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle("Set up with my partner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close", action: onClose).foregroundStyle(SealTheme.brass) }
            }
            .onAppear {
                partnerHash = UserDefaults.standard.string(forKey: partnerKey)
            }
            .onChange(of: partnerHash) { _, hash in
                if let hash { UserDefaults.standard.set(hash, forKey: partnerKey) }
                else { UserDefaults.standard.removeObject(forKey: partnerKey) }
            }
            .sheet(isPresented: $showHandover) {
                if let partner {
                    NavigationStack {
                        PersonView(person: partner, myRoot: myRoot, friendStore: friendStore,
                                   estateEngine: estateEngine, ceremony: ceremony, sync: sync)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { showHandover = false }.foregroundStyle(SealTheme.brass)
                                }
                            }
                    }
                    .environment(\.parentMode, parentMode)
                    .parentTypeScale()
                    .preferredColorScheme(.dark)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Who

    private var partnerPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(partner == nil ? "Who is your partner?" : "Your partner").font(.headline).foregroundStyle(.white)
            if let partner {
                HStack(spacing: 12) {
                    IdentityRing(displayName: partner.identity.displayName, tier: partner.identity.tier, size: 40)
                    Text(partner.identity.displayName).font(.headline).foregroundStyle(.white)
                    Spacer()
                    Button("Change") { partnerHash = nil }
                        .font(.caption.weight(.semibold)).foregroundStyle(SealTheme.brass)
                        .parentTapTarget(40)
                }
            } else if friendStore.friends.isEmpty {
                Text("You have not met anyone in Seal yet. Start with the first step: open People and scan each other's seal, phones side by side.")
                    .font(.callout).foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onOpenPeople) {
                    Label("Open People and scan their seal", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(SealTheme.brass).foregroundStyle(SealTheme.ink)
                .parentTapTarget(56)
            } else {
                Text("Pick them from the people you have met, or scan their seal if they are not here yet.")
                    .font(.callout).foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(friendStore.friends) { friend in
                    Button { partnerHash = friend.identity.credentialIDHash } label: {
                        HStack(spacing: 12) {
                            IdentityRing(displayName: friend.identity.displayName, tier: friend.identity.tier, size: 36)
                            Text(friend.identity.displayName).font(.body).foregroundStyle(.white)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.white.opacity(0.3))
                        }
                        .padding(12)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .parentTapTarget()
                }
                Button(action: onOpenPeople) {
                    Label("Scan their seal instead", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                }
                .buttonStyle(SealSecondaryButtonStyle())
                .parentTapTarget(52)
            }
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
    }

    // MARK: - One step

    private func stepRow(_ step: Step) -> some View {
        let done = isDone(step)
        let current = step == firstUndone
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(done ? SealTheme.brass : (current ? SealTheme.brass.opacity(0.7) : .white.opacity(0.35)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(step))
                        .font(.headline)
                        .foregroundStyle(done ? .white.opacity(0.5) : .white)
                        .strikethrough(done, color: .white.opacity(0.35))
                        .fixedSize(horizontal: false, vertical: true)
                    if current || (step == .third && !done) {
                        Text(detail(step))
                            .font(.caption).foregroundStyle(.white.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            if !done, current || step == .third { action(step) }
        }
        .padding(12)
        .background(current ? Color.white.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func action(_ step: Step) -> some View {
        switch step {
        case .meet:
            EmptyView()
        case .keyHolder:
            button("Make \(partnerName) a key holder", brass: true) {
                if let partner { estateEngine.addCustodian(partner.identity) }
            }
        case .handover:
            button("\(partnerName) signs for the key on this phone", brass: true) { showHandover = true }
        case .envelope:
            button("Write to \(partnerName)", brass: true) {
                guard let partner else { return }
                estateEngine.addRecipient(partner.identity)
                let envelope = estateEngine.newEnvelope(for: partner.identity.credentialIDHash,
                                                        title: "For \(partner.identity.displayName)")
                onWriteEnvelope(envelope)
            }
        case .third:
            button("Add another key holder", brass: false, action: onOpenPeople)
        case .seal:
            button("Seal the envelopes", brass: true, action: onSeal)
        }
    }

    private func button(_ label: String, brass: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).frame(maxWidth: .infinity)
        }
        .buttonStyle(brass ? AnyButtonStyle(SealPrimaryButtonStyle()) : AnyButtonStyle(SealSecondaryButtonStyle()))
        .disabled(DemoFixtures.isActive)
        .parentTapTarget(56)
        .padding(.leading, 34)
    }
}

/// Two button styles behind one `if`. SwiftUI's `.buttonStyle` wants one
/// concrete type per call, so this erases it.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
