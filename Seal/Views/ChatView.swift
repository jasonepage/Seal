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
    @State private var showCardCompose = false
    /// Photos in Parent Mode. The Camera TAB is gone there, so the composer
    /// opens the same CameraTab as a cover, aimed at this chat — no second
    /// photo UI, just a second door to the existing one.
    @State private var showCamera = false
    @Environment(\.parentMode) private var parentMode
    /// Drives the post-report confirmation alert. Set to the reported sender's
    /// display name so feedback is visible even if no mail client opens.
    @State private var reportedSenderName: String?
    @Environment(\.openURL) private var openURL

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
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.7))
                            Text(ChatEngine.replyPreview(replyingTo))
                                .font(.caption2)
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
                    // Seal a card (docs/CARDS.md). Brass because sealing is a
                    // trust moment (UI.md §1.1).
                    Button { showCardCompose = true } label: {
                        Image(systemName: "seal")
                            .font(.system(size: 22))
                            .foregroundStyle(SealTheme.brass)
                            .frame(minWidth: composerTarget, minHeight: composerTarget)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Seal a card")

                    // Photos. Deliberately NOT brass — a photo is not a trust
                    // moment. Opens the existing camera + send tray.
                    Button { showCamera = true } label: {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(minWidth: composerTarget, minHeight: composerTarget)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Send a photo")

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
                            .frame(minWidth: composerTarget, minHeight: composerTarget)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Send")
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
        .sheet(isPresented: $showCardCompose) {
            CardComposeSheet(chat: engine.chats.first(where: { $0.id == chat.id }) ?? chat,
                             myRoot: myRoot, engine: engine)
        }
        // The whole camera, unchanged, with this chat pre-selected in the send
        // tray. Requires a FriendStore because CameraTab takes one; every real
        // presentation of ChatView passes it.
        .fullScreenCover(isPresented: $showCamera) {
            if let friendStore {
                CameraTab(myRoot: myRoot, chatEngine: engine, friendStore: friendStore,
                          preselectedChat: chat,
                          onClose: { showCamera = false })
            }
        }
        .task {
            // Poll for inbound messages while the chat is open.
            // TODO: CKSubscription push instead of polling.
            while !Task.isCancelled {
                await engine.refresh(chat, myRoot: myRoot)
                await engine.markRead(in: chat, from: myRoot)   // ack what I've now seen
                // An acceptance or a confirmation may have just landed. Doing
                // this here as well as in refreshAll is what makes the last
                // step of an introduction complete while both people are
                // looking at the chat, instead of on the next cold launch.
                if let friendStore {
                    await engine.ensureIntroductionsProgressed(myRoot: myRoot, friendStore: friendStore)
                }
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
        // App Store 1.2: report must give clear, immediate feedback even when
        // no mail client is configured to receive the routed report.
        .alert("Reported", isPresented: Binding(
            get: { reportedSenderName != nil },
            set: { if !$0 { reportedSenderName = nil } }
        )) {
            Button("OK", role: .cancel) { reportedSenderName = nil }
        } message: {
            Text("Thanks — \(reportedSenderName ?? "this person") is now blocked and won't appear in your chats. We review reports and remove violators within 24 hours.")
        }
    }

    /// 52pt in Parent Mode (Theme/ParentMode.swift), otherwise the glyphs keep
    /// their natural size and the row stays compact.
    private var composerTarget: CGFloat { parentMode ? 52 : 0 }

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
        } else if let offer = message.introduction {
            // An introduction is a bubble kind but not a bubble shape — like a
            // sealed card it spans the content width, because it asks for a
            // decision and must not be skimmed past as ordinary chat.
            IntroductionBubble(message: message, offer: offer, chat: chat, myRoot: myRoot,
                               engine: engine, friendStore: friendStore)
        } else if let card = message.card {
            // A card is a bubble kind, but not a bubble shape — it spans the
            // content width so it can never be skimmed past as ordinary chat.
            // Reactions and replies still work on it: it carries the same
            // wireID as any other message.
            VStack(alignment: .leading, spacing: 2) {
                if message.replyPreview != nil { replyQuote(message) }
                SealedCardBubble(message: message, card: card, mine: mine,
                                 senderName: cardSenderName(message, mine: mine),
                                 senderIdentity: identity(for: message.senderHash),
                                 senderLinked: isLinkedFriend(message.senderHash),
                                 engine: engine)
                    .contextMenu { cardMenu(message, mine: mine) }
                reactionChips(message)
            }
        } else {
            messageBubble(message, mine: mine)
        }
    }

    /// Long-press menu for a card. Same actions as a bubble minus the reaction
    /// picker's visual noise — react, reply, and (for others' cards) the
    /// Guideline 1.2 report/block pair.
    @ViewBuilder
    private func cardMenu(_ message: ChatEngine.ChatMessage, mine: Bool) -> some View {
        ForEach(Self.reactionEmojis, id: \.self) { emoji in
            Button {
                Task { await engine.react(emoji, to: message, in: chat, from: myRoot) }
            } label: {
                Text("\(emoji)  React")
            }
        }
        Divider()
        Button { replyingTo = message } label: {
            Label("Reply", systemImage: "arrowshape.turn.up.left")
        }
        if !mine {
            Divider()
            Button(role: .destructive) {
                engine.block(message.senderHash)
                if let url = reportMailURL(for: message) { openURL(url) }
                reportedSenderName = senderName(message)
            } label: {
                Label("Report", systemImage: "exclamationmark.bubble")
            }
            Button(role: .destructive) {
                engine.block(message.senderHash)
            } label: {
                Label("Block \(senderName(message))", systemImage: "hand.raised")
            }
        }
    }

    /// True when this sender is an INTRODUCED friend, so the card's ring and
    /// fingerprint phrase drop brass (docs/INTRODUCTIONS.md).
    private func isLinkedFriend(_ hash: String) -> Bool {
        guard let friend = friendStore?.friends.first(where: { $0.id == hash }) else { return false }
        return !friend.friendship.isInPerson
    }

    /// Full identity for a member hash — the card detail sheet needs the tier
    /// and root public key to render the ring and the fingerprint phrase.
    ///
    /// Falls back to the engine's directory cache, because a colony can contain
    /// someone you've never forged with: the FriendStore has nothing for them,
    /// but `refresh` has already fetched their record to verify their messages.
    private func identity(for hash: String) -> RootIdentity? {
        if hash == myRoot.credentialIDHash { return myRoot }
        return friendStore?.friends.first { $0.id == hash }?.identity
            ?? engine.cachedIdentity(for: hash)
    }

    /// Name on a card's verification line. Same fallback chain as `identity`,
    /// so a card from a non-friend colony member isn't attributed to "Someone".
    private func cardSenderName(_ message: ChatEngine.ChatMessage, mine: Bool) -> String {
        if mine { return myRoot.displayName }
        return identity(for: message.senderHash)?.displayName ?? senderName(message)
    }

    private func senderName(_ message: ChatEngine.ChatMessage) -> String {
        friendStore?.friends.first { $0.id == message.senderHash }?
            .identity.displayName ?? "Someone"
    }

    /// Pre-filled report email to the developer (App Store 1.2 moderation).
    /// Reporting also blocks; this just routes the flag to a human inbox.
    private func reportMailURL(for m: ChatEngine.ChatMessage) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?+")   // so message text can't break the URL
        let subject = "Seal report"
        let body = """
        A user reported a message in Seal.

        Reported message: "\(m.mediaRef != nil ? "[photo]" : ChatEngine.summary(m))"
        Reported user (root hash): \(m.senderHash)
        Message id: \(m.wireID ?? "—")
        Reporter (root hash): \(myRoot.credentialIDHash)

        Action if upheld: tombstone the reported identity in the directory.
        """
        let s = subject.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let b = body.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: "mailto:jasonepage@gmail.com?subject=\(s)&body=\(b)")
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
                    if !mine {
                        Divider()
                        Button(role: .destructive) {
                            engine.block(message.senderHash)              // protect immediately
                            if let url = reportMailURL(for: message) {     // email the report to the dev
                                openURL(url)
                            }
                            // Visible confirmation regardless of whether a mail
                            // client opened (App Store 1.2: report must clearly work).
                            reportedSenderName = senderName(message)
                        } label: {
                            Label("Report", systemImage: "exclamationmark.bubble")
                        }
                        Button(role: .destructive) {
                            engine.block(message.senderHash)
                        } label: {
                            Label("Block \(senderName(message))", systemImage: "hand.raised")
                        }
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
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(SealTheme.brass.opacity(0.8))
                Text(message.replyPreview ?? "")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(parentMode ? 2 : 1)
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
                        Text(emoji).font(.caption)
                        if count > 1 {
                            Text("\(count)")
                                .font(.caption2)
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
    /// Set from the "Introduce … to" row (docs/INTRODUCTIONS.md). 1:1 chats
    /// only, in-person friends only, and never in Parent Mode — accepting an
    /// introduction is simplified-mode work, making one is not.
    @State private var introducing: FriendStore.StoredFriend?
    /// Verified perks per member hash — seeded from the FriendStore cache,
    /// refreshed from the directory while the drawer is open.
    @State private var perksByMember: [String: [PerkAttestation]] = [:]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.parentMode) private var parentMode

    private var iAmAdmin: Bool {
        chat.creatorHash == myRoot.credentialIDHash && chat.memberHashes.count > 2
    }

    var body: some View {
        ZStack {
            SealTheme.ink.ignoresSafeArea()
            // Scrollable. At accessibility sizes — and with Parent Mode's
            // Details expanded — this is taller than the sheet, and a bare
            // VStack does not clip or scroll: it overflows in both directions
            // and the bottom becomes unreachable (the same bug the ceremony
            // screens hit).
            ScrollView {
                VStack(spacing: 20) {
                    Label("End-to-end sealed", systemImage: "checkmark.shield.fill")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(SealTheme.brass)
                        .padding(.top, 28)

                    // The plain sentence for everyone. The technical one is
                    // not deleted: it sits in the Details disclosure lower down
                    // in this same drawer, verbatim.
                    Text("Messages here are locked to your phone and theirs. Anything that doesn't check out is never shown to you.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    VStack(spacing: 14) {
                        memberRow(name: "\(myRoot.displayName) (you)", tier: myRoot.tier, publicKey: myRoot.publicKey,
                                  perks: perksByMember[myRoot.credentialIDHash] ?? [],
                                  plainLine: "This is you.")
                        ForEach(otherMembers, id: \.credentialIDHash) { member in
                            HStack {
                                memberRow(name: member.displayName, tier: member.tier, publicKey: member.publicKey,
                                          perks: perksByMember[member.credentialIDHash] ?? [],
                                          // A linked friend NEVER gets the
                                          // "This is really <name>." line: this
                                          // phone has no idea whether it is,
                                          // and saying so would be the exact
                                          // lie the tier exists to prevent.
                                          plainLine: parentMode && !isLinked(member.credentialIDHash)
                                              ? "This is really \(member.displayName)." : nil,
                                          linked: isLinked(member.credentialIDHash),
                                          provenance: provenanceLine(member.credentialIDHash),
                                          vouchLine: vouchLine(member))
                                if iAmAdmin {
                                    Button { removing = member } label: {
                                        Image(systemName: "minus.circle")
                                            .foregroundStyle(.orange.opacity(0.8))
                                    }
                                }
                                // Block / unblock this member (reversible; App Store 1.2).
                                if let engine {
                                    Button {
                                        let h = member.credentialIDHash
                                        if engine.isBlocked(h) { engine.unblock(h) } else { engine.block(h) }
                                    } label: {
                                        Image(systemName: engine.isBlocked(member.credentialIDHash)
                                              ? "hand.raised.slash.fill" : "hand.raised")
                                            .foregroundStyle(engine.isBlocked(member.credentialIDHash)
                                                             ? SealTheme.brass : .white.opacity(0.5))
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 24)

                    // Introduce this person to someone else you've met in
                    // person. 1:1 only (an introduction names exactly two
                    // people) and in-person only (it doesn't chain). The
                    // old "not in Parent Mode" rule went with the mode:
                    // making an introduction is not an advanced act, and
                    // gating it on a text-size switch would hide a
                    // headline feature from whoever turned the type up.
                    if let candidate = introduceCandidate {
                        Button {
                            introducing = candidate
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "link")
                                    .foregroundStyle(SealTheme.silver)
                                Text("Introduce \(candidate.identity.displayName) to…")
                                    .font(.system(.callout, design: .rounded, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.9))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.3))
                            }
                            .padding(14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, 24)
                    }

                    // The Details disclosure is now everyone's. It is a
                    // strict superset of what the top level used to show:
                    // the technical sentence, every member's fingerprint
                    // phrase, the instruction to say them out loud, and the
                    // epoch line. Nothing was dropped, it moved one tap
                    // down (docs/COLDSTART.md).
                    parentDetails
                        .padding(.horizontal, 24)

                    // The TTL disclosure stays visible in BOTH modes. It is a
                    // limitation of the promise this drawer makes, not vocabulary,
                    // and tucking a limitation behind a disclosure is how honest
                    // copy quietly becomes dishonest.
                    if chat.ttl != nil {
                        Text("Disappearing messages are deleted from devices on schedule, but screenshots are always possible.")
                            .font(.caption2)
                            .foregroundStyle(.orange.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    Spacer(minLength: 12)
                }
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .preferredColorScheme(.dark)
        .sheet(item: $introducing) { friend in
            if let friendStore, let engine {
                IntroduceSheet(subject: friend, myRoot: myRoot,
                               engine: engine, friendStore: friendStore)
            }
        }
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

    /// The one friend in a 1:1 chat this device may introduce to somebody
    /// else. nil for groups, for non-friends, and for linked friends.
    private var introduceCandidate: FriendStore.StoredFriend? {
        guard chat.memberHashes.count == 2,
              // The sheet needs both of these; drawing the row without them
              // would present an empty sheet the user can only swipe away.
              friendStore != nil, engine != nil,
              let other = chat.memberHashes.first(where: { $0 != myRoot.credentialIDHash }),
              let friend = friendStore?.friends.first(where: { $0.id == other }),
              friend.friendship.isInPerson
        else { return nil }
        return friend
    }

    private func friendship(_ hash: String) -> Friendship? {
        friendStore?.friends.first(where: { $0.id == hash })?.friendship
    }

    private func isLinked(_ hash: String) -> Bool {
        guard let friendship = friendship(hash) else { return false }
        return !friendship.isInPerson
    }

    private func introducerName(_ hash: String) -> String {
        friendStore?.friends.first(where: { $0.id == hash })?.identity.displayName
            ?? engine?.cachedIdentity(for: hash)?.displayName
            ?? "a mutual friend"
    }

    /// "Introduced by Mom · 25 Aug 2026" — the provenance line the drawer owes
    /// anyone looking at a linked friend.
    private func provenanceLine(_ hash: String) -> String? {
        guard let proof = friendship(hash)?.introduction else { return nil }
        return "Introduced by \(introducerName(proof.introducerHash)) · "
            + proof.introducedAt.formatted(date: .abbreviated, time: .omitted)
    }

    /// The honest claim, in the words the design specifies. Never "Verified".
    private func vouchLine(_ member: RootIdentity) -> String? {
        guard let proof = friendship(member.credentialIDHash)?.introduction else { return nil }
        let by = introducerName(proof.introducerHash)
        return "You haven't met \(member.displayName) in person through Seal. \(by) has, and vouched for this connection."
    }

    private var otherMembers: [RootIdentity] {
        chat.memberHashes
            .filter { $0 != myRoot.credentialIDHash }
            .compactMap { hash in friendStore?.friends.first(where: { $0.id == hash })?.identity }
    }

    private func memberRow(name: String, tier: IdentityTier, publicKey: Data,
                           perks: [PerkAttestation] = [],
                           plainLine: String? = nil,
                           linked: Bool = false,
                           provenance: String? = nil,
                           vouchLine: String? = nil) -> some View {
        HStack(spacing: 12) {
            IdentityRing(displayName: name, tier: tier, size: parentMode ? 46 : 38, linked: linked)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(.callout, design: .rounded, weight: .medium))
                    .foregroundStyle(.white)
                // Provenance first, because it changes what every line under
                // it means (docs/INTRODUCTIONS.md).
                if let provenance {
                    Text(provenance)
                        .font(.caption)
                        .foregroundStyle(SealTheme.silver)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let vouchLine {
                    Text(vouchLine)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let plainLine {
                    // The same claim in words instead of key material. Not
                    // brass: brass stays attached to the actual key facts, and
                    // the fingerprint phrase itself is one disclosure away.
                    Text(plainLine)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
                // A member with no plain line (a linked friend, where this
                // phone cannot say "this is really them") shows no raw
                // fingerprint phrase here. Every member's phrase is in the
                // Details disclosure, which is where UI.md 6.5 put it and
                // where it now stays for everyone.
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
        .parentTapTarget()
    }

    /// Parent Mode moves the vocabulary — the technical sentence, the
    /// fingerprint phrases, the epoch count — behind one disclosure.
    ///
    /// It MOVES it. Nothing here is deleted, because the helper who set the
    /// phone up has to be able to reach exactly what the normal drawer shows,
    /// and "is this really them?" is the question this screen exists to answer.
    private var parentDetails: some View {
        DisclosureGroup("Details") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Every message is encrypted on-device and its signature chain is verified before display. Unverifiable messages are dropped.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                phraseRow("\(myRoot.displayName) (you)", myRoot.publicKey)
                ForEach(otherMembers, id: \.credentialIDHash) { member in
                    phraseRow(member.displayName, member.publicKey,
                              linked: isLinked(member.credentialIDHash))
                }
                Text("Say these phrases out loud together — matching phrases mean matching keys.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
                if chat.currentEpoch > 0 {
                    Text("Keys rotated \(chat.currentEpoch) time\(chat.currentEpoch == 1 ? "" : "s") — removed members can't read anything sent after their removal.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
        }
        .tint(.white.opacity(0.6))
        .font(.system(.callout, design: .rounded, weight: .semibold))
        .foregroundStyle(.white.opacity(0.85))
    }

    private func phraseRow(_ name: String, _ publicKey: Data, linked: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
            // Same rule as the row above, and it has to be repeated here
            // because Parent Mode's Details is the OTHER place a phrase
            // renders: brass never describes a friendship nobody's device
            // watched being forged.
            Text(FingerprintPhrase.phrase(for: publicKey))
                .font(.callout)
                .foregroundStyle(linked ? SealTheme.silver : SealTheme.brass)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
