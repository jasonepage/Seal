import SwiftUI

/// Chat list (UI.md §3.3): conversations with identity-ring avatars.
struct ChatsView: View {
    let myRoot: RootIdentity
    @Bindable var chatEngine: ChatEngine
    @Bindable var friendStore: FriendStore
    @State private var showNewGroup = false
    @State private var selectedChatID: UUID?

    var body: some View {
        // NavigationSplitView gives iPad a sidebar (list) + detail (open chat)
        // and AUTOMATICALLY collapses to the normal push/pop stack on iPhone,
        // so one structure serves both. Selection drives the detail pane.
        NavigationSplitView {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                if chatEngine.chats.isEmpty {
                    SealMascot(size: 64,
                               line: "No colonies yet.",
                               sub: "Forge a friend in Circle,\nthen haul out here together.")
                } else {
                    List(selection: $selectedChatID) {
                        ForEach(chatEngine.chats) { chat in
                            row(chat)
                                .tag(chat.id)
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
                            // Create + open the note-to-self chat in the detail.
                            selectedChatID = chatEngine.ensureNoteToSelf(myHash: myRoot.credentialIDHash).id
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
        } detail: {
            if let id = selectedChatID,
               let chat = chatEngine.chats.first(where: { $0.id == id }) {
                ChatView(chat: chat, myRoot: myRoot, engine: chatEngine, friendStore: friendStore)
            } else {
                ZStack {
                    SealTheme.ink.ignoresSafeArea()
                    SealMascot(size: 56,
                               line: "Pick a chat",
                               sub: "Your sealed conversations\nopen on this side.")
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ chat: ChatEngine.Chat) -> some View {
        let tier = tierFor(chat)
        let last = chatEngine.messages(for: chat).last { $0.kind != "screenshot" }
        return HStack(spacing: 12) {
            IdentityRing(displayName: chat.name, tier: tier, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(chat.name)
                        .foregroundStyle(.white)
                        .font(.system(.body, design: .rounded, weight: .medium))
                    if chat.memberHashes.count > 2 {
                        HStack(spacing: 3) {
                            SealFigure(detailed: false, tint: .white.opacity(0.5))
                                .frame(height: 9)
                            Text("\(chat.memberHashes.count)")
                                .font(.system(.caption2, design: .rounded, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.08), in: Capsule())
                    }
                }
                Text(last.map { m in
                    let body = m.mediaRef != nil ? "📷 Photo" : m.text
                    return m.senderHash == myRoot.credentialIDHash ? "You: \(body)" : body
                } ?? "Sealed and ready")
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
