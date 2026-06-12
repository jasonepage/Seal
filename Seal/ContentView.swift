//
//  ContentView.swift
//  Seal
//

import SwiftUI

struct ContentView: View {
    @State private var identity = IdentityManager()
    @State private var ceremony: CeremonyManager?
    @State private var sync = SyncEngine()
    @State private var friendStore = FriendStore()
    @State private var chatEngine: ChatEngine?
    @State private var showFriends = false
    @State private var noteToSelf: ChatEngine.Chat?

    var body: some View {
        Group {
            if let root = identity.rootIdentity {
                homePlaceholder(root)
            } else if let ceremony {
                RegistrationView(ceremony: ceremony)
            }
        }
        .onAppear {
            if ceremony == nil { ceremony = CeremonyManager(identity: identity) }
            if chatEngine == nil { chatEngine = ChatEngine(identity: identity, sync: sync) }
        }
    }

    /// Temporary home screen until ChatUI lands — proves registration persisted.
    private func homePlaceholder(_ root: RootIdentity) -> some View {
        ZStack {
            SealTheme.ink.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(root.tier == .verified ? SealTheme.brass : SealTheme.silver)
                Text(root.displayName)
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                Text(root.tier == .verified ? "Verified — hardware key" : "Passkey")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                Text(root.credentialIDHash.prefix(16))
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.35))

                cloudStatusLine
                    .padding(.top, 8)

                Button { showFriends = true } label: {
                    Label("Circle", systemImage: "person.2.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(SealTheme.brass)
                .padding(.horizontal, 48)
                .padding(.top, 16)

                Button {
                    if let chatEngine {
                        noteToSelf = chatEngine.ensureNoteToSelf(myHash: root.credentialIDHash)
                    }
                } label: {
                    Label("Note to self", systemImage: "lock.square")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .padding(.horizontal, 48)

                Button("Reset identity (dev)") {
                    identity.reset()
                    ceremony?.resetPhase()
                }
                .font(.footnote)
                .foregroundStyle(.orange.opacity(0.7))
                .padding(.top, 32)
            }
        }
        .task(id: root.credentialIDHash) {
            guard let endorsement = identity.deviceEndorsement, sync.status == .idle else { return }
            await sync.publishIdentity(root, endorsement: endorsement)
        }
        .sheet(isPresented: $showFriends) {
            if let ceremony, let chatEngine {
                FriendsView(myRoot: root, ceremony: ceremony, sync: sync,
                            friendStore: friendStore, chatEngine: chatEngine)
            }
        }
        .sheet(item: $noteToSelf) { chat in
            if let chatEngine {
                NavigationStack {
                    ChatView(chat: chat, myRoot: root, engine: chatEngine)
                }
                .preferredColorScheme(.dark)
            }
        }
    }

    @ViewBuilder
    private var cloudStatusLine: some View {
        switch sync.status {
        case .idle:
            EmptyView()
        case .publishing:
            Label("Publishing to directory…", systemImage: "icloud.and.arrow.up")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
        case .published:
            Label("In the directory", systemImage: "checkmark.icloud")
                .font(.caption)
                .foregroundStyle(.green.opacity(0.8))
        case .error(let message):
            Label(message, systemImage: "exclamationmark.icloud")
                .font(.caption)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }
}

#Preview {
    ContentView()
}
