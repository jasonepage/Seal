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
        .alert("Handover signed", isPresented: $handoverDone) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Both of you signed it. The record shows \(person.identity.displayName) took a key from you today.")
        }
    }

    private var custodianCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A key holder").font(.headline).foregroundStyle(.white)
            if let custodian {
                Text("\(person.identity.displayName) is one of your custodians. \(custodian.handoverReceiptID == nil ? "The key handover has not been recorded yet." : "The key handover is signed by both of you.")")
                    .font(.callout).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                if custodian.handoverReceiptID == nil {
                    Button { Task { await handOverKey() } } label: {
                        HStack {
                            if handingOver { ProgressView().tint(SealTheme.ink) }
                            Text("Hand over the key").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent).tint(SealTheme.brass)
                    .disabled(handingOver || DemoFixtures.isActive)
                    .parentTapTarget()
                    Text("Give them the security key, then have them tap it on this phone. That one tap is the receipt.")
                        .font(.caption).foregroundStyle(.white.opacity(0.45)).fixedSize(horizontal: false, vertical: true)
                }
                Button(role: .destructive) { estateEngine.removeCustodian(hash) } label: {
                    Text("Stop being a key holder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(.orange)
                .parentTapTarget()
            } else {
                Text("A custodian holds one of the keys that can open your envelopes after you are gone. Pick people who will still be reachable in ten years.")
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
                ForEach(envelopes) { e in
                    HStack {
                        Image(systemName: e.sealed ? "envelope.fill" : "envelope.badge").foregroundStyle(SealTheme.brass)
                        Text(e.title).foregroundStyle(.white)
                        Spacer()
                        Text("opens \(ordinal(e.revealOrder))").font(.caption).foregroundStyle(.white.opacity(0.4))
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
        default: "\(n)th"
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
