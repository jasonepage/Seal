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
    @State private var perkRedeemer: PerkRedeemer?
    @State private var showPostRegistrationRedeem = false
    @State private var showBackupPrompt = false
    @State private var showRecoveryNotice = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let root = identity.rootIdentity, let ceremony, let chatEngine, let friendStore, let appLock, let perkRedeemer {
                HomeView(myRoot: root, identity: identity, ceremony: ceremony,
                         sync: sync, friendStore: friendStore, chatEngine: chatEngine,
                         appLock: appLock, perkRedeemer: perkRedeemer,
                         onSignOut: performSignOut, onDelete: performDelete)
                    .sheet(isPresented: $showPostRegistrationRedeem) {
                        RedeemPerkView(myRoot: root, redeemer: perkRedeemer)
                    }
                    // Blocking, by design (FR-3, UI.md §3.1): this is the one
                    // moment the person is holding their key and thinking
                    // about it, and skipping it is the one choice here that
                    // can't be undone later. A full-screen cover can't be
                    // swiped away, so the only ways out are adding a key or
                    // accepting the risk explicitly.
                    .fullScreenCover(isPresented: $showBackupPrompt) {
                        BackupKeyPrompt(myRoot: root, ceremony: ceremony, sync: sync) {
                            showBackupPrompt = false
                        }
                    }
                    // After a backup-key recovery (FR-3): say plainly that the
                    // main key is gone and what to do about it. Shown once —
                    // the keys panel keeps a standing notice, so this doesn't
                    // need to nag, only to land.
                    .fullScreenCover(isPresented: $showRecoveryNotice) {
                        RecoveredIdentityNotice(myRoot: root) {
                            RecoveryNotice.acknowledge(ownerHash: root.credentialIDHash)
                            showRecoveryNotice = false
                        }
                    }
            } else if let ceremony {
                RegistrationView(ceremony: ceremony, sync: sync)
            }
        }
        .onAppear { setupEngines() }
        .onChange(of: identity.rootIdentity?.credentialIDHash) { _, new in
            setupEngines()
            // Fresh ceremony THIS session (not an app relaunch), and this
            // identity has no backup key yet → the FR-3 prompt.
            //
            // "No backup key yet" is read off the identity we just stored,
            // which is what makes this fire in the right places without a
            // second flag: a fresh registration has none, a sign-in carries
            // whatever the directory published. So registering prompts,
            // signing in on a phone whose identity still has no backup key
            // prompts (it should — nothing has changed about the risk), and
            // signing in on an identity that already has one stays quiet.
            let hasBackup = !(identity.rootIdentity?.backupCredentials ?? []).isEmpty
            let recovered = new.map { RecoveryNotice.needsAcknowledgement(ownerHash: $0) } ?? false
            // A phone that just came back from the dead has a more urgent
            // truth to tell than "add a backup key" — and telling it to add
            // one would be advice it cannot take, since that needs the root
            // key it no longer has.
            if new != nil, ceremony?.phase == .sealed, !DemoFixtures.isActive, recovered {
                showRecoveryNotice = true
            } else if new != nil, ceremony?.phase == .sealed, !DemoFixtures.isActive, !hasBackup {
                showBackupPrompt = true
            }
            // Fresh ceremony THIS session (not an app relaunch) → offer the
            // claim-code prompt once; forge-pack codes ship in the box.
            // `!showBackupPrompt`: a sheet and a full-screen cover presented
            // from the same view in the same tick fight, and the backup-key
            // prompt is the one that must win — a claim code can be redeemed
            // any time, an unbacked identity can't be un-lost.
            if new != nil, ceremony?.phase == .sealed, !DemoFixtures.isActive,
               PerkAuthority.isConfigured, !showBackupPrompt {
                showPostRegistrationRedeem = true
            }
        }
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
        if perkRedeemer?.ownerHash != hash {
            perkRedeemer = PerkRedeemer(ownerHash: hash, identity: identity, sync: sync)
        }
    }

    /// Clear all of this identity's local data + engines (shared by sign-out
    /// and delete). Reads the identity hash BEFORE the identity is cleared.
    private func wipeLocalAndEngines() {
        if let hash = identity.rootIdentity?.credentialIDHash {
            FriendStore.wipe(ownerHash: hash)
            ChatEngine.wipe(ownerHash: hash)
            AppLock.wipe(ownerHash: hash)
            PerkRedeemer.wipe(ownerHash: hash)
        }
        friendStore = nil
        chatEngine = nil
        appLock = nil
        perkRedeemer = nil
        ceremony?.resetPhase()
        sync.resetStatus()
    }

    /// Sign out: wipe local data but KEEP this device's key, so re-login on
    /// this phone is recognized as the same device.
    private func performSignOut() {
        wipeLocalAndEngines()
        DemoFixtures.deactivate()   // exit demo if a reviewer was in it
        identity.signOut()
    }

    /// Delete identity: wipe local data AND this device's keys — nothing of
    /// this identity remains on the phone. The directory tombstone (write-once
    /// marker + tier flip) is written by ProfileView.deleteIdentity BEFORE this
    /// local wipe runs, so sign-in is refused and no device can republish it.
    private func performDelete() {
        wipeLocalAndEngines()
        DemoFixtures.deactivate()   // exit demo if a reviewer was in it
        identity.reset()
    }
}

#Preview {
    ContentView()
}
