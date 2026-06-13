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
    let onReset: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
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
                            perkRedeemer: perkRedeemer, onReset: onReset)
            }
        }
        .tint(SealTheme.brass)
        .preferredColorScheme(.dark)
        .task(id: myRoot.credentialIDHash) {
            // Demo mode is fully local: no publishing, no push prompt, no sync
            // (FR-22/23 — demo identities never touch CloudKit or real users).
            guard !DemoFixtures.isActive else { return }
            if let endorsement = identity.deviceEndorsement, sync.status == .idle {
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
            await chatEngine.refreshAll(myRoot: myRoot, friendStore: friendStore)
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.messageArrived)) { _ in
            guard !DemoFixtures.isActive else { return }
            Task { await chatEngine.refreshAll(myRoot: myRoot, friendStore: friendStore) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !DemoFixtures.isActive {
                Task {
                    // Coming back to the app clears the unread badge.
                    try? await UNUserNotificationCenter.current().setBadgeCount(0)
                    await chatEngine.refreshAll(myRoot: myRoot, friendStore: friendStore)
                }
            }
        }
    }
}
