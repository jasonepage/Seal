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
    /// Carried only so this view can present FriendsView, which owns every
    /// route into the ceremony. The chat list itself never touches either one.
    @Bindable var ceremony: CeremonyManager
    let sync: SyncEngine
    /// Opens Profile. Required, not optional: with one shell there is no
    /// "You" tab any more, so this button is the ONLY route there.
    let onOpenProfile: () -> Void
    @Environment(\.parentMode) private var parentMode
    @State private var showNewGroup = false
    @State private var showPeople = false
    @State private var selectedChatID: UUID?

    var body: some View {
        // NavigationSplitView gives iPad a sidebar (list) + detail (open chat)
        // and AUTOMATICALLY collapses to the normal push/pop stack on iPhone,
        // so one structure serves both. Selection drives the detail pane.
        NavigationSplitView {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                if chatEngine.chats.isEmpty {
                    // Social surface, so the mascot is allowed (UI.md 1.1).
                    //
                    // One version for both shells (docs/COLDSTART.md 3.4). The
                    // old normal-shell copy sent people to a "Circle" tab to
                    // "forge" a friend, two words nobody was handed, and the
                    // Simplified copy told the reader to wait for whoever set
                    // the phone up. Both are dead ends for someone who
                    // installed this alone, which is now the common case.
                    VStack(spacing: 22) {
                        SealMascot(size: 64,
                                   line: "No chats yet.",
                                   sub: "Seal only works with people\nyou've set up in person.")
                        Button { showPeople = true } label: {
                            Label("Add someone", systemImage: "person.badge.plus")
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(SealTheme.brass)
                        .parentTapTarget()
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                // The only route to Profile now that the "You" tab is gone.
                // The identity ring is a trust artifact, so brass here is the
                // tier's brass, not decoration (UI.md §1.1).
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onOpenProfile) {
                        IdentityRing(displayName: myRoot.displayName,
                                     tier: myRoot.tier, size: 34)
                            .frame(width: 52, height: 52)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Your profile and settings")
                }
                // Where the Circle tab went: the people list, the seal for
                // someone else to scan, introductions, and the ceremony.
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showPeople = true } label: {
                        Image(systemName: "person.2.fill")
                            .foregroundStyle(SealTheme.brass)
                    }
                    .accessibilityLabel("People")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Composing only. Adding people lives behind the people
                    // button beside this one and nowhere else, because two
                    // doors into the same room is not a convenience.
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
            .sheet(isPresented: $showPeople) {
                FriendsView(myRoot: myRoot, ceremony: ceremony, sync: sync,
                            friendStore: friendStore, chatEngine: chatEngine,
                            onClose: { showPeople = false })
                    .environment(\.parentMode, parentMode)
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
