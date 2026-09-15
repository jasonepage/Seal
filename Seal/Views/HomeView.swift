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
    @State private var showProfile = false

    var body: some View {
        shell
        .tint(SealTheme.brass)
        .preferredColorScheme(.dark)
        // Injected ONCE. This flag no longer chooses between two shells, since
        // there is only one: it means bigger type and bigger tap targets, and
        // nothing else. Everything below reads it from the environment rather
        // than taking a flag through five initialisers.
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

    // MARK: - Shell

    /// ONE shell (docs/COLDSTART.md). No tab bar: a chat list is what this app
    /// is, and everything else is one tap off its toolbar.
    ///
    /// Where the four tabs went:
    /// - Camera: the composer inside a chat opens CameraTab in a cover,
    ///   pre-aimed at that chat, which is where a photo was always going.
    /// - Circle: the people button in the chat list toolbar, plus "Add someone"
    ///   in the compose menu for the case that actually starts a friendship.
    /// - You: the identity ring in the leading toolbar slot, which opens this
    ///   sheet.
    /// - Chats: it is the app now.
    private var shell: some View {
        ChatsView(myRoot: myRoot, chatEngine: chatEngine, friendStore: friendStore,
                  ceremony: ceremony, sync: sync,
                  onOpenProfile: { showProfile = true })
            .sheet(isPresented: $showProfile) {
                ProfileView(myRoot: myRoot, identity: identity, sync: sync,
                            ceremony: ceremony, appLock: appLock,
                            perkRedeemer: perkRedeemer, friendStore: friendStore,
                            chatEngine: chatEngine,
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
