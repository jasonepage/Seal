import SwiftUI

/// Placeholder for the phase 8 home screen, so the tree stays consistent at
/// the phase 7 boundary. Replaced in the next commit.
struct EstateHomeView: View {
    let myRoot: RootIdentity
    @Bindable var identity: IdentityManager
    @Bindable var ceremony: CeremonyManager
    let sync: SyncEngine
    @Bindable var friendStore: FriendStore
    @Bindable var estateEngine: EstateEngine
    @Bindable var appLock: AppLock
    let onOpenProfile: () -> Void

    var body: some View {
        ZStack {
            SealTheme.ink.ignoresSafeArea()
            SealMascot(size: 72, line: "No envelopes yet.", sub: "Write the first one.")
        }
    }
}
