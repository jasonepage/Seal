import SwiftUI
import UserNotifications

/// Tab shell (UI.md §2). Camera tab lands with ephemeral media.
struct HomeView: View {
    let myRoot: RootIdentity
    @Bindable var identity: IdentityManager
    @Bindable var ceremony: CeremonyManager
    let sync: SyncEngine
    @Bindable var friendStore: FriendStore
    @Bindable var chatEngine: ChatEngine
    @Bindable var appLock: AppLock
    @Bindable var perkRedeemer: PerkRedeemer
    let onSignOut: () -> Void
    let onDelete: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    /// Parent Mode lives here rather than in ContentView because it is
    /// presentation state, not an engine — see Theme/ParentMode.swift. It is
    /// per identity, so it is rebuilt whenever the signed-in identity changes.
    @State private var parentMode: ParentMode?
    @State private var showParentProfile = false

    var body: some View {
        Group {
            if parentMode?.isOn == true {
                parentShell
            } else {
                fullShell
            }
        }
        .tint(SealTheme.brass)
        .preferredColorScheme(.dark)
        // Injected ONCE, above both shells. Everything below reads
        // \.parentMode from the environment instead of threading a flag
        // through five initialisers.
        .environment(\.parentMode, parentMode?.isOn == true)
        .onAppear { ensureParentMode() }
        .onChange(of: myRoot.credentialIDHash) { _, _ in ensureParentMode() }
        .task(id: myRoot.credentialIDHash) {
            // Demo mode is fully local: no publishing, no push prompt, no sync
            // (FR-22/23 — demo identities never touch CloudKit or real users).
            guard !DemoFixtures.isActive else { return }
            // Publish unconditionally. This used to be gated on
            // `sync.status == .idle`, which meant that once a publish failed
            // the status stuck at .error and EVERY later launch skipped
            // publishing entirely — the one device that most needed to
            // republish was the only one that never did. An unpublished
            // endorsement makes every message this device signs unverifiable
            // to everyone, so this must not be conditional on prior state.
            if let endorsement = identity.deviceEndorsement {
                await sync.publishIdentity(myRoot, endorsement: endorsement)
            }
            // Push: ask for alert/sound/badge permission for visible banners…
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            // …but register for remote notifications regardless. CloudKit push
            // delivery and silent background refresh don't require the user to
            // have granted alerts, so registering unconditionally keeps sync
            // working even if they tapped "Don't Allow".
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
            await sync.ensureMessageSubscription(for: myRoot.credentialIDHash)
            await sync.ensureInviteSubscription(for: myRoot.credentialIDHash)
            // Complete any friendship where the other person ran the ceremony
            // on THEIR phone (ForgeHandshake.swift). Must run before refreshAll
            // so a brand-new friend's chat is available on this very pass.
            await ForgeHandshakeService.check(myRoot: myRoot, identity: identity,
                                              friendStore: friendStore, sync: sync)
            await chatEngine.refreshAll(myRoot: myRoot, friendStore: friendStore)
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.messageArrived)) { _ in
            guard !DemoFixtures.isActive else { return }
            Task {
                // A handshake arrives as a GroupInvite record, so the invite
                // subscription already pushed us awake — check here too and the
                // friendship lands within seconds of the ceremony ending.
                await ForgeHandshakeService.check(myRoot: myRoot, identity: identity,
                                                  friendStore: friendStore, sync: sync)
                await chatEngine.refreshAll(myRoot: myRoot, friendStore: friendStore)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !DemoFixtures.isActive {
                Task {
                    // Coming back to the app clears the unread badge.
                    try? await UNUserNotificationCenter.current().setBadgeCount(0)
                    await ForgeHandshakeService.check(myRoot: myRoot, identity: identity,
                                                      friendStore: friendStore, sync: sync)
                    await chatEngine.refreshAll(myRoot: myRoot, friendStore: friendStore)
                }
            }
        }
    }

    // MARK: - Shells

    /// The normal four-tab shell (docs/UI.md §2).
    private var fullShell: some View {
        TabView {
            Tab("Chats", systemImage: "bubble.left.and.bubble.right.fill") {
                ChatsView(myRoot: myRoot, chatEngine: chatEngine, friendStore: friendStore)
            }
            Tab("Camera", systemImage: "camera.fill") {
                CameraTab(myRoot: myRoot, chatEngine: chatEngine, friendStore: friendStore)
            }
            Tab("Circle", systemImage: "person.2.fill") {
                FriendsView(myRoot: myRoot, ceremony: ceremony, sync: sync,
                            friendStore: friendStore, chatEngine: chatEngine)
            }
            Tab("You", systemImage: "checkmark.seal.fill") {
                ProfileView(myRoot: myRoot, identity: identity, sync: sync,
                            ceremony: ceremony, appLock: appLock,
                            perkRedeemer: perkRedeemer, parentMode: parentMode,
                            onSignOut: onSignOut, onDelete: onDelete)
            }
        }
    }

    /// Parent Mode: chats and nothing else. No tab bar at all — a tab bar with
    /// one tab is just a stripe of wasted screen — so the chat list IS the app,
    /// and Profile is one avatar tap away in its toolbar.
    ///
    /// The Camera tab is gone but photos are not: the composer inside a chat
    /// opens the same CameraTab in a cover, pre-aimed at that chat.
    /// The Circle tab is gone, which means the friend ceremony is not reachable
    /// in this mode — by design, since the helper who set the phone up is the
    /// one who forges friendships. Profile says so in plain words and the way
    /// back is the same toggle that got here.
    private var parentShell: some View {
        ChatsView(myRoot: myRoot, chatEngine: chatEngine, friendStore: friendStore,
                  onOpenProfile: { showParentProfile = true })
            .sheet(isPresented: $showParentProfile) {
                ProfileView(myRoot: myRoot, identity: identity, sync: sync,
                            ceremony: ceremony, appLock: appLock,
                            perkRedeemer: perkRedeemer, parentMode: parentMode,
                            onSignOut: onSignOut, onDelete: onDelete,
                            onClose: { showParentProfile = false })
                    // A sheet is a separate branch of the tree, so it needs the
                    // flag and the type bump applied again here.
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
