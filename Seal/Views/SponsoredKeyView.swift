// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

//  SponsoredKeyView.swift
//  Seal
//
//  "REGISTER A KEY FOR SOMEONE WHO IS NOT HERE."
//
//  A dad with a daughter on Android in another state. He types her name,
//  taps a spare security key twice, and the key IS her from then on. He
//  mails it or hands it over the next time he sees her, with the printed
//  page. Years later any iPhone she plugs it into opens her envelope.
//
//  The screen says the one thing that matters before the first tap:
//  whoever holds this key and its PIN is her. Set a PIN. Give it the way
//  you would give a house key. It also says what the key cannot do:
//  nothing opens before the release, with or without it.
//
//  On success the person is added under People with `sponsored: true`,
//  which pins their root key on this phone the way a ceremony would. No
//  second phone was involved, so there is no other direction to run.

struct SponsoredKeyView: View {
    let myRoot: RootIdentity
    @Bindable var ceremony: CeremonyManager
    let sync: SyncEngine
    @Bindable var friendStore: FriendStore
    let onClose: () -> Void

    @State private var name = ""
    @State private var working = false
    @State private var done: RootIdentity?
    @State private var problem: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let done {
                            doneView(done)
                        } else {
                            formView
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 520).frame(maxWidth: .infinity)
                    .containerRelativeFrame(.horizontal)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("A key for someone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(done == nil ? "Cancel" : "Done", action: onClose).foregroundStyle(SealTheme.brass)
                        .disabled(working)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var formView: some View {
        Group {
            Text("For a person who does not have an iPhone, or is not here. You register a spare security key as them, and hand it over. Any iPhone they plug it into, even years from now, opens what you wrote for them.")
                .font(.callout).foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("Their name").font(.headline).foregroundStyle(.white)
                TextField("Emma", text: $name)
                    .textFieldStyle(.plain).font(.title3).foregroundStyle(.white)
                    .padding(14).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                    .focused($nameFocused)
                    .textInputAutocapitalization(.words)
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("Read this first", systemImage: "key.fill").font(.headline).foregroundStyle(SealTheme.brass)
                Text("Whoever holds this key and its PIN is \(name.isEmpty ? "them" : name). Set a PIN on the key before you start. Give it the way you would give a house key.")
                    .font(.callout).foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                Text("The key cannot open anything by itself. Nothing opens before your key holders release everything. If the key is lost, hand them a new one and seal again while you are alive.")
                    .font(.callout).foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
                Text("It needs a key that can carry a secret (a current YubiKey 5 can). Seal checks on the first tap and refuses a key that cannot, before anything is saved.")
                    .font(.caption).foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .background(SealTheme.brass.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))

            Button {
                Task { await register() }
            } label: {
                HStack {
                    if working { ProgressView().tint(SealTheme.ink) }
                    Text(working ? "Tap the key when asked" : "Tap the spare key").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(SealPrimaryButtonStyle())
            .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty || DemoFixtures.isActive)
            .parentTapTarget(60)

            Text("Two taps: one makes the key theirs, one locks their secret to it. Your phone keeps nothing of theirs afterward.")
                .font(.caption).foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)

            if let problem {
                Text(problem).font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func doneView(_ root: RootIdentity) -> some View {
        Group {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 64)).foregroundStyle(SealTheme.brass)
                .frame(maxWidth: .infinity)
            Text("This key is \(root.displayName).")
                .font(.system(.title2, design: .rounded, weight: .bold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity)
            Text(FingerprintPhrase.phrase(for: root.publicKey))
                .font(.title3).foregroundStyle(SealTheme.brass)
                .frame(maxWidth: .infinity)
            Text("\(root.displayName) is under People now. Write them an envelope like anyone else. When you hand over the key, print their page from their name under People and put it in the box with it: it says whose key it is and what to do.")
                .font(.callout).foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
            Text("Until they plug the key into an iPhone and sign in, nothing about them exists on any phone but this record. That is fine. The envelope waits.")
                .font(.caption).foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func register() async {
        working = true
        problem = nil
        defer { working = false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let root = try await ceremony.registerSponsoredKey(displayName: trimmed, directory: sync)
            // The record of how this person was added: the root's own
            // endorsement tap stands in for the ceremony tap, and
            // `sponsored` says so, so nothing later mistakes it for one.
            guard let fetched = try? await sync.fetchIdentity(credentialIDHash: root.credentialIDHash),
                  let endorsement = fetched.1.first(where: \.isSponsored),
                  let stored = try? JSONDecoder().decode(WebAuthnAssertion.self, from: endorsement.assertion) else {
                throw SponsoredKey.Failure.badHalves
            }
            let attestation = FriendshipAttestation(nonce: endorsement.prfSalt ?? Data(), timestamp: Clocks.current.now, assertion: stored)
            let friendship = Friendship(friendRootID: root.credentialIDHash,
                                        attestation: try JSONEncoder().encode(attestation),
                                        reverseAttestation: nil,
                                        forgedAt: Clocks.current.now,
                                        autoReciprocated: nil,
                                        sponsored: true)
            friendStore.add(identity: root, friendship: friendship)
            done = root
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
