import Foundation
import CloudKit
import CryptoKit
import os

/// E2EE chat over CloudKit (SDS §2, §5). Each member has a per-chat sender
/// chain; per-message keys ratchet forward and are never reused. Inbound
/// messages pass the full verification chain (root → endorsement → signature)
/// before display — unverifiable messages are dropped, never shown.
@Observable
final class ChatEngine {
    /// Messaging-layer diagnostics — same subsystem as WebAuthnDiag, separate
    /// `messaging` category. Logs key FINGERPRINTS (8 hex of SHA256) and counts
    /// only; never key material or plaintext. Read in Console.app filtered on
    /// subsystem `io.github.jasonepage.Seal` category `messaging`.
    static let msgLog = Logger(subsystem: "io.github.jasonepage.Seal", category: "messaging")

    /// 8-hex fingerprint of a PUBLIC key, for correlating desyncs in logs.
    static func fp(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }
    struct Chat: Codable, Identifiable, Hashable {
        let id: UUID
        var name: String
        var memberHashes: [String]      // root credentialIDHashes, including me
        var ttl: TimeInterval?          // disappearing messages (FR-12), nil = keep
        var epoch: UInt64?              // key epoch; bumps on removal (FR-13)
        var creatorHash: String?        // group admin (FR-9); nil for 1:1

        var currentEpoch: UInt64 { epoch ?? 0 }
    }

    struct ChatMessage: Codable, Identifiable, Hashable {
        let id: UUID
        let senderHash: String
        let text: String
        let sentAt: Date
        var delivered: Bool             // round-tripped through CloudKit
        var expiresAt: Date?            // client-enforced (NFR-7: best-effort, disclosed)
        var mediaRef: String?           // MediaAsset record name (encrypted blob)
        var mediaKey: Data?             // content key — arrived inside E2EE payload
        var kind: String?               // nil = normal, "screenshot" = NFR-7 notice
        var wireID: String?             // stable cross-device id "<sender>.e<epoch>.<index>";
                                        // reactions point at this, not the local `id`
        var reactions: [String: String]? // reactorHash → emoji (one reaction per person)
        var replyTo: String?            // wireID of the quoted message (nil if it
                                        // predates wireID — still rendered as a reply)
        var replyPreview: String?       // one-line snippet of the quoted message
        var replySenderHash: String?    // author of the quoted message
    }

    /// What actually gets encrypted — TTL and the media content key travel
    /// inside the sealed payload, invisible to the server.
    private struct MessagePayload: Codable {
        let text: String
        let ttl: TimeInterval?
        var mediaRef: String?
        var mediaKey: Data?
        var kind: String?               // "screenshot" = disclosure notice (NFR-7),
                                        // "reaction" = emoji reaction (no bubble)
        var reactTo: String?            // reaction: target message wireID
        var emoji: String?              // reaction: emoji to apply; "" clears mine
        var replyTo: String?            // reply: quoted message wireID (may be nil)
        var replyPreview: String?       // reply: quoted snippet
        var replySenderHash: String?    // reply: quoted author
        var readUpTo: Date?             // read receipt: sentAt of latest message seen
    }

    private struct ChainState: Codable {
        var chainKey: Data
        var index: UInt64
        /// Transcript chain (SDS §2): hash of this sender's previous ciphertext.
        /// Bound into the AAD and signature of the next message, so the server
        /// can't substitute, drop, or reorder a sender's messages undetected.
        var lastMessageHash: Data?
    }

    /// AAD binds group, epoch, sender, index, AND the previous message hash.
    /// Epoch 0 keeps the v2 (no-epoch) format for compatibility.
    private static func messageAAD(groupID: String, epoch: UInt64, sender: String, index: UInt64, prevHash: Data?) -> Data {
        let prev = (prevHash ?? Data()).hexString
        return epoch == 0
            ? Data("seal.msg.v2|\(groupID)|\(sender)|\(index)|\(prev)".utf8)
            : Data("seal.msg.v3|\(groupID)|\(epoch)|\(sender)|\(index)|\(prev)".utf8)
    }

    /// Offline outbox (NFR-5): fully built wire records that failed to save.
    /// Chain state is committed BEFORE the save attempt, so a retry re-ships
    /// the exact same bytes — message keys and indices are never reused.
    /// Deterministic record names make retries idempotent (an "already
    /// exists" error counts as delivered).
    private struct PendingRecord: Codable {
        enum Kind: String, Codable { case message, envelope, media }
        let kind: Kind
        let groupID: String
        let epoch: UInt64
        let senderHash: String
        var recipientHash: String?
        var envelope: Data?
        var chainIndex: UInt64?
        var ciphertext: Data?
        var devicePub: Data?
        var signature: Data?
        var sentAt: Date?
        var recipients: [String]?
        var localMessageID: UUID?
        var mediaName: String?          // media: reserved record name
        var mediaBlob: Data?            // media: encrypted bytes
    }

    private var outbox: [PendingRecord] = []

    private(set) var chats: [Chat] = []
    private(set) var messagesByChat: [UUID: [ChatMessage]] = [:]
    private(set) var lastError: String?
    /// Root hashes this user has blocked (App Store Guideline 1.2). Their
    /// messages are hidden and skipped on receive; fully reversible. Local only.
    private(set) var blockedHashes: Set<String> = []

    // Presence. readMarks persists ("Read" survives relaunch); the rest is
    // transient throttling/expiry state rebuilt each session.
    private(set) var readMarks: [UUID: [String: Date]] = [:]   // chat → reader → latest seen sentAt
    private(set) var typingBy: [UUID: [String: Date]] = [:]    // chat → member → typing-until
    private var lastReadAck: [UUID: Date] = [:]                // throttle outbound read receipts
    private var lastTypingSent: [UUID: Date] = [:]             // throttle outbound typing pings

    private let identity: IdentityManager
    let sync: SyncEngine
    // chains["send.<chatID>"] = my sending chain
    // chains["recv.<chatID>.<senderHash>"] = a member's receiving chain
    private var chains: [String: ChainState] = [:]
    // directory cache: rootHash → (identity, verified endorsements)
    private var directoryCache: [String: (RootIdentity, [DeviceEndorsement])] = [:]
    // One self-heal republish per launch (see ensureSelfPublished).
    private var didEnsureSelfPublished = false
    // Chats with a refresh in flight — coalesces overlapping refreshes (poll
    // loop + push + foreground) so the same messages aren't double-processed.
    private var refreshingChats: Set<UUID> = []

    let ownerHash: String

    init(identity: IdentityManager, sync: SyncEngine, ownerHash: String) {
        self.identity = identity
        self.sync = sync
        self.ownerHash = ownerHash
        load()
        purgeExpired()
    }

    static func wipe(ownerHash: String) {
        KeychainStore.delete("seal.chats.\(ownerHash)")
        KeychainStore.delete("seal.messages.\(ownerHash)")
        KeychainStore.delete("seal.chains.\(ownerHash)")
        KeychainStore.delete("seal.outbox.\(ownerHash)")
        KeychainStore.delete("seal.readmarks.\(ownerHash)")
        KeychainStore.delete("seal.blocks.\(ownerHash)")
    }

    func setTTL(_ ttl: TimeInterval?, for chat: Chat) {
        guard let idx = chats.firstIndex(where: { $0.id == chat.id }) else { return }
        chats[idx].ttl = ttl
        persist()
    }

    // MARK: - Chats

    /// 1:1 chat IDs are derived from both members' hashes, so both sides
    /// independently arrive at the SAME chat — no invite needed for pairs.
    static func pairChatID(_ a: String, _ b: String) -> UUID {
        let digest = SHA256.hash(data: Data([a, b].sorted().joined(separator: "|").utf8))
        let b = Array(digest.prefix(16))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    func ensureChat(with friend: RootIdentity, myHash: String) -> Chat {
        let id = Self.pairChatID(myHash, friend.credentialIDHash)
        if let existing = chats.first(where: { $0.id == id }) { return existing }
        let chat = Chat(id: id, name: friend.displayName,
                        memberHashes: [myHash, friend.credentialIDHash], ttl: nil)
        chats.append(chat)
        persist()
        return chat
    }

    // MARK: - Groups (FR-9/FR-10)

    /// Signed invite: recipients verify the creator's signature chain AND
    /// that the creator is already their friend before accepting (FR-10).
    private struct GroupInvite: Codable {
        let chatData: Data              // JSON-encoded Chat, what's signed
        let senderHash: String
        let senderDevicePub: Data
        let signature: Data             // device-key signature over chatData
        let kind: String?               // nil = invite, "update" = membership change
    }

    /// Remove a member (creator only, FR-13). Bumps the epoch — every sender's
    /// next message starts a fresh chain wrapped only to remaining members,
    /// so the removed member cannot read anything after this point.
    func removeMember(_ memberHash: String, from chat: Chat, myRoot: RootIdentity) async {
        guard chat.creatorHash == myRoot.credentialIDHash,
              memberHash != myRoot.credentialIDHash,
              let idx = chats.firstIndex(where: { $0.id == chat.id }),
              let deviceKey = identity.deviceKey,
              let devicePub = identity.deviceKey?.publicKey.x963Representation else { return }

        let previousMembers = chats[idx].memberHashes
        var updated = chats[idx]
        updated.memberHashes.removeAll { $0 == memberHash }
        updated.epoch = updated.currentEpoch + 1
        chats[idx] = updated
        persist()

        do {
            let chatData = try JSONEncoder().encode(updated)
            let signature = try deviceKey.signature(for: chatData)
            let update = GroupInvite(chatData: chatData,
                                     senderHash: myRoot.credentialIDHash,
                                     senderDevicePub: devicePub,
                                     signature: signature.derRepresentation,
                                     kind: "update")
            let payload = try JSONEncoder().encode(update)
            // Everyone who was a member learns of the change — including the
            // removed member, whose client drops the chat.
            for member in previousMembers where member != myRoot.credentialIDHash {
                try? await sync.saveGroupInvite(recipientHash: member, payload: payload)
            }
        } catch {
            lastError = "Rotation notice failed: \(error.localizedDescription)"
        }
    }

    func createGroup(name: String, friendHashes: [String], myRoot: RootIdentity) async -> Chat? {
        guard let deviceKey = identity.deviceKey,
              let devicePub = identity.deviceKey?.publicKey.x963Representation else {
            lastError = "No device key — re-register."; return nil
        }
        let chat = Chat(id: UUID(), name: name,
                        memberHashes: [myRoot.credentialIDHash] + friendHashes, ttl: nil,
                        epoch: 0, creatorHash: myRoot.credentialIDHash)
        chats.append(chat)
        persist()
        do {
            let chatData = try JSONEncoder().encode(chat)
            let signature = try deviceKey.signature(for: chatData)
            let invite = GroupInvite(chatData: chatData,
                                     senderHash: myRoot.credentialIDHash,
                                     senderDevicePub: devicePub,
                                     signature: signature.derRepresentation,
                                     kind: nil)
            let payload = try JSONEncoder().encode(invite)
            for friend in friendHashes {
                try await sync.saveGroupInvite(recipientHash: friend, payload: payload)
            }
        } catch {
            lastError = "Invites failed: \(error.localizedDescription)"
        }
        return chat
    }

    /// Accept pending invites — only from verified friends (FR-10), only with
    /// a valid signature chain. Everything else is silently dropped.
    func checkInvites(myRoot: RootIdentity, friendStore: FriendStore) async {
        guard let payloads = try? await sync.fetchGroupInvites(
            recipientHash: myRoot.credentialIDHash) else { return }
        var changed = false
        for payload in payloads {
            guard let invite = try? JSONDecoder().decode(GroupInvite.self, from: payload),
                  let chat = try? JSONDecoder().decode(Chat.self, from: invite.chatData),
                  let (root, endorsements) = try? await directoryEntry(for: invite.senderHash),
                  identity.verify(signature: invite.signature, over: invite.chatData,
                                  deviceKey: invite.senderDevicePub,
                                  claimedRoot: root, endorsements: endorsements)
            else { continue }

            if let existingIdx = chats.firstIndex(where: { $0.id == chat.id }) {
                // Membership update: only the creator may issue it, and only
                // forward in epoch (no replaying old membership).
                guard invite.kind == "update",
                      invite.senderHash == (chats[existingIdx].creatorHash ?? ""),
                      chat.currentEpoch > chats[existingIdx].currentEpoch
                else { continue }
                if chat.memberHashes.contains(myRoot.credentialIDHash) {
                    chats[existingIdx] = chat
                } else {
                    // That's us removed — drop the chat and its messages.
                    messagesByChat[chat.id] = nil
                    chats.remove(at: existingIdx)
                }
                changed = true
            } else {
                guard invite.kind == nil,
                      chat.memberHashes.contains(myRoot.credentialIDHash),
                      friendStore.isFriend(invite.senderHash)
                else { continue }
                chats.append(chat)
                changed = true
            }
        }
        if changed { persist() }
    }

    /// Self-heal the SENDER side of a key desync: make sure THIS device's
    /// current endorsement (signing + KEM key) is actually present in the
    /// directory. A rebuild/reset (e.g. the PIN-fix build) can leave our
    /// published record pointing at old keys — then friends wrap to a KEM key
    /// we no longer hold AND we sign with a device key they can't verify, which
    /// is exactly the bidirectional failure we chased. One idempotent republish
    /// per launch closes that gap; publishIdentity merges by device key, so it's
    /// a no-op once we're current. Best-effort and silent if offline.
    private func ensureSelfPublished(myRoot: RootIdentity) async {
        guard !didEnsureSelfPublished, let endorsement = identity.deviceEndorsement else { return }
        didEnsureSelfPublished = true
        // Skip the CloudKit write only if our current device key is already in
        // the directory's VERIFIED set; republish when it's missing OR present
        // but stale/unverifiable.
        if let (root, endorsements) = try? await sync.fetchIdentity(credentialIDHash: myRoot.credentialIDHash),
           IdentityManager.verifiedDevices(root: root, endorsements: endorsements)
               .contains(where: { $0.devicePublicKey == endorsement.devicePublicKey }) {
            return
        }
        ChatEngine.msgLog.info("ensureSelfPublished: republishing this device's endorsement (device=\(ChatEngine.fp(endorsement.devicePublicKey), privacy: .public) kem=\(ChatEngine.fp(endorsement.kemBundlePublicKeys), privacy: .public)) — was missing/stale in directory")
        await sync.publishIdentity(myRoot, endorsement: endorsement)
    }

    /// Full sync pass: surface 1:1 chats for every friend, accept invites,
    /// pull new messages everywhere. Called on launch, foreground, and push.
    func refreshAll(myRoot: RootIdentity, friendStore: FriendStore) async {
        await ensureSelfPublished(myRoot: myRoot)
        await flushOutbox()
        for friend in friendStore.friends {
            _ = ensureChat(with: friend.identity, myHash: myRoot.credentialIDHash)
        }
        await checkInvites(myRoot: myRoot, friendStore: friendStore)
        for chat in chats {
            await refresh(chat, myRoot: myRoot)
        }
    }

    func ensureNoteToSelf(myHash: String) -> Chat {
        if let existing = chats.first(where: { $0.memberHashes == [myHash] }) { return existing }
        let chat = Chat(id: UUID(), name: "Note to self", memberHashes: [myHash], ttl: nil)
        chats.append(chat)
        persist()
        return chat
    }

    func messages(for chat: Chat) -> [ChatMessage] {
        (messagesByChat[chat.id] ?? [])
            .filter { !blockedHashes.contains($0.senderHash) }   // hide blocked users (1.2)
            .sorted { $0.sentAt < $1.sentAt }
    }

    // MARK: - Block & report (App Store Guideline 1.2)

    func isBlocked(_ hash: String) -> Bool { blockedHashes.contains(hash) }

    /// Hide a user's content and stop processing their messages. Reversible.
    func block(_ hash: String) {
        guard hash != ownerHash else { return }
        blockedHashes.insert(hash)
        persist()
    }

    func unblock(_ hash: String) {
        blockedHashes.remove(hash)
        persist()
    }

    // Report itself is a UI action (it composes an email to the developer in
    // ChatView) — the engine only owns the block side of report-and-block.

    // MARK: - Send

    func send(_ text: String, in chat: Chat, from myRoot: RootIdentity,
              replyingTo: ChatMessage? = nil) async {
        let ttl = chats.first(where: { $0.id == chat.id })?.ttl
        await sendPayload(MessagePayload(text: text, ttl: ttl,
                                         replyTo: replyingTo?.wireID,
                                         replyPreview: replyingTo.map(Self.replyPreview),
                                         replySenderHash: replyingTo?.senderHash),
                          in: chat, from: myRoot)
    }

    /// One-line quote shown above a reply bubble.
    static func replyPreview(_ m: ChatMessage) -> String {
        if m.mediaRef != nil { return "📷 Photo" }
        let t = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 80 ? String(t.prefix(80)) + "…" : t
    }

    /// NFR-7 disclosure, Snapchat-standard: best-effort, sent through the
    /// normal E2EE pipeline so every member sees it. Skipped for Note to self.
    func sendScreenshotNotice(in chat: Chat, from myRoot: RootIdentity) async {
        guard chat.memberHashes.count > 1 else { return }
        let ttl = chats.first(where: { $0.id == chat.id })?.ttl
        await sendPayload(MessagePayload(text: "", ttl: ttl, kind: "screenshot"),
                          in: chat, from: myRoot)
    }

    /// Emoji reaction (FR-11). Travels through the normal E2EE pipeline as a
    /// kind:"reaction" payload pointing at the target's stable `wireID`; on every
    /// device it mutates the target bubble instead of rendering its own. Tapping
    /// the same emoji again clears your reaction. One reaction per person.
    func react(_ emoji: String, to message: ChatMessage, in chat: Chat, from myRoot: RootIdentity) async {
        guard let target = message.wireID else { return }   // pre-wireID message: not reactable
        let myHash = myRoot.credentialIDHash
        let existing = messagesByChat[chat.id]?.first { $0.wireID == target }?.reactions?[myHash]
        let cleared = (existing == emoji)                   // toggle off if same emoji
        applyReaction(chatID: chat.id, reactorHash: myHash, reactTo: target,
                      emoji: cleared ? nil : emoji)         // optimistic local apply
        let ttl = chats.first(where: { $0.id == chat.id })?.ttl
        await sendPayload(MessagePayload(text: "", ttl: ttl, kind: "reaction",
                                         reactTo: target, emoji: cleared ? "" : emoji),
                          in: chat, from: myRoot)
    }

    /// Apply a reaction to its target bubble. Empty/nil emoji removes the
    /// reactor's entry. No-op if the target message isn't present yet (a
    /// reaction that arrives before its message is simply dropped).
    private func applyReaction(chatID: UUID, reactorHash: String, reactTo: String, emoji: String?) {
        guard var msgs = messagesByChat[chatID],
              let i = msgs.firstIndex(where: { $0.wireID == reactTo }) else { return }
        var set = msgs[i].reactions ?? [:]
        if let emoji, !emoji.isEmpty { set[reactorHash] = emoji } else { set[reactorHash] = nil }
        msgs[i].reactions = set.isEmpty ? nil : set
        messagesByChat[chatID] = msgs
        persist()
    }

    // MARK: - Presence (read receipts + typing)

    /// Tell the others I've seen everything up to the latest inbound message.
    /// Throttled so we only emit when the high-water mark actually advances.
    /// Carries a timestamp (comparable across senders) rather than a wireID.
    func markRead(in chat: Chat, from myRoot: RootIdentity) async {
        let myHash = myRoot.credentialIDHash
        let inbound = (messagesByChat[chat.id] ?? []).filter { $0.senderHash != myHash }
        guard let latest = inbound.map(\.sentAt).max() else { return }   // nothing to ack
        if let acked = lastReadAck[chat.id], acked >= latest { return }  // nothing new
        lastReadAck[chat.id] = latest
        await sendPayload(MessagePayload(text: "", ttl: nil, kind: "read", readUpTo: latest),
                          in: chat, from: myRoot)
    }

    /// Best-effort "is typing" ping (throttled to one per ~4s). NOTE: over the
    /// current 4s poll transport this is laggy by design — it's a nicety, not
    /// real-time. Never persisted.
    func sendTyping(in chat: Chat, from myRoot: RootIdentity) async {
        guard chat.memberHashes.count > 1 else { return }
        let now = Date()
        if let last = lastTypingSent[chat.id], now.timeIntervalSince(last) < 4 { return }
        lastTypingSent[chat.id] = now
        await sendPayload(MessagePayload(text: "", ttl: nil, kind: "typing"), in: chat, from: myRoot)
    }

    /// How many OTHER members have read up to a given message (by timestamp).
    func readerCount(of message: ChatMessage, in chat: Chat) -> Int {
        let marks = readMarks[chat.id] ?? [:]
        return chat.memberHashes
            .filter { $0 != message.senderHash }
            .filter { (marks[$0] ?? .distantPast) >= message.sentAt }
            .count
    }

    /// Members currently typing (un-expired), excluding me.
    func typingMembers(in chat: Chat, myRoot: RootIdentity) -> [String] {
        let now = Date()
        return (typingBy[chat.id] ?? [:])
            .filter { $0.key != myRoot.credentialIDHash && $0.value > now }
            .map(\.key)
    }

    private func applyRead(chatID: UUID, readerHash: String, upTo: Date?) {
        guard let upTo else { return }
        var marks = readMarks[chatID] ?? [:]
        if let existing = marks[readerHash], existing >= upTo { return }
        marks[readerHash] = upTo
        readMarks[chatID] = marks
        persist()
    }

    private func markTyping(chatID: UUID, memberHash: String) {
        var t = typingBy[chatID] ?? [:]
        t[memberHash] = Date().addingTimeInterval(6)   // shown until this passes
        typingBy[chatID] = t                            // transient, not persisted
    }

    /// Kinds that ship over the wire but never render their own bubble — they
    /// mutate other state (a reaction, a read mark, a typing flag) instead.
    /// "screenshot" is NOT here: it renders a visible notice.
    private static func isNonBubble(_ kind: String?) -> Bool {
        kind == "reaction" || kind == "read" || kind == "typing"
    }

    /// Encrypt a photo with a fresh content key, park the blob in CloudKit,
    /// and send a message carrying the key inside the E2EE payload.
    func sendPhoto(_ jpeg: Data, in chat: Chat, from myRoot: RootIdentity) async {
        // Demo mode: park the photo in the in-memory cache, skip CloudKit.
        if DemoFixtures.isActive {
            let ref = "demo.media.\(UUID().uuidString)"
            imageCache[ref] = jpeg
            let ttl = chats.first(where: { $0.id == chat.id })?.ttl
            await sendPayload(MessagePayload(text: "", ttl: ttl, mediaRef: ref,
                                             mediaKey: Data(count: 32)), in: chat, from: myRoot)
            return
        }
        do {
            let contentKey = SymmetricKey(size: .bits256)
            let sealed = try AES.GCM.seal(jpeg, using: contentKey).combined!
            // Reserve the record name up front so an offline upload can be
            // queued and retried under the same name the message references.
            let mediaRef = "media.\(UUID().uuidString)"
            imageCache[mediaRef] = jpeg     // sender sees their photo instantly
            do {
                try await sync.saveMediaAsset(sealed, name: mediaRef)
            } catch {
                outbox.append(PendingRecord(
                    kind: .media, groupID: chat.id.uuidString, epoch: 0,
                    senderHash: myRoot.credentialIDHash,
                    mediaName: mediaRef, mediaBlob: sealed))
            }
            let ttl = chats.first(where: { $0.id == chat.id })?.ttl
            await sendPayload(MessagePayload(
                text: "", ttl: ttl, mediaRef: mediaRef,
                mediaKey: contentKey.withUnsafeBytes { Data($0) }
            ), in: chat, from: myRoot)
        } catch {
            lastError = "Photo failed: \(error.localizedDescription)"
        }
    }

    private func sendPayload(_ payloadValue: MessagePayload, in chat: Chat, from myRoot: RootIdentity) async {
        lastError = nil
        // FR-23: demo identities cannot message real users — demo sends are
        // appended locally and never leave the device.
        if DemoFixtures.isActive {
            if Self.isNonBubble(payloadValue.kind) { return }   // presence/reactions: no local bubble
            let localID = UUID()
            var local = messagesByChat[chat.id] ?? []
            local.append(ChatMessage(id: localID, senderHash: myRoot.credentialIDHash,
                                     text: payloadValue.text, sentAt: .now, delivered: true,
                                     expiresAt: payloadValue.ttl.map { Date.now.addingTimeInterval($0) },
                                     mediaRef: payloadValue.mediaRef,
                                     mediaKey: payloadValue.mediaKey,
                                     kind: payloadValue.kind,
                                     wireID: "demo.\(localID)",
                                     replyTo: payloadValue.replyTo,
                                     replyPreview: payloadValue.replyPreview,
                                     replySenderHash: payloadValue.replySenderHash))
            messagesByChat[chat.id] = local
            persist()
            return
        }
        guard let deviceKey = identity.deviceKey,
              let devicePub = identity.deviceKey?.publicKey.x963Representation else {
            lastError = "No device key — re-register."; return
        }
        let myHash = myRoot.credentialIDHash
        let groupID = chat.id.uuidString
        // Always send in the chat's CURRENT epoch (post-removal, that's a
        // fresh chain the removed member never gets an envelope for).
        let liveChat = chats.first(where: { $0.id == chat.id }) ?? chat
        let epoch = liveChat.currentEpoch
        do {
            // 0. Older queued records ship first — keeps per-sender chain order.
            await flushOutbox()

            // 1. Sending chain for this epoch: create + distribute on first use.
            var chain = chains["send.\(chat.id).e\(epoch)"]
            if chain == nil {
                let fresh = ChainState(chainKey: Self.randomBytes(32), index: 0)
                for member in liveChat.memberHashes where member != myHash {
                    // Wrap to EVERY one of the member's endorsed device KEM
                    // keys, not just `.last`. If our directory view of "their
                    // latest device" is stale, the recipient can still open the
                    // copy wrapped to the key it actually holds — self-healing
                    // against the cross-device "Sync failed / CryptoKit error 3"
                    // desync. NOTE: first message of an epoch needs the
                    // directory (recipient KEM keys) — fully-offline sends only
                    // work once a chain exists or the directory entry is cached.
                    guard let (_, endorsements) = try await directoryEntry(for: member) else {
                        lastError = "A member's identity has no message keys — they need to re-register."
                        return
                    }
                    let recipientKEMs = endorsements.map(\.kemBundlePublicKeys).filter { !$0.isEmpty }
                    guard !recipientKEMs.isEmpty else {
                        lastError = "A member's identity has no message keys — they need to re-register."
                        return
                    }
                    let envelope = try HybridKEM.wrapToAll(fresh.chainKey, to: recipientKEMs)
                    ChatEngine.msgLog.info("send: wrapped epoch \(epoch, privacy: .public) key to \(recipientKEMs.count, privacy: .public) device key(s) [\(recipientKEMs.map { ChatEngine.fp($0) }.joined(separator: ","), privacy: .public)]")
                    do {
                        try await sync.saveKeyEnvelope(
                            groupID: groupID, epoch: epoch, senderHash: myHash,
                            recipientHash: member, envelope: envelope)
                    } catch {
                        outbox.append(PendingRecord(
                            kind: .envelope, groupID: groupID, epoch: epoch,
                            senderHash: myHash, recipientHash: member, envelope: envelope))
                    }
                }
                chain = fresh
            }
            var state = chain!

            // 2. Ratchet: derive this message's key, advance the chain.
            let (messageKey, index) = Self.ratchet(&state)

            // 3. Encrypt. AAD binds group, epoch, sender, index, prev-hash.
            let payload = try JSONEncoder().encode(payloadValue)
            let aad = Self.messageAAD(groupID: groupID, epoch: epoch, sender: myHash,
                                      index: index, prevHash: state.lastMessageHash)
            let sealed = try AES.GCM.seal(payload, using: messageKey, authenticating: aad)
            let ciphertext = sealed.combined!

            // 4. Sign ciphertext‖aad with the Secure Enclave device key.
            let signature = try deviceKey.signature(for: ciphertext + aad)

            // 5. Ship it — or queue it. Chain state commits either way (the
            //    ciphertext exists; a retry must never reuse key or index).
            let localID = UUID()
            // `recipients` exists ONLY to drive the CKQuerySubscription that
            // fires a push. Inbound messages are fetched by deterministic
            // record name, never by query, so leaving it empty costs delivery
            // nothing. Presence and reactions therefore ship with NO recipients:
            // otherwise every typing ping (1 per 4s) and every read receipt
            // pushes a "New sealed message" banner at the other person, which
            // buries the real messages and trains people to mute the app.
            let recipients = Self.isNonBubble(payloadValue.kind)
                ? []
                : liveChat.memberHashes.filter { $0 != myHash }
            var deliveredNow = true
            do {
                try await sync.saveMessage(
                    groupID: groupID, epoch: epoch, senderHash: myHash, chainIndex: index,
                    message: .init(ciphertext: ciphertext,
                                   senderDevicePublicKey: devicePub,
                                   signature: signature.derRepresentation,
                                   sentAt: .now),
                    recipients: recipients)
            } catch let ckError as CKError where ckError.code == .serverRecordChanged {
                // A FIRST attempt at this slot collided. That is NOT a delivery:
                // this device has never written here, so the occupant is a stale
                // record from a previous local state (sign-out wipes
                // seal.chains.<hash>, resetting the index to 0, while the server
                // keeps the old records). CloudKit created nothing, so the
                // creation-triggered push never fires and the recipient — who is
                // walking the same deterministic names — is stuck on ciphertext
                // our current chain key can no longer open.
                //
                // Silently calling this "delivered" is what made the failure
                // invisible: the sender sees a sent bubble and the recipient
                // gets nothing at all. Surface it instead. (flushOutbox still
                // treats a collision as delivered — there the record genuinely
                // was written by an earlier attempt of OURS.)
                deliveredNow = false
                lastError = "This chat is out of sync with the server — messages aren't reaching anyone. "
                          + "Old messages from a previous sign-in are occupying this chat's slots."
                ChatEngine.msgLog.error("send: slot \(index, privacy: .public) occupied on FIRST attempt — stale server chain, message NOT delivered and no push fired (group=\(groupID, privacy: .public) epoch=\(epoch, privacy: .public))")
            } catch {
                deliveredNow = false
                outbox.append(PendingRecord(
                    kind: .message, groupID: groupID, epoch: epoch, senderHash: myHash,
                    chainIndex: index, ciphertext: ciphertext, devicePub: devicePub,
                    signature: signature.derRepresentation, sentAt: .now,
                    recipients: recipients, localMessageID: localID))
                // Only call it "Offline" when it actually is — otherwise surface
                // the real CloudKit reason instead of hiding it behind a queue.
                let isNetwork = (error as? CKError).map {
                    $0.code == .networkUnavailable || $0.code == .networkFailure
                } ?? false
                lastError = isNetwork
                    ? "Offline — message queued, sends when you're connected."
                    : "Couldn't send (\(error.localizedDescription)) — queued, will retry when possible."
                ChatEngine.msgLog.error("send: saveMessage failed, queued (sender=\(myHash, privacy: .public) idx=\(index, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            }

            // Advance the transcript chain.
            state.lastMessageHash = Data(SHA256.hash(data: ciphertext))
            chains["send.\(chat.id).e\(epoch)"] = state
            // Reactions/read/typing ship over the wire but never render a
            // bubble (reactions were already applied to their target locally).
            if Self.isNonBubble(payloadValue.kind) {
                persist()
            } else {
                var local = messagesByChat[chat.id] ?? []
                local.append(ChatMessage(id: localID, senderHash: myHash, text: payloadValue.text,
                                         sentAt: .now, delivered: deliveredNow,
                                         expiresAt: payloadValue.ttl.map { Date.now.addingTimeInterval($0) },
                                         mediaRef: payloadValue.mediaRef,
                                         mediaKey: payloadValue.mediaKey,
                                         kind: payloadValue.kind,
                                         wireID: "\(myHash).e\(epoch).\(index)",
                                         replyTo: payloadValue.replyTo,
                                         replyPreview: payloadValue.replyPreview,
                                         replySenderHash: payloadValue.replySenderHash))
                messagesByChat[chat.id] = local
                persist()
            }
        } catch {
            lastError = "Send failed: \(error.localizedDescription)"
        }
    }

    /// Retry everything queued. Called before each send, and from refreshAll
    /// (launch / foreground / push). "Record already exists" = an earlier
    /// attempt half-landed = delivered.
    func flushOutbox() async {
        guard !outbox.isEmpty, !DemoFixtures.isActive else { return }
        var remaining: [PendingRecord] = []
        var deliveredIDs: Set<UUID> = []
        for record in outbox {
            do {
                switch record.kind {
                case .envelope:
                    try await sync.saveKeyEnvelope(
                        groupID: record.groupID, epoch: record.epoch,
                        senderHash: record.senderHash,
                        recipientHash: record.recipientHash ?? "",
                        envelope: record.envelope ?? Data())
                case .message:
                    try await sync.saveMessage(
                        groupID: record.groupID, epoch: record.epoch,
                        senderHash: record.senderHash, chainIndex: record.chainIndex ?? 0,
                        message: .init(ciphertext: record.ciphertext ?? Data(),
                                       senderDevicePublicKey: record.devicePub ?? Data(),
                                       signature: record.signature ?? Data(),
                                       sentAt: record.sentAt ?? .now),
                        recipients: record.recipients ?? [])
                    if let id = record.localMessageID { deliveredIDs.insert(id) }
                case .media:
                    try await sync.saveMediaAsset(record.mediaBlob ?? Data(),
                                                  name: record.mediaName ?? "")
                }
            } catch let error as CKError where error.code == .serverRecordChanged {
                if let id = record.localMessageID { deliveredIDs.insert(id) }
            } catch {
                remaining.append(record)
            }
        }
        guard outbox.count != remaining.count else { return }
        outbox = remaining
        if !deliveredIDs.isEmpty {
            for (chatID, msgs) in messagesByChat {
                messagesByChat[chatID] = msgs.map { message in
                    var message = message
                    if deliveredIDs.contains(message.id) { message.delivered = true }
                    return message
                }
            }
        }
        persist()
    }

    // MARK: - Receive

    /// Pull new messages from every other member, in chain order.
    func refresh(_ chat: Chat, myRoot: RootIdentity) async {
        if DemoFixtures.isActive { purgeExpired(); return }   // fully local (FR-22)
        // Coalesce overlapping refreshes of the SAME chat. The poll loop, push,
        // and foreground all call refresh; without this, concurrent runs read
        // the same chain index, fetch the same message, and each append it —
        // the "one message shows up five times" bug. defer guarantees release.
        guard !refreshingChats.contains(chat.id) else { return }
        refreshingChats.insert(chat.id)
        defer { refreshingChats.remove(chat.id) }
        var failed = false
        let myHash = myRoot.credentialIDHash
        let groupID = chat.id.uuidString
        let liveChat = chats.first(where: { $0.id == chat.id }) ?? chat
        let epoch = liveChat.currentEpoch
        for sender in liveChat.memberHashes where sender != myHash && !blockedHashes.contains(sender) {
            do {
                // Receiving chain for this epoch: unwrap their envelope once.
                var state = chains["recv.\(chat.id).\(sender).e\(epoch)"]
                if state == nil {
                    guard let kemKey = identity.kemPrivateKey,
                          let envelope = try await sync.fetchKeyEnvelope(
                            groupID: groupID, epoch: epoch, senderHash: sender, recipientHash: myHash)
                    else { continue }   // they haven't sent in this epoch yet
                    let chainKey: Data
                    do {
                        chainKey = try HybridKEM.unwrap(envelope, with: kemKey)
                    } catch {
                        // None of the wrapped copies opened with our key: the
                        // sender wrapped to a KEM key this device no longer
                        // holds (stale view of our endorsements, or our keys
                        // were re-minted). Skip this sender with a clear notice
                        // instead of a raw CryptoKit error — refreshAll's
                        // self-republish pushes our current key so their next
                        // send wraps to it.
                        let myKEMfp = ChatEngine.fp(identity.kemPublicKeyData ?? Data())
                        ChatEngine.msgLog.error("recv: KEM unwrap failed (sender=\(sender, privacy: .public)) — no copy matched myKEM=\(myKEMfp, privacy: .public)")
                        lastError = "Couldn't unlock messages from a member yet — their app has older keys for you. It clears once you're both updated; re-friending fixes it for sure."
                        continue
                    }
                    state = ChainState(chainKey: chainKey, index: 0)
                }
                var chain = state!

                // Fetch next expected index until there are no more.
                while let wire = try await sync.fetchMessage(
                    groupID: groupID, epoch: epoch, senderHash: sender, chainIndex: chain.index) {

                    // Our own tracked prev-hash goes into the expected AAD —
                    // if the server swapped any earlier message, this (and the
                    // signature) stop matching and the transcript visibly breaks.
                    let aad = Self.messageAAD(groupID: groupID, epoch: epoch, sender: sender,
                                              index: chain.index, prevHash: chain.lastMessageHash)

                    // Full verification chain before decryption is even
                    // attempted. If it misses, our CACHED directory view of the
                    // sender may be stale (they re-endorsed a new device since
                    // we cached) — refetch once and retry before dropping.
                    var entry = try await directoryEntry(for: sender)
                    if !verifyInbound(wire, aad: aad, entry: entry) {
                        entry = try await directoryEntry(for: sender, forceRefresh: true)
                    }
                    guard verifyInbound(wire, aad: aad, entry: entry) else {
                        ChatEngine.msgLog.error("recv: drop — signed by device \(ChatEngine.fp(wire.senderDevicePublicKey), privacy: .public) not among sender's endorsed devices [\((entry?.1 ?? []).map { ChatEngine.fp($0.devicePublicKey) }.joined(separator: ","), privacy: .public)]")
                        lastError = "Couldn't verify a message from a member — their signing key isn't in the directory yet. Ask them to reopen the app (to republish) or re-friend."
                        Self.advance(&chain)    // skip the bad slot, don't stall the chain
                        continue
                    }

                    let (messageKey, idx) = Self.ratchet(&chain)
                    // Decrypt failures must NOT escape this loop. They used to
                    // throw to the per-sender catch below, which abandoned the
                    // sender for this refresh — and since the chain index never
                    // advanced past the offending slot, every later refresh hit
                    // the same slot and failed again. One stale record silently
                    // froze that person's whole conversation, permanently.
                    // Skip the slot instead (same policy the verify-miss path
                    // above already uses) so a later, good message still lands.
                    guard let sealedBox = try? AES.GCM.SealedBox(combined: wire.ciphertext),
                          let plaintext = try? AES.GCM.open(sealedBox, using: messageKey,
                                                            authenticating: aad)
                    else {
                        ChatEngine.msgLog.error("recv: slot \(idx, privacy: .public) from \(sender, privacy: .public) failed to decrypt — skipping it rather than stalling the chain")
                        lastError = "Skipped an unreadable message from a member — it was sent with keys that no longer match. Newer messages still arrive."
                        continue
                    }

                    let payload = (try? JSONDecoder().decode(MessagePayload.self, from: plaintext))
                        ?? MessagePayload(text: String(decoding: plaintext, as: UTF8.self), ttl: nil)
                    switch payload.kind ?? "" {
                    case "reaction":
                        // Mutates an existing bubble; never appended as its own.
                        applyReaction(chatID: chat.id, reactorHash: sender,
                                      reactTo: payload.reactTo ?? "", emoji: payload.emoji)
                    case "read":
                        applyRead(chatID: chat.id, readerHash: sender, upTo: payload.readUpTo)
                    case "typing":
                        markTyping(chatID: chat.id, memberHash: sender)
                    default:
                        // Idempotent display: a message can be processed more
                        // than once (overlapping refreshes, a re-fetch after a
                        // racy chain save). wireID is stable per message, so if
                        // it's already on screen, don't append a duplicate.
                        let wireID = "\(sender).e\(epoch).\(idx)"
                        if messagesByChat[chat.id]?.contains(where: { $0.wireID == wireID }) == true {
                            break
                        }
                        // A real message from them ends any "typing" state.
                        typingBy[chat.id]?[sender] = nil
                        var local = messagesByChat[chat.id] ?? []
                        local.append(ChatMessage(
                            id: UUID(), senderHash: sender,
                            text: payload.text,
                            sentAt: wire.sentAt, delivered: true,
                            expiresAt: payload.ttl.map { wire.sentAt.addingTimeInterval($0) },
                            mediaRef: payload.mediaRef,
                            mediaKey: payload.mediaKey,
                            kind: payload.kind,
                            wireID: wireID,
                            replyTo: payload.replyTo,
                            replyPreview: payload.replyPreview,
                            replySenderHash: payload.replySenderHash))
                        messagesByChat[chat.id] = local
                    }
                    chain.lastMessageHash = Data(SHA256.hash(data: wire.ciphertext))
                }
                chains["recv.\(chat.id).\(sender).e\(epoch)"] = chain
                persist()
            } catch let error as CKError
                where error.code == .networkUnavailable || error.code == .networkFailure {
                // Polling while offline isn't an error worth shouting about.
                lastError = "Offline — will sync when connected."
                failed = true
            } catch {
                lastError = "Sync failed: \(error.localizedDescription)"
                failed = true
            }
        }
        // Back online and the pass fully succeeded: clear the stale offline notice.
        if !failed, lastError == "Offline — will sync when connected." { lastError = nil }
        purgeExpired()
    }

    /// Client-enforced expiry (NFR-7: best-effort by design, disclosed in UI).
    func purgeExpired() {
        let now = Date.now
        var changed = false
        for (chatID, messages) in messagesByChat {
            let kept = messages.filter { ($0.expiresAt ?? .distantFuture) > now }
            if kept.count != messages.count {
                messagesByChat[chatID] = kept
                changed = true
            }
        }
        if changed { persist() }
    }

    // MARK: - Media decryption (in-memory cache)

    private var imageCache: [String: Data] = [:]

    /// Fetch + decrypt a message's photo. Returns decrypted JPEG data.
    func mediaData(for message: ChatMessage) async -> Data? {
        guard let ref = message.mediaRef, let keyData = message.mediaKey else { return nil }
        if let cached = imageCache[ref] { return cached }
        guard let encrypted = try? await sync.fetchMediaAsset(ref),
              let box = try? AES.GCM.SealedBox(combined: encrypted),
              let plain = try? AES.GCM.open(box, using: SymmetricKey(data: keyData))
        else { return nil }
        imageCache[ref] = plain
        return plain
    }

    // MARK: - Helpers

    private func directoryEntry(for hash: String, forceRefresh: Bool = false) async throws -> (RootIdentity, [DeviceEndorsement])? {
        if !forceRefresh, let cached = directoryCache[hash] { return cached }
        guard let (root, endorsements) = try await sync.fetchIdentity(credentialIDHash: hash) else { return nil }
        let verified = IdentityManager.verifiedDevices(root: root, endorsements: endorsements)
        directoryCache[hash] = (root, verified)
        return (root, verified)
    }

    /// Verify one inbound wire message against a (root, verified-endorsements)
    /// directory entry. Pulled out so the receive loop can retry it after a
    /// forced directory refetch without duplicating the call.
    private func verifyInbound(_ wire: SyncEngine.WireMessage, aad: Data,
                               entry: (RootIdentity, [DeviceEndorsement])?) -> Bool {
        guard let (root, endorsements) = entry else { return false }
        return identity.verify(signature: wire.signature, over: wire.ciphertext + aad,
                               deviceKey: wire.senderDevicePublicKey,
                               claimedRoot: root, endorsements: endorsements)
    }

    /// chainKey → (messageKey, index); chain advances, old key destroyed.
    private static func ratchet(_ state: inout ChainState) -> (SymmetricKey, UInt64) {
        let input = SymmetricKey(data: state.chainKey)
        let messageKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: input, info: Data("seal.message".utf8), outputByteCount: 32)
        let nextChain = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: input, info: Data("seal.chain".utf8), outputByteCount: 32)
        let index = state.index
        state.chainKey = nextChain.withUnsafeBytes { Data($0) }
        state.index += 1
        return (messageKey, index)
    }

    private static func advance(_ state: inout ChainState) {
        var s = state
        _ = ratchet(&s)
        state = s
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    // MARK: - Persistence (keychain JSON for now; TODO: encrypted SwiftData)

    private func persist() {
        if let data = try? JSONEncoder().encode(chats) { KeychainStore.save(data, for: "seal.chats.\(ownerHash)") }
        if let data = try? JSONEncoder().encode(messagesByChat) { KeychainStore.save(data, for: "seal.messages.\(ownerHash)") }
        if let data = try? JSONEncoder().encode(chains) { KeychainStore.save(data, for: "seal.chains.\(ownerHash)") }
        if let data = try? JSONEncoder().encode(outbox) { KeychainStore.save(data, for: "seal.outbox.\(ownerHash)") }
        if let data = try? JSONEncoder().encode(readMarks) { KeychainStore.save(data, for: "seal.readmarks.\(ownerHash)") }
        if let data = try? JSONEncoder().encode(blockedHashes) { KeychainStore.save(data, for: "seal.blocks.\(ownerHash)") }
    }

    private func load() {
        if let data = KeychainStore.load("seal.chats.\(ownerHash)"),
           let decoded = try? JSONDecoder().decode([Chat].self, from: data) { chats = decoded }
        if let data = KeychainStore.load("seal.messages.\(ownerHash)"),
           let decoded = try? JSONDecoder().decode([UUID: [ChatMessage]].self, from: data) { messagesByChat = decoded }
        if let data = KeychainStore.load("seal.chains.\(ownerHash)"),
           let decoded = try? JSONDecoder().decode([String: ChainState].self, from: data) { chains = decoded }
        if let data = KeychainStore.load("seal.outbox.\(ownerHash)"),
           let decoded = try? JSONDecoder().decode([PendingRecord].self, from: data) { outbox = decoded }
        if let data = KeychainStore.load("seal.readmarks.\(ownerHash)"),
           let decoded = try? JSONDecoder().decode([UUID: [String: Date]].self, from: data) { readMarks = decoded }
        if let data = KeychainStore.load("seal.blocks.\(ownerHash)"),
           let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) { blockedHashes = decoded }
    }
}
