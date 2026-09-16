// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import UIKit

//  PersonView.swift
//  Seal
//
//  ONE PERSON YOU HAVE MET. Three things you can do with them: make them a
//  custodian, write them an envelope, and record handing them a key. The
//  handover is the existing two-sided custody receipt: they tap THEIR key
//  on YOUR phone over a commitment naming the item, and your device key
//  signs the same commitment. That receipt is the record that a key changed
//  hands, and it is what the custodian row shows as "handover signed".

struct PersonView: View {
    let person: FriendStore.StoredFriend
    let myRoot: RootIdentity
    @Bindable var friendStore: FriendStore
    @Bindable var estateEngine: EstateEngine
    @Bindable var ceremony: CeremonyManager
    let sync: SyncEngine

    @State private var handingOver = false
    @State private var handoverError: String?
    @State private var handoverDone = false
    @State private var showRecord = false
    @State private var kitURL: URL?
    @State private var kitError: String?
    @Environment(\.parentMode) private var parentMode

    private var hash: String { person.identity.credentialIDHash }
    private var custodian: Custodian? { estateEngine.estate?.custodians.first { $0.rootHash == hash } }
    private var isRecipient: Bool { estateEngine.estate?.recipients.contains { $0.rootHash == hash } ?? false }
    private var envelopes: [Envelope] { estateEngine.estate?.envelopes(for: hash) ?? [] }

    var body: some View {
        ZStack {
            SealTheme.ink.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 8) {
                        IdentityRing(displayName: person.identity.displayName, tier: person.identity.tier, size: 84)
                        Text(person.identity.displayName)
                            .font(.system(.title2, design: .rounded, weight: .semibold)).foregroundStyle(.white)
                        Text("Met in person \(person.friendship.forgedAt.formatted(date: .abbreviated, time: .omitted)). Their key is pinned on this phone.")
                            .font(.caption).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
                        Text(FingerprintPhrase.phrase(for: person.identity.publicKey))
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(SealTheme.brass.opacity(0.8))
                    }
                    .padding(.top, 12)

                    custodianCard
                    envelopesCard

                    Button { showRecord = true } label: {
                        Label("See the record with them", systemImage: "list.bullet.rectangle.portrait")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).tint(.white)
                    .parentTapTarget()
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, 24)
                .frame(maxWidth: 520).frame(maxWidth: .infinity)
                .containerRelativeFrame(.horizontal)
            }
        }
        .navigationTitle(person.identity.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .sheet(isPresented: $showRecord) {
            NavigationStack {
                RecordView(myRoot: myRoot, friendStore: friendStore, estateEngine: estateEngine,
                           counterpart: person, onClose: { showRecord = false })
            }
            .preferredColorScheme(.dark)
        }
        .alert("Handover", isPresented: Binding(get: { handoverError != nil }, set: { if !$0 { handoverError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(handoverError ?? "") }
        // The moment after the tap. The key holder is standing here holding
        // the key and has just understood what it is for, so this is where
        // they hear what their job is and get asked whether they have people
        // they would do this for. It used to be a one-line alert.
        .sheet(isPresented: $handoverDone) {
            HandoverDoneView(
                custodianName: person.identity.displayName,
                ownerName: myRoot.displayName,
                numbers: OnboardingNumbers(
                    policy: estateEngine.estate?.policy ?? ReleasePolicy(threshold: 2),
                    custodianCount: estateEngine.estate?.custodians.count ?? 3),
                onDone: { handoverDone = false })
            .environment(\.parentMode, parentMode)
            .parentTypeScale()
        }
    }

    private var custodianCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A key holder").font(.headline).foregroundStyle(.white)
            if let custodian {
                Text("\(person.identity.displayName) is one of your custodians. \(custodian.handoverReceiptID == nil ? "\(person.identity.displayName) has not yet confirmed it on this phone." : "\(person.identity.displayName) confirmed it on this phone, and both of you signed the record.")")
                    .font(.callout).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                if custodian.handoverReceiptID == nil {
                    Button { Task { await handOverKey() } } label: {
                        HStack {
                            if handingOver { ProgressView().tint(SealTheme.ink) }
                            Text("\(person.identity.displayName) confirms on this phone").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent).tint(SealTheme.brass)
                    .disabled(handingOver || DemoFixtures.isActive)
                    .parentTapTarget()
                    // What actually happens (ReceiptService.issue and
                    // CeremonyManager.signReceipt): the counterparty signs a
                    // commitment with THEIR credential, on THIS phone, and
                    // this phone's device key signs the same commitment.
                    // Nothing physical changes hands. iOS decides the path:
                    // a security key is tapped on this phone; a passkey goes
                    // through the cross-device QR code that iOS shows.
                    Text("Do this with \(person.identity.displayName) next to you. Tap the button, then hand \(person.identity.displayName) this phone. If they use a security key, they tap it on this phone. If they use Face ID, this phone shows a square code: they scan it with their own phone and confirm with their face. That confirmation, plus this phone's signature, is the record that they agreed to hold a key. Nothing else changes hands.")
                        .font(.caption).foregroundStyle(.white.opacity(0.45)).fixedSize(horizontal: false, vertical: true)
                }
                // The printed page that goes in the drawer with the key
                // (SurvivalKitPDF). Built from two names and the rule, so
                // it cannot carry a secret or an envelope.
                VStack(alignment: .leading, spacing: 8) {
                    if let kitURL {
                        ShareLink(item: kitURL) {
                            Label("Print or send the page for \(person.identity.displayName)", systemImage: "printer")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered).tint(.white)
                        .parentTapTarget()
                    } else {
                        Button { makeKit() } label: {
                            Label("A page to keep with the key", systemImage: "doc.text")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered).tint(.white)
                        .parentTapTarget()
                    }
                    Text("One printed page for \(person.identity.displayName): whose key it is, what to do when the time comes, and what to do if Seal the app is ever gone. No secrets on it. Put it in the drawer with the key.")
                        .font(.caption).foregroundStyle(.white.opacity(0.45)).fixedSize(horizontal: false, vertical: true)
                    if let kitError { Text(kitError).font(.caption).foregroundStyle(.orange) }
                }
                Button(role: .destructive) { estateEngine.removeCustodian(hash) } label: {
                    Text("Stop being a key holder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(.orange)
                .parentTapTarget()
            } else {
                Text("A custodian holds one of the keys that can open your envelopes after you are gone. Pick people who are likely to still be reachable in ten years.")
                    .font(.callout).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                Button { estateEngine.addCustodian(person.identity) } label: {
                    Text("Make \(person.identity.displayName) a custodian").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(SealTheme.brass)
                .parentTapTarget()
            }
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 20)
    }

    private var envelopesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Envelopes for \(person.identity.displayName)").font(.headline).foregroundStyle(.white)
            if envelopes.isEmpty {
                Text("None yet. Write one from the home screen.")
                    .font(.callout).foregroundStyle(.white.opacity(0.55))
            } else {
                // Position in the list, not the stored revealOrder: that
                // number starts at zero and can have gaps after a delete or
                // a reorder, and "opens 0th" was on a real screen.
                ForEach(Array(envelopes.enumerated()), id: \.element.id) { position, e in
                    HStack {
                        Image(systemName: e.sealed ? "envelope.fill" : "envelope.badge").foregroundStyle(SealTheme.brass)
                        Text(e.title).foregroundStyle(.white)
                        Spacer()
                        Text("opens \(ordinal(position + 1))").font(.caption).foregroundStyle(.white.opacity(0.4))
                    }
                }
                Text("They open on \(person.identity.displayName)'s phone, in this order, only after release. Nobody else, including the custodians, learns these exist.")
                    .font(.caption).foregroundStyle(.white.opacity(0.45)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 20)
    }

    private func ordinal(_ n: Int) -> String {
        switch n {
        case 1: "first"
        case 2: "second"
        case 3: "third"
        case 4: "fourth"
        case 5: "fifth"
        default: "\(n)th"
        }
    }

    private func makeKit() {
        guard let estate = estateEngine.estate else { return }
        do {
            kitURL = try SurvivalKit.makeFile(ownerName: myRoot.displayName, custodianName: person.identity.displayName,
                                              policy: estate.policy, custodianCount: estate.custodians.count,
                                              now: estateEngine.now)
        } catch {
            kitError = error.localizedDescription
        }
    }

    private func handOverKey() async {
        handingOver = true
        defer { handingOver = false }
        do {
            let item = "Security key for \(myRoot.displayName)'s sealed envelopes"
            let receipt = try await ReceiptService.issue(item: item, photo: nil, to: person.identity, from: myRoot,
                                                         identity: ceremony.identity, ceremony: ceremony)
            let store = ReceiptStore(ownerHash: myRoot.credentialIDHash)
            store.loadIfNeeded()
            store.add(receipt)
            estateEngine.setHandoverReceipt(receipt.receiptID, for: hash)
            if let fetched = try? await sync.fetchIdentity(credentialIDHash: hash) {
                _ = try? await ReceiptService.publish(receipt, photo: nil,
                                                      receiverEndorsements: fetched.1, sync: sync)
            }
            handoverDone = true
        } catch {
            handoverError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
