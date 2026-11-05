// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import UIKit
import PhotosUI

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
    /// Both envelope sets, so "Stop being a key holder" on a gone person
    /// clears them from each. Empty means just `estateEngine`.
    var allEngines: [EstateEngine] = []
    private var engines: [EstateEngine] { allEngines.isEmpty ? [estateEngine] : allEngines }

    @State private var handingOver = false
    @State private var showPhotoOptions = false
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var photoItem: PhotosPickerItem?
    @State private var confirmRemove = false
    @Environment(\.dismiss) private var dismiss
    @State private var handoverError: String?
    @State private var handoverDone = false
    @State private var showRecord = false
    @State private var kitURL: URL?
    @State private var kitError: String?
    @Environment(\.parentMode) private var parentMode

    private var hash: String { person.identity.credentialIDHash }
    // Across every rule (1.3: there are always three). One person holds one
    // physical key, so a handover recorded on any rule counts.
    private var custodian: Custodian? {
        let all = engines.compactMap { $0.estate?.custodians.first { $0.rootHash == hash } }
        return all.first { $0.handoverReceiptID != nil } ?? all.first
    }
    private var isRecipient: Bool {
        engines.contains { $0.estate?.recipients.contains { $0.rootHash == hash } ?? false }
    }
    private var envelopes: [Envelope] { engines.flatMap { $0.estate?.envelopes(for: hash) ?? [] } }
    /// Read live from the store, not from `person`, which is a copy taken
    /// when the row was tapped.
    private var goneAt: Date? { friendStore.goneDate(hash) }
    private var name: String { person.identity.displayName }

    var body: some View {
        ZStack {
            SealTheme.ink.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    if let goneAt { goneBanner(goneAt) }
                    VStack(spacing: 8) {
                        // Tap to add a picture of them (PersonPhotos): this phone only.
                        Button { showPhotoOptions = true } label: {
                            IdentityRing(displayName: person.identity.displayName, tier: person.identity.tier, size: 96,
                                         photo: PersonPhotos.shared.image(for: hash))
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: "camera.fill")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(SealTheme.ink)
                                        .padding(7)
                                        .background(SealTheme.brass, in: Circle())
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(PersonPhotos.shared.image(for: hash) == nil
                                            ? "Add a photo of \(person.identity.displayName)"
                                            : "Change the photo of \(person.identity.displayName)")
                        Text(person.identity.displayName)
                            .font(.system(.title2, design: .rounded, weight: .semibold)).foregroundStyle(.white)
                        Text(person.friendship.sponsored == true
                             ? "Their key was registered on this phone \(person.friendship.forgedAt.formatted(date: .abbreviated, time: .omitted)) and handed to them. Whoever holds it is \(person.identity.displayName)."
                             : "Met in person \(person.friendship.forgedAt.formatted(date: .abbreviated, time: .omitted)). Their key is pinned on this phone.")
                            .font(.caption).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
                        Text(FingerprintPhrase.phrase(for: person.identity.publicKey))
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(SealTheme.brass.opacity(0.8))
                    }
                    .padding(.top, 12)
                    .confirmationDialog("A photo of \(person.identity.displayName)", isPresented: $showPhotoOptions,
                                        titleVisibility: .visible) {
                        Button("Take a photo") { showCamera = true }
                        Button("Choose from Photos") { showLibrary = true }
                        if PersonPhotos.shared.image(for: hash) != nil {
                            Button("Remove photo", role: .destructive) { PersonPhotos.shared.remove(for: hash) }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Only on this phone. \(person.identity.displayName) never sees it.")
                    }
                    .sheet(isPresented: $showCamera) {
                        SystemCameraPicker(source: .camera) { image in
                            if let image { PersonPhotos.shared.set(image, for: hash) }
                            showCamera = false
                        }
                        .ignoresSafeArea()
                    }
                    .photosPicker(isPresented: $showLibrary, selection: $photoItem, matching: .images)
                    .onChange(of: photoItem) { _, item in
                        guard let item else { return }
                        Task {
                            if let data = try? await item.loadTransferable(type: Data.self) {
                                PersonPhotos.shared.set(data: data, for: hash)
                            }
                            photoItem = nil
                        }
                    }

                    if goneAt == nil {
                        custodianCard
                    } else {
                        goneKeyHolderCard
                    }
                    envelopesCard

                    Button { showRecord = true } label: {
                        Label("See the record with them", systemImage: "list.bullet.rectangle.portrait")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).tint(.white)
                    .parentTapTarget()
                    .padding(.horizontal, 20)

                    if goneAt != nil {
                        Button(role: .destructive) { confirmRemove = true } label: {
                            Label("Remove from People", systemImage: "person.badge.minus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered).tint(.orange)
                        .parentTapTarget()
                        .padding(.horizontal, 20)
                    }
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
        .confirmationDialog(
            "Remove \(name) from People? Any envelope or key still meant for \(name) stays marked on the Envelopes and Keys tabs until you deal with it there.",
            isPresented: $confirmRemove, titleVisibility: .visible
        ) {
            Button("Remove from People", role: .destructive) {
                friendStore.remove(hash)
                dismiss()
            }
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
                Text("\(person.identity.displayName) is one of your key holders. \(custodian.handoverReceiptID == nil ? "\(person.identity.displayName) has not yet confirmed it on this phone." : "\(person.identity.displayName) confirmed it on this phone, and both of you signed the record.")")
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
                    Text("Do this with \(person.identity.displayName) next to you. Tap the button, then hand \(person.identity.displayName) this phone. If they use a security key, they tap it on this phone. If they use Face ID or Touch ID, this phone shows a square code: they scan it with their own phone and confirm there. That confirmation, plus this phone's signature, is the record that they agreed to hold a key. Nothing else changes hands.")
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
                Button(role: .destructive) { for engine in engines { engine.removeCustodian(hash) } } label: {
                    Text("Take \(person.identity.displayName) off your key holders").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(.orange)
                .parentTapTarget()
            } else {
                Text("A key holder keeps one of the keys that can open your envelopes when your rule allows. Pick people who are likely to still be reachable in ten years.")
                    .font(.callout).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                if !(estateEngine.estate?.opensRightAway ?? false) {
                    Button { estateEngine.addCustodian(person.identity) } label: {
                        Text("Make \(person.identity.displayName) a key holder").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(SealTheme.brass)
                    .parentTapTarget()
                }
            }
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 20)
    }

    /// Said once, at the top, in plain words.
    private func goneBanner(_ at: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Deleted their Seal account", systemImage: "person.crop.circle.badge.xmark")
                .font(.headline).foregroundStyle(.orange)
            Text("This phone found on \(at.formatted(date: .abbreviated, time: .omitted)) that \(name) deleted their Seal account. Nothing new can be sent to \(name), and \(name) cannot hold a key for you. Their name stays here so you know who this was.")
                .font(.callout).foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    /// The key holder card for a gone person: what it means, and the one
    /// action that still makes sense. No handover, no printed page, no
    /// "make them a key holder". The rule is not changed for the owner.
    private var goneKeyHolderCard: some View {
        let stillHolding = engines.filter { engine in
            engine.estate?.custodians.contains(where: { c in c.rootHash == hash }) ?? false
        }
        return VStack(alignment: .leading, spacing: 12) {
            Text("A key holder").font(.headline).foregroundStyle(.white)
            if stillHolding.isEmpty {
                Text("\(name) is not one of your key holders.")
                    .font(.callout).foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(name) is still listed as a key holder, but their key can no longer help open your envelopes. Take them off the list, choose another key holder, then seal again.")
                    .font(.callout).foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                Button(role: .destructive) {
                    for engine in stillHolding { engine.removeCustodian(hash) }
                } label: {
                    Text("Take \(name) off your key holders").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(.orange)
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
            if goneAt != nil, !envelopes.isEmpty {
                Label("\(name) deleted their Seal account, so these envelopes cannot be delivered. On the Envelopes tab, press and hold one to give it to someone else or delete it.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if envelopes.isEmpty {
                Text(goneAt == nil ? "None yet. Write one from the home screen." : "None.")
                    .font(.callout).foregroundStyle(.white.opacity(0.55))
            } else {
                // Position in the list, not the stored revealOrder: that
                // number starts at zero and can have gaps after a delete or
                // a reorder, and "opens 0th" was on a real screen.
                ForEach(envelopes, id: \.id) { e in
                    HStack {
                        Image(systemName: e.sealed ? "envelope.fill" : "envelope.badge").foregroundStyle(SealTheme.brass)
                        Text(e.title).foregroundStyle(.white)
                        Spacer()
                        Text(ruleLabel(for: e)).font(.caption).foregroundStyle(.white.opacity(0.4))
                    }
                }
                Text("Each one opens on \(person.identity.displayName)'s phone when its rule allows. Nobody else, including the key holders, learns these exist.")
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

    /// The rule an envelope is on, by its kind.
    private func ruleLabel(for envelope: Envelope) -> String {
        engines.first { $0.estate?.envelopes.contains { $0.id == envelope.id } ?? false }?
            .estate?.policy.kind.label ?? ""
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
            // One key in their hand, so the record counts for every rule
            // they hold a key for.
            for engine in engines { engine.setHandoverReceipt(receipt.receiptID, for: hash) }
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
