import SwiftUI

/// Chat list (UI.md §3.3): conversations with identity-ring avatars.
///
/// In Parent Mode this view IS the app (docs/UI.md §Parent Mode): there is no
/// tab bar, so it carries the one route out — an avatar button in the toolbar
/// that opens Profile.
struct ChatsView: View {
    let myRoot: RootIdentity
    @Bindable var chatEngine: ChatEngine
    @Bindable var friendStore: FriendStore
    /// Set only by the Parent Mode shell. nil in the normal four-tab shell,
    /// where Profile is its own tab and this button would be a duplicate.
    var onOpenProfile: (() -> Void)? = nil
    @Environment(\.parentMode) private var parentMode
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
                    // Social surface, so the mascot is allowed (UI.md §1.1).
                    // The Parent Mode copy can't say "Circle" — that tab isn't
                    // there — and shouldn't say "forge", which means nothing to
                    // someone who wasn't handed the vocabulary.
                    if parentMode {
                        SealMascot(size: 64,
                                   line: "No chats yet.",
                                   sub: "Whoever set up this phone\nadds people for you.")
                    } else {
                        SealMascot(size: 64,
                                   line: "No colonies yet.",
                                   sub: "Forge a friend in Circle,\nthen haul out here together.")
                    }
                } else {
                    List(selection: $selectedChatID) {
                        ForEach(chatEngine.chats) { chat in
                            row(chat)
                                .parentTapTarget(60)
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
                // Parent Mode's only route to Profile. The identity ring is a
                // trust artifact, so brass here is the tier's brass, not
                // decoration (UI.md §1.1).
                if parentMode, let onOpenProfile {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: onOpenProfile) {
                            IdentityRing(displayName: myRoot.displayName,
                                         tier: myRoot.tier, size: 34)
                                .frame(width: 52, height: 52)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Your profile and settings")
                    }
                }
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
        // Applied ONCE here, at the top of the split view: it covers the list,
        // the open chat in the detail pane, and every sheet those present.
        // Adding a second .parentTypeScale() further down would bump twice.
        .parentTypeScale()
    }

    private func row(_ chat: ChatEngine.Chat) -> some View {
        let tier = tierFor(chat)
        let last = chatEngine.messages(for: chat).last { $0.kind != "screenshot" }
        return HStack(spacing: 12) {
            IdentityRing(displayName: chat.name, tier: tier, size: parentMode ? 56 : 44,
                         linked: isLinked(chat))
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
                    // ChatEngine.summary, not `text`: a card's `text` carries
                    // the old-build fallback ("…update Seal to view"), which
                    // reads as nonsense in a list row on a build that renders
                    // cards. It summarises to the card's title instead — never
                    // to its value, since a truncated address in a list row is
                    // an invitation to misread it.
                    let body = ChatEngine.summary(m)
                    return m.senderHash == myRoot.credentialIDHash ? "You: \(body)" : body
                } ?? "Sealed and ready")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(parentMode ? 2 : 1)
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

    /// A 1:1 chat with a LINKED friend gets the silver link ring here too
    /// (docs/INTRODUCTIONS.md). Groups never do — a colony's ring is a chat
    /// avatar, not a claim about one person.
    private func isLinked(_ chat: ChatEngine.Chat) -> Bool {
        guard chat.memberHashes.count == 2,
              let other = chat.memberHashes.first(where: { $0 != myRoot.credentialIDHash }),
              let friend = friendStore.friends.first(where: { $0.id == other })
        else { return false }
        return !friend.friendship.isInPerson
    }

    private func tierFor(_ chat: ChatEngine.Chat) -> IdentityTier {
        let other = chat.memberHashes.first { $0 != myRoot.credentialIDHash }
        if let other, let friend = friendStore.friends.first(where: { $0.id == other }) {
            return friend.identity.tier
        }
        return myRoot.tier
    }
}
