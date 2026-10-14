// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

//  AddKeyHolderFlow.swift
//  Seal
//
//  ADDING A KEY HOLDER IN ONE GO (PRODUCT.md section 14).
//
//  The setup card used to say "open People, add them, then make them a
//  key holder": two tabs, three screens, another person standing there.
//  This is the same ceremony in one sheet, in order, with nothing else on
//  the screen:
//
//    who  ->  (scan -> verify -> phrase)  ->  make key holder  ->  handover  ->  done
//
//  Nothing underneath is new. The scan, the tap on this phone, the
//  friendship, `addCustodian`, and the two-sided receipt are the same
//  calls FriendsView and PersonView make today. This file only puts them
//  in a row and removes the tab hopping.

struct AddKeyHolderFlow: View {
    let myRoot: RootIdentity
    @Bindable var ceremony: CeremonyManager
    let sync: SyncEngine
    @Bindable var friendStore: FriendStore
    @Bindable var estateEngine: EstateEngine
    let onClose: () -> Void

    private enum Stage: Equatable {
        case who
        case scanning
        case lookingUp
        case verify(RootIdentity)
        case verifying(RootIdentity)
        case phrase(RootIdentity)
        case confirm(RootIdentity)
        case handover(RootIdentity)
        case handingOver(RootIdentity)
        case done(RootIdentity, recorded: Bool)
        case failed(String)
    }

    @State private var stage: Stage = .who
    @State private var kitURL: URL?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// People already met who are not key holders of this set yet.
    private var candidates: [FriendStore.StoredFriend] {
        let holders = Set(estateEngine.estate?.custodians.map(\.rootHash) ?? [])
        return friendStore.friends
            .filter { $0.friendship.tombstonedAt == nil && !holders.contains($0.identity.credentialIDHash) }
            .sorted { $0.identity.displayName < $1.identity.displayName }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                switch stage {
                case .who: who
                case .scanning: scanning
                case .lookingUp: progress("Looking them up.")
                case .verify(let f): verify(f)
                case .verifying(let f): verifying(f)
                case .phrase(let f): phrase(f)
                case .confirm(let f): confirm(f)
                case .handover(let f): handover(f)
                case .handingOver(let f): progress("Waiting for \(f.displayName).")
                case .done(let f, let recorded): done(f, recorded: recorded)
                case .failed(let why): failed(why)
                }
            }
            .navigationTitle("Add a key holder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isFinished ? "Done" : "Close") { onClose() }
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var isFinished: Bool {
        if case .done = stage { return true }
        return false
    }

    // MARK: - Layout

    private func column<Content: View, Actions: View>(@ViewBuilder content: () -> Content,
                                                       @ViewBuilder actions: () -> Actions) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content() }
                .padding(24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) { actions() }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .frame(maxWidth: 520)
                .background(SealTheme.ink)
        }
    }

    private func title(_ s: String) -> some View {
        Text(s)
            .font(.system(.title, design: .rounded, weight: .semibold))
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func body(_ s: String) -> some View {
        Text(s)
            .font(.callout)
            .foregroundStyle(.white.opacity(0.7))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func progress(_ s: String) -> some View {
        VStack(spacing: 16) {
            ProgressView().tint(.white.opacity(0.7))
            Text(s).font(.callout).foregroundStyle(.white.opacity(0.6))
        }
    }

    private func move(_ s: Stage) {
        if reduceMotion { stage = s } else { withAnimation(.easeInOut(duration: 0.2)) { stage = s } }
    }

    // MARK: - 1. Who

    private var who: some View {
        column {
            title("Who holds a key?")
            body("Someone you trust to act with the others after you are gone, who will still be reachable in ten years. They need to be next to you with their phone, and Seal on it.")

            if !candidates.isEmpty {
                Text("Already met")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))
                VStack(spacing: 0) {
                    ForEach(candidates) { friend in
                        Button { move(.confirm(friend.identity)) } label: {
                            HStack(spacing: 14) {
                                IdentityRing(displayName: friend.identity.displayName, tier: friend.identity.tier, size: 36)
                                Text(friend.identity.displayName)
                                    .font(.body).foregroundStyle(.white)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.3))
                            }
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                        .parentTapTarget()
                        Divider().overlay(.white.opacity(0.08))
                    }
                }
            }
        } actions: {
            Button {
                move(.scanning)
            } label: {
                Label(candidates.isEmpty ? "Scan their seal" : "Someone new: scan their seal", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SealPrimaryButtonStyle())
            .parentTapTarget(60)
            .disabled(DemoFixtures.isActive)
            Text("Their seal is the square code on their People screen.")
                .font(.footnote).foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 2. Scan, verify, phrase (the ceremony, unchanged)

    private var scanning: some View {
        VStack(spacing: 16) {
            RoleBanner(icon: "viewfinder",
                       text: "This is your phone. Point it at their seal, the square code on their People screen.")
            QRScannerView { code in
                guard code.hasPrefix("seal:") else { return }
                let hash = String(code.dropFirst(5))
                move(.lookingUp)
                Task { await lookup(hash) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .frame(minHeight: 180)
            .padding(.horizontal, 24)
        }
        .safeAreaInset(edge: .bottom) {
            Button("Back") { move(.who) }
                .foregroundStyle(.white.opacity(0.7))
                .padding(.top, 10)
        }
    }

    private func verify(_ friend: RootIdentity) -> some View {
        column {
            ForgeStepRail(active: 2)
            title(friend.displayName)
            body("Found. Now hand this phone to \(friend.displayName). They prove their key on this phone; it never leaves your hands together.")
            if friend.tier == .passkey {
                PasskeyHybridCard(friendName: friend.displayName)
            }
        } actions: {
            Button { Task { await forge(friend) } } label: {
                Label("Ready, \(friend.displayName) taps their key", systemImage: "key.radiowaves.forward.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SealPrimaryButtonStyle())
            .parentTapTarget(60)
            Button("Back") { move(.who) }
                .buttonStyle(SealSecondaryButtonStyle())
                .parentTapTarget(60)
        }
    }

    private func verifying(_ friend: RootIdentity) -> some View {
        VStack(spacing: 20) {
            ForgeStepRail(active: 2)
            Spacer()
            progress(ceremony.phase == .reading
                     ? "Checking \(friend.displayName)'s key."
                     : "Waiting for \(friend.displayName)'s key.")
            Text(friend.tier == .passkey
                 ? "If \(friend.displayName) sees an Apple prompt, they pick a nearby device and approve with Face ID or Touch ID."
                 : "Hold the key flat against the top of the phone.")
                .font(.caption).foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Spacer()
        }
        .padding(.top, 8)
    }

    private func phrase(_ friend: RootIdentity) -> some View {
        column {
            ForgeStepRail(active: 3)
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56)).foregroundStyle(SealTheme.brass)
            title("You're connected")
            Text(FingerprintPhrase.phrase(for: friend.publicKey))
                .font(.title3).foregroundStyle(SealTheme.brass)
                .fixedSize(horizontal: false, vertical: true)
            body("Say it out loud to each other. Matching phrases, matching keys.")
        } actions: {
            Button("It matches. Next") { move(.confirm(friend)) }
                .buttonStyle(SealPrimaryButtonStyle())
                .parentTapTarget(60)
        }
    }

    // MARK: - 3. Make them a key holder

    private func confirm(_ friend: RootIdentity) -> some View {
        column {
            IdentityRing(displayName: friend.displayName, tier: friend.tier, size: 64)
            title("Make \(friend.displayName) a key holder?")
            body("After you have gone quiet for a long time and every warning has run, \(friend.displayName)'s key is one of the keys that opens your envelopes. Until then it does nothing. You can change your mind on the Keys tab any time.")
        } actions: {
            Button("Yes, \(friend.displayName) holds a key") {
                estateEngine.addCustodian(friend)
                move(.handover(friend))
            }
            .buttonStyle(SealPrimaryButtonStyle())
            .parentTapTarget(60)
            Button("Back") { move(.who) }
                .buttonStyle(SealSecondaryButtonStyle())
                .parentTapTarget(60)
        }
    }

    // MARK: - 4. The handover (the same receipt PersonView records)

    private func handover(_ friend: RootIdentity) -> some View {
        column {
            title("Now hand over the key.")
            body("Give \(friend.displayName) a security key if you have one for them. Then record it: tap the button and hand \(friend.displayName) this phone. If they use a security key, they tap it here. If they use Face ID or Touch ID, this phone shows a square code and they scan it with their own phone. That, plus this phone's signature, is the record that they agreed to hold a key.")
            body("No key for them today? Skip this. You can record it later from \(friend.displayName)'s page under People.")
        } actions: {
            Button("\(friend.displayName) confirms on this phone") { Task { await handOver(friend) } }
                .buttonStyle(SealPrimaryButtonStyle())
                .parentTapTarget(60)
                .disabled(DemoFixtures.isActive)
            Button("Skip for now") { move(.done(friend, recorded: false)) }
                .buttonStyle(SealSecondaryButtonStyle())
                .parentTapTarget(60)
        }
    }

    // MARK: - 5. Done

    private func done(_ friend: RootIdentity, recorded: Bool) -> some View {
        column {
            Image(systemName: "key.fill")
                .font(.system(size: 56)).foregroundStyle(SealTheme.brass)
            title("\(friend.displayName) holds a key.")
            body(recorded
                 ? "Both of you signed the record. A printed page goes in the drawer with the key, so anyone who finds it knows what it is for."
                 : "The handover is not recorded yet. Do that from \(friend.displayName)'s page under People when you have a key for them.")
            if let kitURL {
                ShareLink(item: kitURL) {
                    Label("Print or send the page for \(friend.displayName)", systemImage: "printer")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SealSecondaryButtonStyle())
                .parentTapTarget(60)
            } else {
                Button { makeKit(friend) } label: {
                    Label("Make the printed page", systemImage: "printer").frame(maxWidth: .infinity)
                }
                .buttonStyle(SealSecondaryButtonStyle())
                .parentTapTarget(60)
            }
            Text("The page is also on \(friend.displayName)'s page under People.")
                .font(.footnote).foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        } actions: {
            Button("Add another key holder") { kitURL = nil; move(.who) }
                .buttonStyle(SealSecondaryButtonStyle())
                .parentTapTarget(60)
            Button("Done") { onClose() }
                .buttonStyle(SealPrimaryButtonStyle())
                .parentTapTarget(60)
        }
    }

    private func failed(_ why: String) -> some View {
        column {
            Image(systemName: "xmark.circle")
                .font(.system(size: 48)).foregroundStyle(.white.opacity(0.6))
            title("That did not finish.")
            body(why)
        } actions: {
            Button("Try again") { move(.who) }
                .buttonStyle(SealPrimaryButtonStyle())
                .parentTapTarget(60)
        }
    }

    // MARK: - The calls (the same ones FriendsView and PersonView make)

    private func lookup(_ hash: String) async {
        guard hash != myRoot.credentialIDHash else { move(.failed("That is your own seal.")); return }
        if let known = friendStore.friends.first(where: { $0.identity.credentialIDHash == hash && $0.friendship.tombstonedAt == nil }) {
            // Already met: no second ceremony. Straight to the question.
            move(.confirm(known.identity)); return
        }
        do {
            guard let found = try await sync.fetchIdentity(credentialIDHash: hash) else {
                move(.failed("Nobody in the directory with that seal. Have they set up Seal?")); return
            }
            move(.verify(found.0))
        } catch {
            move(.failed("Could not reach the directory: \(error.localizedDescription)"))
        }
    }

    private func forge(_ friend: RootIdentity) async {
        move(.verifying(friend))
        ceremony.resetPhase()
        do {
            let friendship = try await ceremony.forgeFriendship(myRoot: myRoot, friend: friend)
            friendStore.add(identity: friend, friendship: friendship)
            move(.phrase(friend))
            await ForgeHandshakeService.publish(myRoot: myRoot, friend: friend, friendship: friendship,
                                                identity: ceremony.identity, sync: sync)
        } catch {
            move(.failed((error as? LocalizedError)?.errorDescription ?? "That did not finish. Try again."))
        }
    }

    private func handOver(_ friend: RootIdentity) async {
        move(.handingOver(friend))
        do {
            let item = "Security key for \(myRoot.displayName)'s sealed envelopes"
            let receipt = try await ReceiptService.issue(item: item, photo: nil, to: friend, from: myRoot,
                                                         identity: ceremony.identity, ceremony: ceremony)
            let store = ReceiptStore(ownerHash: myRoot.credentialIDHash)
            store.loadIfNeeded()
            store.add(receipt)
            estateEngine.setHandoverReceipt(receipt.receiptID, for: friend.credentialIDHash)
            if let fetched = try? await sync.fetchIdentity(credentialIDHash: friend.credentialIDHash) {
                _ = try? await ReceiptService.publish(receipt, photo: nil, receiverEndorsements: fetched.1, sync: sync)
            }
            move(.done(friend, recorded: true))
        } catch {
            // The key holder stands; only the record is missing, and the
            // done screen says where to record it.
            move(.done(friend, recorded: false))
        }
    }

    private func makeKit(_ friend: RootIdentity) {
        guard let estate = estateEngine.estate else { return }
        kitURL = try? SurvivalKit.makeFile(ownerName: myRoot.displayName, custodianName: friend.displayName,
                                           policy: estate.policy, custodianCount: estate.custodians.count,
                                           now: estateEngine.now)
    }
}
