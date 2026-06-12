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
    @State private var appLock: AppLock?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let root = identity.rootIdentity, let ceremony, let chatEngine, let friendStore, let appLock {
                HomeView(myRoot: root, identity: identity, ceremony: ceremony,
                         sync: sync, friendStore: friendStore, chatEngine: chatEngine,
                         appLock: appLock, onReset: performReset)
            } else if let ceremony {
                RegistrationView(ceremony: ceremony, sync: sync)
            }
        }
        .onAppear { setupEngines() }
        .onChange(of: identity.rootIdentity?.credentialIDHash) { setupEngines() }
        .overlay {
            if let appLock, appLock.isLocked { AppLockScreen(lock: appLock) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { appLock?.lockIfEnabled() }
        }
        .overlay(alignment: .topTrailing) {
            if DemoFixtures.showWatermark { DemoWatermark() }   // FR-23
        }
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
        if appLock?.ownerHash != hash {
            appLock = AppLock(ownerHash: hash)
        }
    }

    /// Reset destroys this identity's keys AND all its local data.
    private func performReset() {
        if let hash = identity.rootIdentity?.credentialIDHash {
            FriendStore.wipe(ownerHash: hash)
            ChatEngine.wipe(ownerHash: hash)
            AppLock.wipe(ownerHash: hash)
        }
        friendStore = nil
        chatEngine = nil
        appLock = nil
        identity.reset()
        ceremony?.resetPhase()
        sync.resetStatus()
        // TODO(FR-19): tombstone the directory record so friends see revocation
    }
}

#Preview {
    ContentView()
}
