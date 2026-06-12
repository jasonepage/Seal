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
                        Task { await engine.send(text, in: chat, from: myRoot) }
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
                try? await Task.sleep(for: .seconds(4))
            }
        }
        // NFR-7: best-effort screenshot disclosure, Snapchat-standard.
        // Only fires while this chat is open and frontmost.
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            Task { await engine.sendScreenshotNotice(in: chat, from: myRoot) }
        }
    }

    private var currentTTL: TimeInterval? {
        engine.chats.first(where: { $0.id == chat.id })?.ttl
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

    @ViewBuilder
    private func messageBubble(_ message: ChatEngine.ChatMessage, mine: Bool) -> some View {
        HStack {
            if mine { Spacer(minLength: 48) }
            VStack(alignment: .trailing, spacing: 2) {
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
                }
            }
            if !mine { Spacer(minLength: 48) }
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
                    memberRow(name: "\(myRoot.displayName) (you)", tier: myRoot.tier, publicKey: myRoot.publicKey)
                    ForEach(otherMembers, id: \.credentialIDHash) { member in
                        HStack {
                            memberRow(name: member.displayName, tier: member.tier, publicKey: member.publicKey)
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

    private func memberRow(name: String, tier: IdentityTier, publicKey: Data) -> some View {
        HStack(spacing: 12) {
            IdentityRing(displayName: name, tier: tier, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(.callout, design: .rounded, weight: .medium))
                    .foregroundStyle(.white)
                Text(FingerprintPhrase.phrase(for: publicKey))
                    .font(.callout)
                    .foregroundStyle(SealTheme.brass)
            }
            Spacer()
        }
    }
}
