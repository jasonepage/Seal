// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import UserNotifications

/// The shell. One screen: your envelopes, the people who hold your keys,
/// and anything you guard for somebody else. Profile is one tap off the
/// toolbar, as before.
///
/// This is also where the owner's HEARTBEAT happens. Every launch and every
/// return to the foreground writes one signed line to the estate log saying
/// "I am here." It needs the phone and, if the app lock is on, Face ID. It
/// never needs the hardware key: a living person who lost their key must not
/// be declared dead by their own product.
struct HomeView: View {
    let myRoot: RootIdentity
    @Bindable var identity: IdentityManager
    @Bindable var ceremony: CeremonyManager
    let sync: SyncEngine
    @Bindable var friendStore: FriendStore
    @Bindable var estateEngine: EstateEngine
    /// "Bills and medical": the second set with the short rule. Its
    /// heartbeat is written beside the letters' on every open; the guarded
    /// estates (what this phone holds for others) live on the letters
    /// engine only, so they are not fetched twice.
    @Bindable var urgentEngine: EstateEngine
    @Bindable var appLock: AppLock
    let onSignOut: () -> Void
    let onDelete: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    /// Parent Mode lives here rather than in ContentView because it is
    /// presentation state, not an engine (Theme/ParentMode.swift). It is per
    /// identity, so it is rebuilt whenever the signed-in identity changes.
    @State private var parentMode: ParentMode?
    @State private var showProfile = false
    /// Set after a heartbeat that the person asked for by name (Siri, the
    /// Action button, a Shortcut: CheckInIntent). One plain line, then gone.
    @State private var checkInLine: String?

    var body: some View {
        shell
        .tint(SealTheme.brass)
        .preferredColorScheme(.dark)
        .environment(\.parentMode, parentMode?.isOn == true)
        .onAppear { ensureParentMode() }
        .onChange(of: myRoot.credentialIDHash) { _, _ in ensureParentMode() }
        .task(id: myRoot.credentialIDHash) {
            guard !DemoFixtures.isActive else { return }
            // Publish unconditionally (see the history of this line in git:
            // a publish gated on prior status once left the one device that
            // most needed to republish as the only one that never did).
            if let endorsement = identity.deviceEndorsement {
                await sync.publishIdentity(myRoot, endorsement: endorsement)
            }
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
            await sync.ensureInviteSubscription(for: myRoot.credentialIDHash)
            // Take the retired messenger's push off this phone. It lives on
            // the server, so an old build's "New sealed message" alert stays
            // registered until something deletes it.
            await sync.retireMessengerSubscriptions(for: myRoot.credentialIDHash)
            await checkInbound()
            await refreshEverything()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.messageArrived)) { _ in
            guard !DemoFixtures.isActive else { return }
            Task {
                await checkInbound()
                await refreshEverything()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !DemoFixtures.isActive {
                Task {
                    try? await UNUserNotificationCenter.current().setBadgeCount(0)
                    await checkInbound()
                    await refreshEverything()
                }
            }
        }
        .alert("Seal", isPresented: Binding(get: { checkInLine != nil }, set: { if !$0 { checkInLine = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(checkInLine ?? "") }
    }

    /// What to say after a check-in the person asked for. Only the true
    /// thing: a phone with nothing sealed has nothing to check in to.
    private func answerCheckInRequest() {
        guard CheckInRequest.consume() else { return }
        if let estate = estateEngine.estate, estate.epochPublished {
            checkInLine = estateEngine.lastError == nil
                ? "You are checked in. The people holding your keys can see you are still here."
                : "Seal could not reach the record just now. Open the app again when you have a signal, and it will check you in."
        } else {
            checkInLine = "Nothing to check in to yet. Seal your envelopes first, and then a check-in means something."
        }
    }

    /// Anything addressed to this phone that arrives through the directory
    /// rather than through a tap: the other half of a forge handshake, and a
    /// handover receipt somebody issued to us.
    ///
    /// The receipt pull used to live in the Handovers screen, which meant a
    /// custodian only learned they had been handed a key if they went looking
    /// for a page most of them would never open. That screen is gone and this
    /// runs on every launch, every foreground and every push instead, which
    /// is where it should have been.
    private func checkInbound() async {
        await ForgeHandshakeService.check(myRoot: myRoot, identity: identity,
                                          friendStore: friendStore, sync: sync)
        let receipts = ReceiptStore(ownerHash: myRoot.credentialIDHash)
        receipts.loadIfNeeded()
        await ReceiptService.check(myRoot: myRoot, identity: identity,
                                   store: receipts, sync: sync)
    }

    /// The heartbeat first, because it is the line that matters most, then
    /// the estates this phone guards.
    private func refreshEverything() async {
        await estateEngine.heartbeat()
        await urgentEngine.heartbeat()
        answerCheckInRequest()
        // The heartbeat just moved, so the owner's own reminders are measured
        // again from now (OwnerNotices). Nothing is posted here; three
        // reminders are scheduled for later and replaced on the next open.
        await OwnerNotices.schedule(engine: estateEngine, ownerHash: myRoot.credentialIDHash)
        await OwnerNotices.schedule(engine: urgentEngine, ownerHash: urgentEngine.storeHash)
        // The "still right?" reminder, at the next due date (SecretReview).
        await SecretReview.schedule(ownerHash: myRoot.credentialIDHash,
                                    hasSecrets: !(estateEngine.allSecrets.isEmpty && urgentEngine.allSecrets.isEmpty),
                                    estateCreatedAt: estateEngine.estate?.createdAt ?? estateEngine.now,
                                    now: estateEngine.now)
        await estateEngine.refreshGuarded()
        // "Do you still have your key?" at each estate's due date
        // (CustodyReminders). A receipt, never a vote.
        await CustodyReminders.schedule(engine: estateEngine, ownerHash: myRoot.credentialIDHash)
        // The CloudKit push for a guarded estate is silent now, because it
        // fires on the owner's heartbeat too. This is what the person
        // actually sees, and only when the state moved (CustodianNotices).
        await CustodianNotices.post(
            estateEngine.guarded.map { (guarded: $0, state: estateEngine.state(of: $0.estateID)) },
            ownerHash: myRoot.credentialIDHash)
    }

    // MARK: - Shell

    private var shell: some View {
        EstateHomeView(myRoot: myRoot, identity: identity, ceremony: ceremony, sync: sync,
                       friendStore: friendStore, lettersEngine: estateEngine, urgentEngine: urgentEngine,
                       appLock: appLock,
                       onOpenProfile: { showProfile = true })
            .sheet(isPresented: $showProfile) {
                ProfileView(myRoot: myRoot, identity: identity, sync: sync,
                            ceremony: ceremony, appLock: appLock,
                            friendStore: friendStore,
                            estateEngine: estateEngine,
                            parentMode: parentMode,
                            onSignOut: onSignOut, onDelete: onDelete,
                            onClose: { showProfile = false })
                    // A sheet is a separate branch of the tree, so the flag and
                    // the type bump are applied again here.
                    .environment(\.parentMode, parentMode?.isOn == true)
                    .parentTypeScale()
            }
    }

    private func ensureParentMode() {
        if parentMode?.ownerHash != myRoot.credentialIDHash {
            parentMode = ParentMode(ownerHash: myRoot.credentialIDHash)
        }
    }
}
