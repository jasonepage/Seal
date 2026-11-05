// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// "Already set up a key for someone? Tap it." (1.3)
///
/// Brings back a person whose key you set up earlier, after a sign-out or on
/// a new iPhone (CeremonyManager+FindKey.swift). Same person, same key, so
/// every envelope already sealed to them still opens for them. Brass: a key
/// is tapped in front of you. No mascot: a security surface.
struct FindKeyOwnerView: View {
    @Bindable var ceremony: CeremonyManager
    let sync: SyncEngine
    @Bindable var friendStore: FriendStore
    let onClose: () -> Void
    /// Called with the person once they are back under People.
    var onFound: ((RootIdentity) -> Void)? = nil

    @State private var working = false
    @State private var problem: String?
    @State private var found: RootIdentity?

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let found {
                            foundView(found)
                        } else {
                            askView
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle("Add someone back")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: found == nil ? .cancellationAction : .confirmationAction) {
                    Button(found == nil ? "Cancel" : "Done", action: onClose)
                        .foregroundStyle(SealTheme.brass)
                        .disabled(working)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var askView: some View {
        Group {
            Image(systemName: "key.radiowaves.forward.fill")
                .font(.system(size: 52))
                .foregroundStyle(SealTheme.brass)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
            Text("Did you set up a key for someone before?")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text("If they are not under People any more, hold their key to your phone. Seal finds who it belongs to and adds them back. Anything you already sealed for them still opens for them.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await find() }
            } label: {
                HStack {
                    if working { ProgressView().tint(SealTheme.ink) }
                    Text(working ? "Tap the key when asked" : "Tap their key")
                        .frame(maxWidth: .infinity)
                }
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(SealTheme.brass)
            .foregroundStyle(SealTheme.ink)
            .disabled(working || DemoFixtures.isActive)

            if let problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func foundView(_ root: RootIdentity) -> some View {
        Group {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(SealTheme.brass)
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
            Text("This key is \(root.displayName).")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
            Text(FingerprintPhrase.phrase(for: root.publicKey))
                .font(.title3)
                .foregroundStyle(SealTheme.brass)
                .frame(maxWidth: .infinity)
            Text("\(root.displayName) is back under People. You can make them a key holder or write them a letter.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func find() async {
        working = true
        problem = nil
        defer { working = false }
        do {
            let result = try await ceremony.findKeyOwner(directory: sync)
            let attestation = FriendshipAttestation(nonce: result.challenge,
                                                    timestamp: Clocks.current.now,
                                                    assertion: result.tap)
            let friendship = Friendship(friendRootID: result.root.credentialIDHash,
                                        attestation: try JSONEncoder().encode(attestation),
                                        reverseAttestation: nil,
                                        forgedAt: Clocks.current.now,
                                        autoReciprocated: nil,
                                        sponsored: true)
            friendStore.add(identity: result.root, friendship: friendship)
            found = result.root
            onFound?(result.root)
        } catch CeremonyManager.CeremonyError.cancelled {
            // They backed out on purpose. Nothing to say.
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
