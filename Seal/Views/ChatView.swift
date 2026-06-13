import SwiftUI

/// Minimal conversation screen — proves the E2EE pipeline end to end.
/// Full ChatUI per docs/UI.md §3.3 comes after the slice is verified.
struct ChatView: View {
    let chat: ChatEngine.Chat
    let myRoot: RootIdentity
    @Bindable var engine: ChatEngine
    var friendStore: FriendStore? = nil
    @State private var draft = ""
    @State private var showVerification = false
    @State private var replyingTo: ChatEngine.ChatMessage?

    var body: some View {
        ZStack {
            SealTheme.ink.ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(engine.messages(for: chat)) { message in
                                bubble(message)
                                    .id(message.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    }
                    .onChange(of: engine.messages(for: chat).count) {
                        if let last = engine.messages(for: chat).last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                if let error = engine.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.horizontal)
                }

                let typing = engine.typingMembers(in: chat, myRoot: myRoot)
                if !typing.isEmpty {
                    HStack {
                        Text(typingText(typing))
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 2)
                }

                if let replyingTo {
                    HStack(spacing: 8) {
                        Image(systemName: "arrowshape.turn.up.left.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(SealTheme.brass.opacity(0.8))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Replying to \(authorName(replyingTo.senderHash))")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.7))
                            Text(ChatEngine.replyPreview(replyingTo))
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(1)
                        }
                        Spacer()
                        Button { self.replyingTo = nil } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }

                HStack(spacing: 12) {
                    TextField("Sealed message…", text: $draft)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                        .foregroundStyle(.white)
                    Button {
                        let text = draft.trimmingCharacters(in: .whitespaces)
                        guard !text.isEmpty else { return }
                        draft = ""
                        let reply = replyingTo
                        replyingTo = nil
                        Task { await engine.send(text, in: chat, from: myRoot, replyingTo: reply) }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(SealTheme.brass)
                    }
                }
                .padding(12)
            }
        }
        .navigationTitle(chat.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { showVerification = true } label: {
                    VStack(spacing: 1) {
                        Text(chat.name)
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(.white)
                        ColonyBar(chat: chat, myRoot: myRoot, friendStore: friendStore)
                    }
                }
                .buttonStyle(.plain)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section("Disappearing messages") {
                        ttlOption("Off", nil)
                        ttlOption("1 minute", 60)
                        ttlOption("1 hour", 3600)
                        ttlOption("1 day", 86400)
                    }
                } label: {
                    Image(systemName: currentTTL == nil ? "hourglass" : "hourglass.tophalf.filled")
                        .foregroundStyle(currentTTL == nil ? .white.opacity(0.5) : SealTheme.brass)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showVerification = true } label: {
                    Image(systemName: "checkmark.shield")
                        .foregroundStyle(SealTheme.brass)
                }
            }
        }
        .sheet(isPresented: $showVerification) {
            VerificationSheet(chat: engine.chats.first(where: { $0.id == chat.id }) ?? chat,
                              myRoot: myRoot, friendStore: friendStore, engine: engine)
                .presentationDetents([.medium, .large])
        }
        .task {
            // Poll for inbound messages while the chat is open.
            // TODO: CKSubscription push instead of polling.
            while !Task.isCancelled {
                await engine.refresh(chat, myRoot: myRoot)
                await engine.markRead(in: chat, from: myRoot)   // ack what I've now seen
                try? await Task.sleep(for: .seconds(4))
            }
        }
        // NFR-7: best-effort screenshot disclosure, Snapchat-standard.
        // Only fires while this chat is open and frontmost.
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            Task { await engine.sendScreenshotNotice(in: chat, from: myRoot) }
        }
        // Best-effort typing ping while composing (throttled in the engine).
        .onChange(of: draft) { _, newValue in
            guard !newValue.isEmpty else { return }
            Task { await engine.sendTyping(in: chat, from: myRoot) }
        }
    }

    private var currentTTL: TimeInterval? {
        engine.chats.first(where: { $0.id == chat.id })?.ttl
    }

    /// The most recent message I sent — the only one that carries a read label.
    private var lastMyMessageID: UUID? {
        engine.messages(for: chat).last { $0.senderHash == myRoot.credentialIDHash }?.id
    }

    private func typingText(_ hashes: [String]) -> String {
        let names = hashes.map { hash in
            friendStore?.friends.first { $0.id == hash }?.identity.displayName ?? "Someone"
        }
        return names.count == 1 ? "\(names[0]) is typing…" : "\(names.count) people are typing…"
    }

    private func ttlOption(_ label: String, _ ttl: TimeInterval?) -> some View {
        Button {
            engine.setTTL(ttl, for: chat)
        } label: {
            if currentTTL == ttl {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    @ViewBuilder
    private func bubble(_ message: ChatEngine.ChatMessage) -> some View {
        let mine = message.senderHash == myRoot.credentialIDHash
        if message.kind == "screenshot" {
            HStack(spacing: 5) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 10))
                Text(mine ? "You took a screenshot"
                          : "\(senderName(message)) took a screenshot")
                    .font(.caption2)
            }
            .foregroundStyle(.orange.opacity(0.75))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
        } else {
            messageBubble(message, mine: mine)
        }
    }

    private func senderName(_ message: ChatEngine.ChatMessage) -> String {
        friendStore?.friends.first { $0.id == message.senderHash }?
            .identity.displayName ?? "Someone"
    }

    /// Quick-pick reactions surfaced on long-press (FR-11).
    private static let reactionEmojis = ["❤️", "😂", "👍", "🔥", "😮", "😢"]

    @ViewBuilder
    private func messageBubble(_ message: ChatEngine.ChatMessage, mine: Bool) -> some View {
        HStack {
            if mine { Spacer(minLength: 48) }
            VStack(alignment: .trailing, spacing: 2) {
                if message.replyPreview != nil {
                    replyQuote(message)
                }
                Group {
                    if message.mediaRef != nil {
                        MediaBubble(message: message, engine: engine)
                    } else {
                        Text(message.text)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(
                                mine ? SealTheme.brass.opacity(0.25) : Color.white.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 18))
                    }
                }
                .contextMenu {
                    ForEach(Self.reactionEmojis, id: \.self) { emoji in
                        Button {
                            Task { await engine.react(emoji, to: message, in: chat, from: myRoot) }
                        } label: {
                            Text("\(emoji)  React")
                        }
                    }
                    Divider()
                    Button {
                        replyingTo = message
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                }
                reactionChips(message)
                HStack(spacing: 4) {
                    if message.expiresAt != nil {
                        Image(systemName: "hourglass")
                            .font(.system(size: 9))
                            .foregroundStyle(SealTheme.brass.opacity(0.7))
                    }
                    if mine {
                        Image(systemName: message.delivered ? "checkmark.seal" : "clock")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    if mine, message.id == lastMyMessageID {
                        let readers = engine.readerCount(of: message, in: chat)
                        if readers > 0 {
                            Text(chat.memberHashes.count > 2 ? "Read by \(readers)" : "Read")
                                .font(.system(size: 9))
                                .foregroundStyle(SealTheme.brass.opacity(0.7))
                        }
                    }
                }
            }
            if !mine { Spacer(minLength: 48) }
        }
    }

    /// Quoted snippet shown above a reply bubble. Renders from the snippet the
    /// reply carries, so it works even when the original message isn't loaded.
    @ViewBuilder
    private func replyQuote(_ message: ChatEngine.ChatMessage) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1)
                .fill(SealTheme.brass.opacity(0.6))
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(authorName(message.replySenderHash))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SealTheme.brass.opacity(0.8))
                Text(message.replyPreview ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Display name for a member hash ("You" for self).
    private func authorName(_ hash: String?) -> String {
        guard let hash else { return "Reply" }
        if hash == myRoot.credentialIDHash { return "You" }
        return friendStore?.friends.first { $0.id == hash }?.identity.displayName ?? "Someone"
    }

    /// Aggregated reaction pills under a bubble: one capsule per distinct emoji,
    /// with a count when more than one person reacted the same way.
    @ViewBuilder
    private func reactionChips(_ message: ChatEngine.ChatMessage) -> some View {
        if let reactions = message.reactions, !reactions.isEmpty {
            let counts = Dictionary(grouping: reactions.values, by: { $0 }).mapValues(\.count)
            HStack(spacing: 4) {
                ForEach(counts.sorted { $0.key < $1.key }, id: \.key) { emoji, count in
                    HStack(spacing: 2) {
                        Text(emoji).font(.system(size: 11))
                        if count > 1 {
                            Text("\(count)")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.08), in: Capsule())
                }
            }
        }
    }
}

/// Encrypted photo: fetches the blob, decrypts with the key that arrived
/// inside the E2EE payload, shimmers while working.
struct MediaBubble: View {
    let message: ChatEngine.ChatMessage
    @Bindable var engine: ChatEngine
    @State private var imageData: Data?
    @State private var failed = false
    @State private var fullscreen = false

    var body: some View {
        Group {
            if let imageData, let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 240, maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .onTapGesture { fullscreen = true }
                    .fullScreenCover(isPresented: $fullscreen) {
                        ZStack {
                            Color.black.ignoresSafeArea()
                            Image(uiImage: uiImage).resizable().scaledToFit()
                        }
                        .onTapGesture { fullscreen = false }
                    }
            } else if failed {
                Label("Photo unavailable", systemImage: "photo.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(12)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(.white.opacity(0.06))
                        .frame(width: 240, height: 240)
                    VStack(spacing: 6) {
                        ProgressView().tint(SealTheme.brass)
                        Text("Unsealing…")
                            .font(.caption2)
                            .foregroundStyle(SealTheme.brass.opacity(0.8))
                    }
                }
            }
        }
        .task {
            imageData = await engine.mediaData(for: message)
            if imageData == nil { failed = true }
        }
    }
}

/// The verification drawer (UI.md §3.3): security status one gesture away.
struct VerificationSheet: View {
    let chat: ChatEngine.Chat
    let myRoot: RootIdentity
    let friendStore: FriendStore?
    var engine: ChatEngine? = nil
    @State private var removing: RootIdentity?
    /// Verified perks per member hash — seeded from the FriendStore cache,
    /// refreshed from the directory while the drawer is open.
    @State private var perksByMember: [String: [PerkAttestation]] = [:]
    @Environment(\.dismiss) private var dismiss

    private var iAmAdmin: Bool {
        chat.creatorHash == myRoot.credentialIDHash && chat.memberHashes.count > 2
    }

    var body: some View {
        ZStack {
            SealTheme.ink.ignoresSafeArea()
            VStack(spacing: 20) {
                Label("End-to-end sealed", systemImage: "checkmark.shield.fill")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(SealTheme.brass)
                    .padding(.top, 28)

                Text("Every message is encrypted on-device and its signature chain is verified before display. Unverifiable messages are dropped.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                VStack(spacing: 14) {
                    memberRow(name: "\(myRoot.displayName) (you)", tier: myRoot.tier, publicKey: myRoot.publicKey,
                              perks: perksByMember[myRoot.credentialIDHash] ?? [])
                    ForEach(otherMembers, id: \.credentialIDHash) { member in
                        HStack {
                            memberRow(name: member.displayName, tier: member.tier, publicKey: member.publicKey,
                                      perks: perksByMember[member.credentialIDHash] ?? [])
                            if iAmAdmin {
                                Button { removing = member } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(.orange.opacity(0.8))
                                }
                            }
                        }
                    }
                }
                .padding(16)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 24)

                Text("Say these phrases out loud together — matching phrases mean matching keys.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                if chat.ttl != nil {
                    Text("Disappearing messages are deleted from devices on schedule, but screenshots are always possible.")
                        .font(.caption2)
                        .foregroundStyle(.orange.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                if chat.currentEpoch > 0 {
                    Text("Keys rotated \(chat.currentEpoch) time\(chat.currentEpoch == 1 ? "" : "s") — removed members can't read anything sent after their removal.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                Spacer()
            }
        }
        .preferredColorScheme(.dark)
        .task { await refreshPerks() }
        .confirmationDialog(
            "Remove \(removing?.displayName ?? "")? Group keys rotate — they can't read anything sent after this.",
            isPresented: .init(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove and rotate keys", role: .destructive) {
                if let member = removing, let engine {
                    Task {
                        await engine.removeMember(member.credentialIDHash, from: chat, myRoot: myRoot)
                        dismiss()
                    }
                }
                removing = nil
            }
        }
    }

    private var otherMembers: [RootIdentity] {
        chat.memberHashes
            .filter { $0 != myRoot.credentialIDHash }
            .compactMap { hash in friendStore?.friends.first(where: { $0.id == hash })?.identity }
    }

    private func memberRow(name: String, tier: IdentityTier, publicKey: Data,
                           perks: [PerkAttestation] = []) -> some View {
        HStack(spacing: 12) {
            IdentityRing(displayName: name, tier: tier, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(.callout, design: .rounded, weight: .medium))
                    .foregroundStyle(.white)
                Text(FingerprintPhrase.phrase(for: publicKey))
                    .font(.callout)
                    .foregroundStyle(SealTheme.brass)
                // Founder EDITION line (never a tier change): only rendered
                // after the full grant+claim chain verified (PerkAuthority).
                ForEach(perks, id: \.grant.codeHashHex) { perk in
                    Text(perk.grant.kind.displayLabel(number: perk.grant.number))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(SealTheme.brass.opacity(0.85))
                }
            }
            Spacer()
        }
    }

    /// Seed from cache, then refresh each member's perks from the directory
    /// and verify the full chain before anything renders.
    private func refreshPerks() async {
        guard PerkAuthority.isConfigured else { return }   // dormant: no fetches, no rendering
        // Cached (already-verified) perks render immediately.
        for friend in friendStore?.friends ?? [] {
            if let cached = friend.perks { perksByMember[friend.id] = cached }
        }
        guard let sync = engine?.sync, !DemoFixtures.isActive else { return }
        for hash in chat.memberHashes {
            guard let raw = try? await sync.fetchPerks(credentialIDHash: hash), !raw.isEmpty,
                  // `?? nil` flattens the try?-of-optional double wrap
                  let (root, endorsements) = (try? await sync.fetchIdentity(credentialIDHash: hash)) ?? nil
            else { continue }
            let verified = PerkAuthority.verifiedPerks(raw, root: root, endorsements: endorsements)
            perksByMember[hash] = verified
            friendStore?.setPerks(verified, for: hash)
        }
    }
}
