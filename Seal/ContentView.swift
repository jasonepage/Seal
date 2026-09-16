// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//
//  ContentView.swift
//  Seal
//

import SwiftUI

struct ContentView: View {
    @State private var identity: IdentityManager
    @State private var ceremony: CeremonyManager?
    @State private var sync = SyncEngine()
    @State private var friendStore: FriendStore?
    @State private var estateEngine: EstateEngine?
    @State private var appLock: AppLock?
    @State private var showBackupPrompt = false
    @State private var showRecoveryNotice = false
    @Environment(\.scenePhase) private var scenePhase

    /// The ceremony has to exist before the first frame is drawn.
    ///
    /// It used to be built in `.onAppear`. On a phone with no identity yet,
    /// both branches of the Group below were false, so the Group drew
    /// nothing at all, and `.onAppear` does not fire on a view with no
    /// content. Nothing ran, nothing was drawn, and the app came up to a
    /// blank white screen and stayed there. Building the ceremony here means
    /// the registration screen is on screen from the first frame.
    init() {
        let identity = IdentityManager()
        _identity = State(initialValue: identity)
        _ceremony = State(initialValue: CeremonyManager(identity: identity))
    }

    var body: some View {
        Group {
            if let root = identity.rootIdentity, let ceremony, let estateEngine, let friendStore, let appLock {
                HomeView(myRoot: root, identity: identity, ceremony: ceremony,
                         sync: sync, friendStore: friendStore, estateEngine: estateEngine,
                         appLock: appLock,
                         onSignOut: performSignOut, onDelete: performDelete)
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
                    // main key is gone and what to do about it. Shown once, 
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
            } else {
                // Should not happen now that the ceremony is built in init,
                // but a view that draws nothing is also a view that never
                // appears, and that is what a blank white screen is made of.
                SealTheme.ink.ignoresSafeArea()
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
            // prompts (it should, nothing has changed about the risk), and
            // signing in on an identity that already has one stays quiet.
            let hasBackup = !(identity.rootIdentity?.backupCredentials ?? []).isEmpty
            let recovered = new.map { RecoveryNotice.needsAcknowledgement(ownerHash: $0) } ?? false
            // A phone that just came back from the dead has a more urgent
            // truth to tell than "add a backup key", and telling it to add
            // one would be advice it cannot take, since that needs the root
            // key it no longer has.
            if new != nil, ceremony?.phase == .sealed, !DemoFixtures.isActive, recovered {
                showRecoveryNotice = true
            } else if new != nil, ceremony?.phase == .sealed, !DemoFixtures.isActive, !hasBackup {
                showBackupPrompt = true
            }
        }
        .overlay {
            if let appLock, appLock.isLocked { AppLockScreen(lock: appLock) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { appLock?.lockIfEnabled() }
        }
        // FR-23: the demo watermark used to be a top-trailing overlay, which
        // sat straight on top of the home screen's toolbar buttons and hid
        // them. It lives in its own strip at the bottom now. safeAreaInset
        // RESERVES that strip, so the watermark can never cover a control,
        // and an empty content view when the watermark is off adds nothing.
        .safeAreaInset(edge: .bottom) {
            if DemoFixtures.showWatermark { DemoWatermark() }
        }
    }

    /// Stores are namespaced per identity, a new identity sees no data
    /// from previous ones.
    private func setupEngines() {
        if ceremony == nil { ceremony = CeremonyManager(identity: identity) }
        guard let hash = identity.rootIdentity?.credentialIDHash else { return }
        if friendStore?.ownerHash != hash {
            friendStore = FriendStore(ownerHash: hash)
        }
        if estateEngine?.ownerHash != hash {
            estateEngine = EstateEngine(ownerHash: hash, identity: identity, sync: sync)
        }
        if appLock?.ownerHash != hash {
            appLock = AppLock(ownerHash: hash)
        }
    }

    /// Clear all of this identity's local data + engines (shared by sign-out
    /// and delete). Reads the identity hash BEFORE the identity is cleared.
    private func wipeLocalAndEngines() {
        if let hash = identity.rootIdentity?.credentialIDHash {
            FriendStore.wipe(ownerHash: hash)
            EstateEngine.wipe(ownerHash: hash)   // the estate, its logs, the guarded index and the media
            ReceiptStore.wipe(ownerHash: hash)   // receipts are evidence, never leave them behind
            TimestampStore.wipe(ownerHash: hash)
            AppLock.wipe(ownerHash: hash)
            CustodianNotices.wipe(ownerHash: hash)   // what this phone has already announced
        }
        friendStore = nil
        estateEngine = nil
        appLock = nil
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

    /// Delete identity: wipe local data AND this device's keys, nothing of
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
