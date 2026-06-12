//
//  ContentView.swift
//  Seal
//

import SwiftUI

struct ContentView: View {
    @State private var identity = IdentityManager()
    @State private var ceremony: CeremonyManager?
    @State private var sync = SyncEngine()
    @State private var friendStore: FriendStore?
    @State private var chatEngine: ChatEngine?

    var body: some View {
        Group {
            if let root = identity.rootIdentity, let ceremony, let chatEngine, let friendStore {
                HomeView(myRoot: root, identity: identity, ceremony: ceremony,
                         sync: sync, friendStore: friendStore, chatEngine: chatEngine,
                         onReset: performReset)
            } else if let ceremony {
                RegistrationView(ceremony: ceremony)
            }
        }
        .onAppear { setupEngines() }
        .onChange(of: identity.rootIdentity?.credentialIDHash) { setupEngines() }
    }

    /// Stores are namespaced per identity — a new identity sees no data
    /// from previous ones.
    private func setupEngines() {
        if ceremony == nil { ceremony = CeremonyManager(identity: identity) }
        guard let hash = identity.rootIdentity?.credentialIDHash else { return }
        if friendStore?.ownerHash != hash {
            friendStore = FriendStore(ownerHash: hash)
        }
        if chatEngine?.ownerHash != hash {
            chatEngine = ChatEngine(identity: identity, sync: sync, ownerHash: hash)
        }
    }

    /// Reset destroys this identity's keys AND all its local data.
    private func performReset() {
        if let hash = identity.rootIdentity?.credentialIDHash {
            FriendStore.wipe(ownerHash: hash)
            ChatEngine.wipe(ownerHash: hash)
        }
        friendStore = nil
        chatEngine = nil
        identity.reset()
        ceremony?.resetPhase()
        sync.resetStatus()
        // TODO(FR-19): tombstone the directory record so friends see revocation
    }
}

#Preview {
    ContentView()
}
