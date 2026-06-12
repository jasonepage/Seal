import SwiftUI

/// Chat list (UI.md §3.3): conversations with identity-ring avatars.
struct ChatsView: View {
    let myRoot: RootIdentity
    @Bindable var chatEngine: ChatEngine
    @Bindable var friendStore: FriendStore
    @State private var showNewGroup = false

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                if chatEngine.chats.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "seal")
                            .font(.system(size: 44))
                            .foregroundStyle(.white.opacity(0.25))
                        Text("No sealed chats yet.")
                            .foregroundStyle(.white.opacity(0.5))
                        Text("Forge a friend in Circle, then tap them to chat.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.35))
                    }
                } else {
                    List {
                        ForEach(chatEngine.chats) { chat in
                            NavigationLink {
                                ChatView(chat: chat, myRoot: myRoot, engine: chatEngine, friendStore: friendStore)
                            } label: {
                                row(chat)
                            }
                            .listRowBackground(Color.white.opacity(0.05))
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Chats")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showNewGroup = true
                        } label: {
                            Label("New group", systemImage: "person.3.fill")
                        }
                        Button {
                            _ = chatEngine.ensureNoteToSelf(myHash: myRoot.credentialIDHash)
                        } label: {
                            Label("Note to self", systemImage: "lock.square")
                        }
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .foregroundStyle(SealTheme.brass)
                    }
                }
            }
            .sheet(isPresented: $showNewGroup) {
                NewGroupView(myRoot: myRoot, chatEngine: chatEngine, friendStore: friendStore)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ chat: ChatEngine.Chat) -> some View {
        let tier = tierFor(chat)
        let last = chatEngine.messages(for: chat).last
        return HStack(spacing: 12) {
            IdentityRing(displayName: chat.name, tier: tier, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.name)
                    .foregroundStyle(.white)
                    .font(.system(.body, design: .rounded, weight: .medium))
                Text(last.map { $0.senderHash == myRoot.credentialIDHash ? "You: \($0.text)" : $0.text }
                     ?? "Sealed and ready")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer()
            if let last {
                Text(last.sentAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.vertical, 4)
    }

    private func tierFor(_ chat: ChatEngine.Chat) -> IdentityTier {
        let other = chat.memberHashes.first { $0 != myRoot.credentialIDHash }
        if let other, let friend = friendStore.friends.first(where: { $0.id == other }) {
            return friend.identity.tier
        }
        return myRoot.tier
    }
}
