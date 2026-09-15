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
        var card: SealedCard?           // kind == "card": the sealed payload
        /// Re-checkable signature tuple. Populated for CARDS ONLY — a bubble is
        /// verified on arrival and never looked at again, but a card can be
        /// acted on days later (SealedCard.swift, MessageProof).
        var proof: MessageProof?
        /// kind == "introduce": the offer plus the verdict of the checks the
        /// engine ran on arrival, so the card is a pure function of stored
        /// state and `body` never does async work. Nil on every other message.
        var introduction: IntroductionOffer?
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
        var card: SealedCard?           // "card": high-stakes payload (SealedCard.swift)
        // Introductions (Seal/Introductions/Introduction.swift). Three kinds,
        // one flow: the introducer's signed vouch, each party's signed
        // acceptance travelling back, and the confirmation carrying both
        // acceptances out again. No new record type — same reasoning as cards.
        var introduce: IntroductionStatement?
        var introduceAccept: IntroductionAcceptance?
        var introduceConfirm: IntroductionConfirmation?
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
    // Guards against concurrent refreshAll passes each starting a publish.
    private var publishInFlight = false
    // Chats with a refresh in flight — coalesces overlapping refreshes (poll
    // loop + push + foreground) so the same messages aren't double-processed.
    private var refreshingChats: Set<UUID> = []

    let ownerHash: String

    /// Introductions in flight, in any role (docs/INTRODUCTIONS.md). Owned
    /// here rather than beside the FriendStore because the receive path is
    /// where the three payload kinds land, and because messages are consumed
    /// once — the ratchet destroys the key — so "what does this flow still
    /// owe?" has to be answered from local state, not from the transcript.
    let introductions: IntroductionStore

    /// Acceptances re-sent this session (see `resendAcceptanceOnce`). In
    /// memory on purpose: the point is one nudge per launch, not a permanent
    /// retry queue.
    private var resentAcceptances: Set<String> = []

    /// Last time each introduction was pushed forward. `refreshAll` runs on
    /// launch, foreground and push, and ChatView's poll calls the same thing
    /// every FOUR SECONDS while a chat is open — so every retryable failure
    /// below (directory unreachable, a recipient with no published keys) would
    /// otherwise become two forced identity fetches, or an outbound message,
    /// every four seconds for the life of the install. One attempt per minute
    /// per introduction. In memory: a fresh launch is allowed to try again
    /// immediately, which is what a user who just reopened the app expects.
    private var introductionAttempts: [String: Date] = [:]

    init(identity: IdentityManager, sync: SyncEngine, ownerHash: String) {
        self.identity = identity
        self.sync = sync
        self.ownerHash = ownerHash
        self.introductions = IntroductionStore(ownerHash: ownerHash)
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
        IntroductionStore.wipe(ownerHash: ownerHash)
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
        // publishInFlight is set with NO await between the guard and the
        // assignment, so overlapping refreshAll passes (launch + foreground +
        // push all call it, and refreshAll has no coalescing of its own) can't
        // each start a publish. Without this, three tasks race to read-merge-
        // write the SAME Identity record, burn each other's retries on
        // .serverRecordChanged, and can exhaust all 3 attempts — manufacturing
        // exactly the unpublished-endorsement failure this function exists to
        // prevent.
        guard !didEnsureSelfPublished, !publishInFlight,
              let endorsement = identity.deviceEndorsement else { return }
        publishInFlight = true
        defer { publishInFlight = false }
        // Skip the CloudKit write only if our current device key is already in
        // the directory's VERIFIED set; republish when it's missing OR present
        // but stale/unverifiable.
        if let (root, endorsements) = try? await sync.fetchIdentity(credentialIDHash: myRoot.credentialIDHash),
           IdentityManager.verifiedDevices(root: root, endorsements: endorsements)
               .contains(where: { $0.devicePublicKey == endorsement.devicePublicKey }) {
            didEnsureSelfPublished = true
            return
        }
        ChatEngine.msgLog.info("ensureSelfPublished: republishing this device's endorsement (device=\(ChatEngine.fp(endorsement.devicePublicKey), privacy: .public) kem=\(ChatEngine.fp(endorsement.kemBundlePublicKeys), privacy: .public)) — was missing/stale in directory")
        // Latch only when there's no point trying again. This used to set the
        // flag BEFORE publishing, so a publish that failed (offline, or a lost
        // race on the shared Identity record) was never retried for the rest of
        // the app session — leaving this device unverifiable to every peer
        // while it happily kept sending messages nobody could accept.
        //
        // `refused` latches too: a tombstoned identity can never publish, and
        // refreshAll runs on launch, foreground AND every silent push, so
        // retrying a permanent refusal would hammer CloudKit forever for a
        // result that cannot change.
        //
        // Assign forward-only (never write `false` over a `true`) so a losing
        // task can't clear a latch a concurrent winner just set.
        switch await sync.publishIdentity(myRoot, endorsement: endorsement) {
        case .published, .refused:
            didEnsureSelfPublished = true
        case .failed:
            ChatEngine.msgLog.error("ensureSelfPublished: publish FAILED — this device's messages can't be verified by anyone until it lands; will retry next refresh")
        }
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
        // After the inbound pass, not before: acceptances and confirmations
        // arrive as messages, so this is the step that turns what just landed
        // into the next thing this device owes (docs/INTRODUCTIONS.md).
        await ensureIntroductionsProgressed(myRoot: myRoot, friendStore: friendStore)
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

    /// One-line summary of a message, for the chat list and reply quotes.
    ///
    /// A card summarises to its TITLE, never to `text`: `text` deliberately
    /// carries the old-build fallback string ("…update Seal to view"), which is
    /// exactly right on a build that can't render the card and nonsense on one
    /// that can. The card's `value` is never summarised — a truncated address
    /// in a list row is an invitation to misread it.
    static func summary(_ m: ChatMessage) -> String {
        if m.introduction != nil { return "🔗 Introduction" }
        if let card = m.card { return "🔏 \(card.title)" }
        if m.mediaRef != nil { return "📷 Photo" }
        return m.text
    }

    /// One-line quote shown above a reply bubble.
    static func replyPreview(_ m: ChatMessage) -> String {
        let t = summary(m).trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Sealed card (docs/CARDS.md): a high-stakes payload — an address, wire
    /// instructions, a statement — through the SAME pipeline as everything
    /// else, as `kind:"card"`. No new record type, no new signature scheme: the
    /// message signature is the card's authenticity, and the AAD already binds
    /// it to group|epoch|sender|index|prev-hash.
    ///
    /// `fallbackText` goes in `text` as well as in the card. A build with no
    /// card support decodes this payload fine (unknown keys are ignored), hits
    /// the receive switch's `default:` branch, and renders `payload.text` —
    /// which is the ONLY field it reads. Put the fallback only inside `card`
    /// and an older client shows an empty bubble instead of an explanation.
    /// Setting `text` also gives the chat-list preview and reply quotes
    /// something sensible for free.
    ///
    /// A card is a bubble kind (`isNonBubble` stays false), so it gets
    /// `recipients` and fires a push like any real message.
    func sendCard(_ card: SealedCard, in chat: Chat, from myRoot: RootIdentity) async {
        // Cards inherit the chat's TTL like every other message. They are NOT
        // exempted: the verification drawer promises disappearing messages
        // disappear, and silently carving out a message class would break that
        // promise quietly. CardComposeSheet warns before sending instead.
        let ttl = chats.first(where: { $0.id == chat.id })?.ttl
        await sendPayload(MessagePayload(text: card.fallbackText, ttl: ttl,
                                         kind: "card", card: card),
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
            || kind == Introduction.acceptKind || kind == Introduction.confirmKind
    }

    /// Kinds that should carry `recipients`, which is the ONLY thing that
    /// fires a push (the CKQuerySubscription watches that field).
    ///
    /// Normally that is exactly the bubble kinds — presence pings and
    /// reactions deliberately ship with no recipients so a typing indicator
    /// never buries a real message. An introduction CONFIRMATION is the one
    /// exception: it renders no bubble, but it is not chatter — it is the
    /// moment a friendship comes into existence on the other phone, and it
    /// arrives at most twice per introduction. Leaving it silent would mean a
    /// new family member appears only when the app is next opened for some
    /// other reason.
    private static func firesPush(_ kind: String?) -> Bool {
        !isNonBubble(kind) || kind == Introduction.confirmKind
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

    /// Returns true when the wire record was written OR queued in the outbox
    /// (i.e. it will land), false when the send failed outright with nothing
    /// left to retry.
    ///
    /// The result exists for the introduction flow, which has to know whether
    /// it still owes somebody a message: an introducer that marked its
    /// confirmations "sent" after a send that never happened would leave two
    /// people permanently waiting, each believing the other hadn't answered.
    /// Every other caller ignores it, as they always have.
    @discardableResult
    private func sendPayload(_ payloadValue: MessagePayload, in chat: Chat, from myRoot: RootIdentity) async -> Bool {
        lastError = nil
        // FR-23: demo identities cannot message real users — demo sends are
        // appended locally and never leave the device.
        if DemoFixtures.isActive {
            if Self.isNonBubble(payloadValue.kind) { return true }   // presence/reactions: no local bubble
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
                                     replySenderHash: payloadValue.replySenderHash,
                                     card: payloadValue.card,
                                     introduction: payloadValue.introduce.map {
                                         IntroductionOffer.verified($0, counterpart: nil)
                                     }))
            messagesByChat[chat.id] = local
            persist()
            return true
        }
        guard let deviceKey = identity.deviceKey,
              let devicePub = identity.deviceKey?.publicKey.x963Representation else {
            lastError = "No device key — re-register."; return false
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
                        return false
                    }
                    let recipientKEMs = endorsements.map(\.kemBundlePublicKeys).filter { !$0.isEmpty }
                    guard !recipientKEMs.isEmpty else {
                        lastError = "A member's identity has no message keys — they need to re-register."
                        return false
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
            //    prevHash is read out ONCE here: `state.lastMessageHash` is
            //    advanced further down, and a card's proof has to record the
            //    same value that actually went into this message's AAD.
            let prevHash = state.lastMessageHash
            let payload = try JSONEncoder().encode(payloadValue)
            let aad = Self.messageAAD(groupID: groupID, epoch: epoch, sender: myHash,
                                      index: index, prevHash: prevHash)
            let sealed = try AES.GCM.seal(payload, using: messageKey, authenticating: aad)
            let ciphertext = sealed.combined!

            // 4. Sign ciphertext‖aad with the Secure Enclave device key.
            let signature = try deviceKey.signature(for: ciphertext + aad)

            // Cards keep everything needed to re-run this exact check later
            // (SealedCard.swift). Ordinary bubbles don't — they're verified on
            // arrival and never revisited.
            let proof: MessageProof? = payloadValue.card.map { card in
                MessageProof(ciphertext: ciphertext,
                             signature: signature.derRepresentation,
                             signerDevicePublicKey: devicePub,
                             groupID: groupID, epoch: epoch, chainIndex: index,
                             prevMessageHash: prevHash,
                             cardDigest: card.digest)
            }

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
            let recipients = Self.firesPush(payloadValue.kind)
                ? liveChat.memberHashes.filter { $0 != myHash }
                : []
            var deliveredNow = true
            // Distinct from `deliveredNow`: a queued message has NOT been
            // delivered but WILL be, so the caller has nothing left to do.
            // Only the stale-slot collision below is a dead end.
            var shipped = true
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
                shipped = false
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
                                         replySenderHash: payloadValue.replySenderHash,
                                         card: payloadValue.card,
                                         proof: proof,
                                         introduction: payloadValue.introduce.map {
                                             // The introducer's own copy. No
                                             // `counterpart`: they have two,
                                             // and both names come out of
                                             // their FriendStore.
                                             IntroductionOffer.verified($0, counterpart: nil)
                                         }))
                messagesByChat[chat.id] = local
                persist()
            }
            return shipped
        } catch {
            lastError = "Send failed: \(error.localizedDescription)"
            return false
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

    // MARK: - Introductions (docs/INTRODUCTIONS.md)

    /// Vouch two people you have met IN PERSON into a friendship with each
    /// other. Returns nil on success, or a plain-language reason it didn't
    /// happen.
    ///
    /// Two messages go out, one to each party in the 1:1 chat that already
    /// exists with them. Nothing is published, nothing is queried, and no
    /// record type is involved: an introduction names two people and says a
    /// third vouched for them, which is exactly the who-knows-whom data
    /// docs/TRUST.md D3 keeps private, so it travels encrypted or not at all.
    func sendIntroduction(_ first: FriendStore.StoredFriend,
                          and second: FriendStore.StoredFriend,
                          from myRoot: RootIdentity,
                          friendStore: FriendStore) async -> String? {
        let myHash = myRoot.credentialIDHash
        guard first.id != second.id else { return "Pick two different people." }
        guard first.id != myHash, second.id != myHash else {
            return "An introduction connects two OTHER people."
        }
        // Read both friendships BACK from the store instead of trusting the
        // copies the sheet has been holding: an edge can be un-forged (or
        // upgraded) while a view is alive, and the tier is the whole rule.
        guard let a = friendStore.friends.first(where: { $0.id == first.id }),
              let b = friendStore.friends.first(where: { $0.id == second.id }) else {
            return "One of them isn't in your people any more."
        }
        // Re-check what the picker already filtered. A rule enforced only by a
        // view is a rule an attacker skips — and this one is the whole point:
        // introduction does not chain.
        guard a.friendship.isInPerson, b.friendship.isInPerson else {
            return "You can only introduce people you've met in person through Seal."
        }

        let pair = Introduction.canonical((hash: a.id, publicKey: a.identity.publicKey),
                                          (hash: b.id, publicKey: b.identity.publicKey))
        let createdAtEpoch = Int64(Date.now.timeIntervalSince1970)
        // Demo mode has no device key — nothing in it is ever registered — so
        // it produces the same OFFER with an unsigned statement and skips the
        // signing step, exactly as `demoAccept` skips the acceptance. Without
        // this the demo walkthrough dies at "No device key — re-register." on
        // the one screen it exists to show.
        if DemoFixtures.isActive {
            let statement = IntroductionStatement(
                introducerHash: myHash,
                introducerDevicePublicKey: Data(),
                partyAHash: pair.a.hash, partyAPublicKey: pair.a.publicKey,
                partyBHash: pair.b.hash, partyBPublicKey: pair.b.publicKey,
                createdAtEpoch: createdAtEpoch,
                signature: Data("seal.demo.introduction".utf8))
            introductions.record(statement)
            await deliverOffer(statement, to: a, other: b, from: myRoot)
            await deliverOffer(statement, to: b, other: a, from: myRoot)
            return nil
        }
        guard let deviceKey = identity.deviceKey else { return "No device key — re-register." }

        let commitment = Introduction.commitment(
            introducerHash: myHash,
            partyAHash: pair.a.hash, partyAPublicKey: pair.a.publicKey,
            partyBHash: pair.b.hash, partyBPublicKey: pair.b.publicKey,
            createdAtEpoch: createdAtEpoch)
        let statement: IntroductionStatement
        do {
            let signature = try deviceKey.signature(for: commitment)
            statement = IntroductionStatement(
                introducerHash: myHash,
                introducerDevicePublicKey: deviceKey.publicKey.x963Representation,
                partyAHash: pair.a.hash, partyAPublicKey: pair.a.publicKey,
                partyBHash: pair.b.hash, partyBPublicKey: pair.b.publicKey,
                createdAtEpoch: createdAtEpoch,
                signature: signature.derRepresentation)
        } catch {
            return "Couldn't sign the introduction: \(error.localizedDescription)"
        }
        introductions.record(statement)
        await deliverOffer(statement, to: a, other: b, from: myRoot)
        await deliverOffer(statement, to: b, other: a, from: myRoot)
        Introduction.log.info("sent introduction \(statement.shortID, privacy: .public) to \(a.id, privacy: .public) and \(b.id, privacy: .public)")
        return nil
    }

    /// Re-ship an introduction this device already made and signed. The SAME
    /// statement, byte for byte, so the recipient's store recognises it by
    /// commitment and nobody ends up holding two offers for one introduction.
    /// Returns nil when both copies went out, or a plain-language reason
    /// otherwise — a "Send again" button that can silently do nothing is a
    /// button that trains people to distrust the app.
    @discardableResult
    func resendIntroduction(_ statement: IntroductionStatement,
                            from myRoot: RootIdentity,
                            friendStore: FriendStore) async -> String? {
        guard statement.introducerHash == myRoot.credentialIDHash else {
            return "Only the person who made an introduction can send it again."
        }
        var sent = 0
        for hash in [statement.partyAHash, statement.partyBHash] {
            guard let party = friendStore.friends.first(where: { $0.id == hash }),
                  let otherHash = statement.counterpartHash(for: hash),
                  let other = friendStore.friends.first(where: { $0.id == otherHash })
            else { continue }
            await deliverOffer(statement, to: party, other: other, from: myRoot)
            sent += 1
        }
        return sent == 2 ? nil : "One of the two isn't in your people any more, so Seal didn't send it again."
    }

    private func deliverOffer(_ statement: IntroductionStatement,
                              to party: FriendStore.StoredFriend,
                              other: FriendStore.StoredFriend,
                              from myRoot: RootIdentity) async {
        let chat = ensureChat(with: party.identity, myHash: myRoot.credentialIDHash)
        // Introductions inherit the chat's TTL like every other message. They
        // are NOT carved out: the verification drawer promises disappearing
        // messages disappear, and a message class that quietly outlives that
        // promise is how honest copy becomes dishonest (docs/CARDS.md made the
        // same call). If an unanswered card burns, the introducer's own card
        // still offers "Send again", which re-ships this identical statement.
        let ttl = chats.first(where: { $0.id == chat.id })?.ttl
        // `text` is the old-build fallback, exactly as a card's is: a build
        // without introductions decodes this payload fine, falls through to
        // `default:`, and renders `text` — the only field it reads.
        await sendPayload(MessagePayload(
            text: "\(myRoot.displayName) would like to introduce you to \(other.identity.displayName). Update Seal to accept.",
            ttl: ttl, kind: Introduction.offerKind, introduce: statement),
            in: chat, from: myRoot)
    }

    /// Accept an introduction: sign it and send the acceptance back to the
    /// introducer. Nil on success, a plain-language reason otherwise.
    ///
    /// Accepting is NOT the moment the friendship appears. Both parties have
    /// to accept, and the friend record is created when the introducer's
    /// confirmation carrying both acceptances arrives (`materialize`).
    func acceptIntroduction(_ offer: IntroductionOffer,
                            in chat: Chat,
                            from myRoot: RootIdentity,
                            friendStore: FriendStore) async -> String? {
        let statement = offer.statement
        let myHash = myRoot.credentialIDHash
        guard offer.isActionable else {
            return offer.refusal ?? offer.unchecked ?? "This introduction can't be accepted."
        }
        guard statement.involves(myHash) else { return "This introduction is addressed to someone else." }
        // Check (b), enforced HERE and not only in the card: the introducer
        // must be someone THIS phone met in person. This is where "a linked
        // friend cannot introduce" actually bites.
        if let reason = Introduction.introducerEligibility(statement, friendStore: friendStore) {
            return reason
        }
        if let existing = introductions.entry(for: statement) {
            if existing.declinedAt != nil { return "You already dismissed this introduction." }
            // Idempotent: accepting twice re-signs nothing and re-sends
            // nothing. The card doesn't offer the button in this state, but
            // the engine is what has to be true.
            if existing.myAcceptance(myHash) != nil { return nil }
        }
        if DemoFixtures.isActive {
            return demoAccept(statement, from: myRoot, friendStore: friendStore)
        }
        guard let deviceKey = identity.deviceKey else { return "No device key — re-register." }

        let acceptedAtEpoch = Int64(Date.now.timeIntervalSince1970)
        let commitment = Introduction.acceptanceCommitment(
            introduction: statement.commitment, accepterHash: myHash, acceptedAtEpoch: acceptedAtEpoch)
        let acceptance: IntroductionAcceptance
        do {
            let signature = try deviceKey.signature(for: commitment)
            acceptance = IntroductionAcceptance(
                introductionCommitment: statement.commitment,
                accepterHash: myHash,
                accepterDevicePublicKey: deviceKey.publicKey.x963Representation,
                acceptedAtEpoch: acceptedAtEpoch,
                signature: signature.derRepresentation)
        } catch {
            return "Couldn't sign your acceptance: \(error.localizedDescription)"
        }
        // Recorded BEFORE the send, so a send that fails leaves this phone
        // knowing it said yes — `resendAcceptanceOnce` picks it up later.
        introductions.recordAcceptance(acceptance, for: statement)
        await sendPayload(MessagePayload(text: "", ttl: nil, kind: Introduction.acceptKind,
                                         introduceAccept: acceptance),
                          in: chat, from: myRoot)
        Introduction.log.info("accepted introduction \(statement.shortID, privacy: .public)")
        return nil
    }

    /// "Not now." Nothing is sent, ever — the introducer keeps seeing "not
    /// accepted yet" and never learns which side stopped. That silence is a
    /// protocol rule, not an omission: there is nothing useful the introducer
    /// could do with the information and plenty of family they could do it to.
    func declineIntroduction(_ offer: IntroductionOffer) {
        introductions.markDeclined(offer.statement)
        Introduction.log.info("dismissed introduction \(offer.statement.shortID, privacy: .public) — nothing sent, by design")
    }

    /// Push every introduction this device is part of as far as it can go.
    /// Called from `refreshAll` and from the open-chat poll, so the flow
    /// survives any phone being offline at any step. Every transition is
    /// idempotent and keyed by the commitment hash.
    func ensureIntroductionsProgressed(myRoot: RootIdentity, friendStore: FriendStore) async {
        guard !DemoFixtures.isActive else { return }
        let myHash = myRoot.credentialIDHash
        await retryUncheckedOffers(myRoot: myRoot)
        for entry in introductions.entries {
            guard entry.abandonedAt == nil else { continue }
            // Rate floor — see `introductionAttempts`. Recorded before the
            // work, so a failure costs the same as a success.
            if let last = introductionAttempts[entry.commitmentHex],
               Date.now.timeIntervalSince(last) < 60 { continue }
            introductionAttempts[entry.commitmentHex] = .now
            if entry.isIntroducer(myHash) {
                guard entry.bothAccepted, entry.confirmationsSentAt == nil else { continue }
                await sendConfirmations(entry, from: myRoot, friendStore: friendStore)
            } else {
                guard entry.declinedAt == nil, entry.completedAt == nil else { continue }
                if entry.bothAccepted {
                    await materialize(entry, myRoot: myRoot, friendStore: friendStore)
                } else if entry.myAcceptance(myHash) != nil {
                    await resendAcceptanceOnce(entry, myRoot: myRoot, friendStore: friendStore)
                }
            }
        }
    }

    /// Both parties said yes: hand each of them the other's acceptance.
    private func sendConfirmations(_ entry: IntroductionStore.Entry,
                                   from myRoot: RootIdentity,
                                   friendStore: FriendStore) async {
        let statement = entry.statement
        guard let a = entry.acceptances[statement.partyAHash],
              let b = entry.acceptances[statement.partyBHash] else { return }
        // Both of them must STILL be friends of ours. Un-forging one is a
        // deliberate act and it stops the introduction we were carrying — the
        // same call `materialize` makes about an un-forged introducer. Latched
        // as abandoned so a dead flow doesn't re-push whoever is left on every
        // single launch.
        guard friendStore.isFriend(statement.partyAHash),
              friendStore.isFriend(statement.partyBHash) else {
            Introduction.log.error("confirm: abandoned \(entry.shortID, privacy: .public) — one of the two is no longer a friend of this phone")
            introductions.markAbandoned(entry.commitmentHex)
            return
        }
        let confirmation = IntroductionConfirmation(statement: statement, acceptances: [a, b])
        var shipped = 0
        for hash in [statement.partyAHash, statement.partyBHash] {
            guard let party = friendStore.friends.first(where: { $0.id == hash }) else { continue }
            let chat = ensureChat(with: party.identity, myHash: myRoot.credentialIDHash)
            if await sendPayload(MessagePayload(text: "", ttl: nil, kind: Introduction.confirmKind,
                                                introduceConfirm: confirmation),
                                 in: chat, from: myRoot) {
                shipped += 1
            }
        }
        // Only latch when BOTH are on their way. Half a confirmation is two
        // people waiting on each other forever, and re-sending is free: the
        // recipients key everything by commitment hash and a second copy
        // changes nothing.
        guard shipped == 2 else {
            Introduction.log.error("confirm: only \(shipped, privacy: .public)/2 delivered for \(entry.shortID, privacy: .public) — will retry next refresh")
            return
        }
        introductions.markConfirmationsSent(entry.commitmentHex)
        Introduction.log.info("confirm: both parties notified for \(entry.shortID, privacy: .public)")
    }

    /// Create the linked friendship. Runs on a PARTY's device once both
    /// acceptances are in hand, and re-verifies everything from scratch
    /// against a force-refreshed directory before writing anything: the
    /// acceptances arrived inside a bundle assembled by the introducer, who is
    /// exactly the person this feature asks you to trust the least.
    private func materialize(_ entry: IntroductionStore.Entry,
                             myRoot: RootIdentity,
                             friendStore: FriendStore) async {
        let statement = entry.statement
        let myHash = myRoot.credentialIDHash
        guard let counterpartHash = statement.counterpartHash(for: myHash),
              let mine = entry.acceptances[myHash],
              let theirs = entry.acceptances[counterpartHash] else {
            // Malformed for this device — not one of the two parties, or an
            // acceptance we were told exists and don't hold. Nothing about
            // that changes on a retry.
            Introduction.log.error("materialize: abandoned \(entry.shortID, privacy: .public) — this phone isn't part of it, or an acceptance is missing")
            introductions.markAbandoned(entry.commitmentHex)
            return
        }

        // NEVER DOWNGRADE. If this person is already a friend, the existing
        // edge is either in-person (strictly stronger) or already linked
        // (identical) — either way, replacing it could only lose information,
        // and a replayed confirmation must never turn a brass friendship into
        // a silver one.
        guard !friendStore.isFriend(counterpartHash) else {
            introductions.markCompleted(entry.commitmentHex)
            return
        }
        // The introducer must STILL be an in-person friend. Un-forging them
        // between the offer and the confirmation is a deliberate act, and it
        // should stop the introduction they were carrying.
        if let reason = Introduction.introducerEligibility(statement, friendStore: friendStore) {
            Introduction.log.error("materialize: abandoned \(entry.shortID, privacy: .public) — \(reason, privacy: .public)")
            introductions.markAbandoned(entry.commitmentHex)
            return
        }
        // Two kinds of failure below, and they must not be confused. A
        // directory we couldn't REACH keeps retrying. A check that actually
        // FAILED latches as abandoned — otherwise a dead introduction would
        // force-refresh two identity records every four seconds, for the life
        // of the install, and rewrite `lastError` each time (the open-chat
        // poll calls this).
        let counterpartEntry = (try? await directoryEntry(for: counterpartHash, forceRefresh: true)) ?? nil
        let myEntry = (try? await directoryEntry(for: myHash, forceRefresh: true)) ?? nil
        guard let (counterpartRoot, _) = counterpartEntry else {
            Introduction.log.error("materialize: directory unreachable for \(counterpartHash, privacy: .public) — will retry")
            return
        }
        guard myEntry != nil else {
            Introduction.log.error("materialize: directory unreachable for this phone's own identity — will retry")
            return
        }
        // Check (d) again, now, against a fresh directory read.
        guard counterpartRoot.publicKey == statement.publicKey(for: counterpartHash) else {
            Introduction.log.error("materialize: REFUSED — \(counterpartHash, privacy: .public) now publishes a different identity key than the introduction names")
            lastError = "\(counterpartRoot.displayName)'s identity key changed since that introduction was made, so Seal didn't complete it. Ask to be introduced again."
            introductions.markAbandoned(entry.commitmentHex)
            return
        }
        guard Introduction.verifyAcceptance(theirs, for: statement, accepter: counterpartEntry, identity: identity) else {
            Introduction.log.error("materialize: REFUSED — the other party's acceptance didn't verify")
            introductions.markAbandoned(entry.commitmentHex)
            return
        }
        // Our OWN acceptance is verified too, against our own published
        // devices. That is what lets a phone complete an introduction from a
        // confirmation alone after a reinstall: a signature we made is
        // something nobody else can produce, so the bundle is self-sufficient.
        guard Introduction.verifyAcceptance(mine, for: statement, accepter: myEntry, identity: identity) else {
            Introduction.log.error("materialize: REFUSED — this phone's own acceptance didn't verify against its published devices")
            introductions.markAbandoned(entry.commitmentHex)
            return
        }

        let ordered = [statement.partyAHash, statement.partyBHash].compactMap { entry.acceptances[$0] }
        let proof = IntroductionProof(statement: statement, acceptances: ordered)
        guard let encoded = try? JSONEncoder().encode(proof) else {
            // Cannot happen with this shape (Data, String, Int64) and cannot
            // succeed later if it somehow did.
            Introduction.log.error("materialize: abandoned \(entry.shortID, privacy: .public) — the proof wouldn't encode")
            introductions.markAbandoned(entry.commitmentHex)
            return
        }
        // `attestation` carries the proof, so a linked edge stays
        // re-verifiable offline from the friendship alone — the same thing
        // ForgeHandshake does with its handshake. The typed `introduction`
        // field is the one anything reads; both come from this one encode, so
        // they cannot drift.
        friendStore.add(identity: counterpartRoot,
                        friendship: Friendship(friendRootID: counterpartHash,
                                               attestation: encoded,
                                               reverseAttestation: nil,
                                               forgedAt: .now,
                                               autoReciprocated: nil,
                                               introduction: proof))
        _ = ensureChat(with: counterpartRoot, myHash: myHash)
        introductions.markCompleted(entry.commitmentHex)
        Introduction.log.info("materialize: LINKED with \(counterpartHash, privacy: .public) via \(statement.introducerHash, privacy: .public)")
    }

    /// One nudge per launch for an acceptance the introducer may never have
    /// received (their phone was off, ours dropped the send). Bounded on
    /// purpose: a permanent retry queue for a message that is probably already
    /// delivered would be chatter nobody can see and nobody asked for.
    private func resendAcceptanceOnce(_ entry: IntroductionStore.Entry,
                                      myRoot: RootIdentity,
                                      friendStore: FriendStore) async {
        let myHash = myRoot.credentialIDHash
        guard let acceptance = entry.myAcceptance(myHash),
              // Give the first send a chance to land before nudging.
              Date.now.timeIntervalSince(acceptance.acceptedAt) > 600,
              !resentAcceptances.contains(entry.commitmentHex),
              let introducer = friendStore.friends.first(where: { $0.id == entry.statement.introducerHash })
        else { return }
        resentAcceptances.insert(entry.commitmentHex)
        let chat = ensureChat(with: introducer.identity, myHash: myHash)
        await sendPayload(MessagePayload(text: "", ttl: nil, kind: Introduction.acceptKind,
                                         introduceAccept: acceptance),
                          in: chat, from: myRoot)
    }

    /// Re-run the checks on any offer that couldn't be checked when it landed
    /// (directory unreachable). Updates the card in place, so "checking…"
    /// resolves on its own instead of needing the message to arrive again —
    /// which it never will, because the ratchet has already eaten the key.
    private func retryUncheckedOffers(myRoot: RootIdentity) async {
        var changed = false
        for (chatID, messages) in messagesByChat {
            guard let chat = chats.first(where: { $0.id == chatID }) else { continue }
            for message in messages {
                guard let offer = message.introduction, offer.unchecked != nil else { continue }
                let rechecked = await checkedOffer(offer.statement, sender: message.senderHash,
                                                   chat: chat, myRoot: myRoot)
                guard rechecked.unchecked == nil else { continue }
                // Re-find by id: this loop awaits, and a concurrent refresh
                // may have appended to the same chat in the meantime.
                if let index = messagesByChat[chatID]?.firstIndex(where: { $0.id == message.id }) {
                    messagesByChat[chatID]?[index].introduction = rechecked
                    changed = true
                }
            }
        }
        if changed { persist() }
    }

    /// Every cryptographic check on an inbound offer, plus the directory
    /// lookups they need. Records the statement locally when it passes, so
    /// the flow can be resumed from state rather than from the transcript.
    private func checkedOffer(_ statement: IntroductionStatement,
                              sender: String,
                              chat: Chat,
                              myRoot: RootIdentity) async -> IntroductionOffer {
        let introducer = (try? await directoryEntry(for: statement.introducerHash)) ?? nil
        var counterpart: (RootIdentity, [DeviceEndorsement])? = nil
        if let hash = statement.counterpartHash(for: myRoot.credentialIDHash) {
            counterpart = (try? await directoryEntry(for: hash)) ?? nil
        }
        let offer = Introduction.checkOffer(statement,
                                            senderHash: sender,
                                            isOneToOneChat: chat.memberHashes.count == 2,
                                            myHash: myRoot.credentialIDHash,
                                            myPublicKey: myRoot.publicKey,
                                            introducer: introducer,
                                            counterpart: counterpart,
                                            now: .now,
                                            identity: identity)
        // One check the pure function can't make: blocking is local, and
        // completing an introduction to someone this phone has blocked would
        // quietly re-add them to the friend list while their messages stayed
        // hidden — a friendship the owner can't see and didn't ask for.
        if offer.isActionable,
           let counterpartHash = statement.counterpartHash(for: myRoot.credentialIDHash),
           blockedHashes.contains(counterpartHash) {
            return .refused(statement, "You've blocked the person in this introduction. Unblock them first, then ask to be introduced again.")
        }
        if offer.isActionable {
            introductions.record(statement)
        } else if let refusal = offer.refusal {
            Introduction.log.error("offer: REFUSED \(statement.shortID, privacy: .public) from \(sender, privacy: .public) — \(refusal, privacy: .public)")
        }
        return offer
    }

    /// Demo mode (FR-22/23) has no keys and never touches a verification path
    /// — fixtures are trusted by construction. Accepting a demo introduction
    /// therefore skips the protocol entirely and produces the OUTCOME, so the
    /// whole three-party flow can be walked through on one simulator with
    /// `-SealDemoMode`. Nothing here runs outside demo mode.
    private func demoAccept(_ statement: IntroductionStatement,
                            from myRoot: RootIdentity,
                            friendStore: FriendStore) -> String? {
        let myHash = myRoot.credentialIDHash
        guard let counterpartHash = statement.counterpartHash(for: myHash) else {
            return "This introduction is addressed to someone else."
        }
        let stamp = Int64(Date.now.timeIntervalSince1970)
        func acceptance(_ hash: String) -> IntroductionAcceptance {
            IntroductionAcceptance(introductionCommitment: statement.commitment,
                                   accepterHash: hash,
                                   accepterDevicePublicKey: Data(),
                                   acceptedAtEpoch: stamp,
                                   signature: Data())
        }
        introductions.recordAcceptance(acceptance(myHash), for: statement)
        introductions.recordAcceptance(acceptance(counterpartHash), for: statement)
        guard let counterpart = DemoFixtures.person(hash: counterpartHash) else { return nil }
        let proof = IntroductionProof(
            statement: statement,
            acceptances: [acceptance(statement.partyAHash), acceptance(statement.partyBHash)])
        if !friendStore.isFriend(counterpartHash), let encoded = try? JSONEncoder().encode(proof) {
            friendStore.add(identity: counterpart,
                            friendship: Friendship(friendRootID: counterpartHash,
                                                   attestation: encoded,
                                                   reverseAttestation: nil,
                                                   forgedAt: .now,
                                                   autoReciprocated: nil,
                                                   introduction: proof))
            _ = ensureChat(with: counterpart, myHash: myHash)
        }
        introductions.markCompleted(statement.commitmentHex)
        return nil
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
                    // Read once: `chain.lastMessageHash` advances at the bottom
                    // of this loop, and a card's proof must record the value
                    // that actually went into this message's AAD.
                    let prevHash = chain.lastMessageHash
                    let aad = Self.messageAAD(groupID: groupID, epoch: epoch, sender: sender,
                                              index: chain.index, prevHash: prevHash)

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
                        lastError = "Couldn't verify a message from a member. If it keeps happening, ask them to reopen the app (to republish their key) or re-friend."
                        Self.advance(&chain)    // skip the bad slot, don't stall the chain
                        // CRITICAL: mirror the sender's transcript hash even
                        // though we rejected this message. The sender advances
                        // lastMessageHash for EVERY message it sends, so if we
                        // skip a slot without doing the same, our prevHash and
                        // theirs diverge and the AAD is wrong for every message
                        // that follows — the signature then fails forever and
                        // the conversation is dead from one transient hiccup.
                        // Tamper evidence is unaffected: a swapped ciphertext
                        // still produces an AAD the real sender never signed,
                        // so the NEXT message fails on its signature, which an
                        // attacker cannot forge without the device key.
                        chain.lastMessageHash = Data(SHA256.hash(data: wire.ciphertext))
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
                        // Same reason as the verify-miss path above: the sender
                        // hashed this slot into its chain, so we must too, or
                        // every later message fails its AAD check.
                        chain.lastMessageHash = Data(SHA256.hash(data: wire.ciphertext))
                        continue
                    }

                    let payload = (try? JSONDecoder().decode(MessagePayload.self, from: plaintext))
                        ?? MessagePayload(text: String(decoding: plaintext, as: UTF8.self), ttl: nil)

                    // An introduction offer is a BUBBLE kind — it renders a
                    // card and fires a push, like a sealed card — so it falls
                    // through to `default:` with its verdict attached.
                    // Everything cryptographic about it is settled HERE,
                    // before the bubble exists, because the card must be a
                    // pure function of stored state: `body` cannot fetch a
                    // directory, and a message is only decryptable once.
                    var introductionOffer: IntroductionOffer? = nil
                    if payload.kind == Introduction.offerKind, let statement = payload.introduce {
                        introductionOffer = await checkedOffer(statement, sender: sender,
                                                               chat: liveChat, myRoot: myRoot)
                    }

                    switch payload.kind ?? "" {
                    case "reaction":
                        // Mutates an existing bubble; never appended as its own.
                        applyReaction(chatID: chat.id, reactorHash: sender,
                                      reactTo: payload.reactTo ?? "", emoji: payload.emoji)
                    case "read":
                        applyRead(chatID: chat.id, readerHash: sender, upTo: payload.readUpTo)
                    case "typing":
                        markTyping(chatID: chat.id, memberHash: sender)
                    case Introduction.acceptKind:
                        // Someone answered an introduction WE made. Verified
                        // against the accepter's published devices before it
                        // is recorded — the sender of a message and the
                        // signer of the acceptance inside it must be the same
                        // person, or an introducer could be told a party
                        // agreed when they never did.
                        guard let acceptance = payload.introduceAccept,
                              acceptance.accepterHash == sender,
                              let record = introductions.entry(acceptance.introductionCommitment.hexString),
                              record.isIntroducer(myRoot.credentialIDHash),
                              record.statement.involves(sender),
                              Introduction.verifyAcceptance(acceptance, for: record.statement,
                                                            accepter: entry, identity: identity)
                        else {
                            Introduction.log.error("accept: dropped an acceptance that didn't check out (from \(sender, privacy: .public))")
                            break
                        }
                        introductions.recordAcceptance(acceptance, for: record.statement)
                        Introduction.log.info("accept: \(sender, privacy: .public) accepted \(record.shortID, privacy: .public)")
                    case Introduction.confirmKind:
                        // Both parties said yes and the introducer is handing
                        // us the other side's signed acceptance. The whole
                        // bundle is re-checked: the statement as if it had
                        // just arrived, then each acceptance against the
                        // accepter's own published devices. `materialize`
                        // checks all of it AGAIN against a forced directory
                        // refresh before a friend record is written — the
                        // introducer assembled this bundle, and they are the
                        // party this feature trusts least.
                        guard let confirmation = payload.introduceConfirm,
                              confirmation.statement.introducerHash == sender else { break }
                        let checked = await checkedOffer(confirmation.statement, sender: sender,
                                                         chat: liveChat, myRoot: myRoot)
                        guard checked.isActionable else { break }
                        for acceptance in confirmation.acceptances {
                            guard confirmation.statement.involves(acceptance.accepterHash) else { continue }
                            let accepter = (try? await directoryEntry(for: acceptance.accepterHash)) ?? nil
                            guard Introduction.verifyAcceptance(acceptance, for: confirmation.statement,
                                                                accepter: accepter, identity: identity) else {
                                Introduction.log.error("confirm: dropped an acceptance that didn't verify (claimed \(acceptance.accepterHash, privacy: .public))")
                                continue
                            }
                            introductions.recordAcceptance(acceptance, for: confirmation.statement)
                        }
                    default:
                        // Idempotent display: a message can be processed more
                        // than once (overlapping refreshes, a re-fetch after a
                        // racy chain save). wireID is stable per message, so if
                        // it's already on screen, don't append a duplicate.
                        let wireID = "\(sender).e\(epoch).\(idx)"
                        if messagesByChat[chat.id]?.contains(where: { $0.wireID == wireID }) == true {
                            break
                        }
                        // One card per introduction, whatever the transport
                        // does. The introducer can re-send the identical
                        // signed statement (their card offers "Send again"),
                        // and that must reappear if the first card burned on a
                        // TTL — but never stack two live cards for one offer.
                        if let introductionOffer,
                           messagesByChat[chat.id]?.contains(where: {
                               $0.introduction?.statement.commitmentHex == introductionOffer.statement.commitmentHex
                           }) == true {
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
                            replySenderHash: payload.replySenderHash,
                            card: payload.card,
                            // Cards only. This message just passed
                            // verifyInbound above; keeping the tuple is what
                            // lets the detail sheet run that check again later
                            // against a fresh directory, instead of reporting
                            // a check it merely remembers.
                            proof: payload.card.map { card in
                                MessageProof(
                                    ciphertext: wire.ciphertext,
                                    signature: wire.signature,
                                    signerDevicePublicKey: wire.senderDevicePublicKey,
                                    groupID: groupID, epoch: epoch, chainIndex: idx,
                                    prevMessageHash: prevHash,
                                    cardDigest: card.digest)
                            },
                            introduction: introductionOffer))
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
    ///
    /// A sealed card that burns here used to take its record line with it, so
    /// the record quietly forgot that anything had ever been sent, which is the
    /// exact moment somebody would reach for it (docs/RECORD.md §11). Every
    /// card about to be dropped therefore leaves a tombstone FIRST: kind, time,
    /// counterpart, title and digest. Never the value. The value burning is the
    /// entire point of the TTL.
    ///
    /// Capturing here rather than at send or receive means one hook covers
    /// every path, and nothing can be purged without passing through it, even
    /// a card that arrived and expired while the app was closed.
    func purgeExpired() {
        let now = Date.now
        var changed = false
        for (chatID, messages) in messagesByChat {
            let kept = messages.filter { ($0.expiresAt ?? .distantFuture) > now }
            if kept.count != messages.count {
                let burning = messages.filter {
                    ($0.expiresAt ?? .distantFuture) <= now && $0.card != nil
                }
                if !burning.isEmpty, let chat = chats.first(where: { $0.id == chatID }) {
                    RecordStubStore.upsert(burning.compactMap { recordStub(for: $0, in: chat) },
                                           ownerHash: ownerHash)
                }
                messagesByChat[chatID] = kept
                changed = true
            }
        }
        if changed { persist() }
    }

    /// The tombstone for one card. Mirrors what `RecordBuilder` derives from a
    /// live card exactly, field for field, so the event's digest and therefore
    /// its identity are IDENTICAL before and after the burn.
    private func recordStub(for message: ChatMessage, in chat: Chat) -> RecordStub? {
        guard let card = message.card else { return nil }
        let mine = message.senderHash == ownerHash
        let others = chat.memberHashes.filter { $0 != ownerHash }
        // A 1:1 chat has one counterpart and its name IS that person's display
        // name. A group has no single counterpart, so the line belongs to the
        // whole record rather than to any one person's timeline.
        let partner: String? = mine ? (others.count == 1 ? others.first : nil)
                                    : message.senderHash
        return RecordStub(
            kindRaw: (mine ? RecordEvent.Kind.cardSent : RecordEvent.Kind.cardReceived).rawValue,
            occurredAtEpoch: RecordEvent.epochSeconds(message.sentAt),
            counterpartHash: partner,
            counterpartName: partner == nil ? nil : chat.name,
            title: card.title,
            contentDigestHex: (message.proof?.cardDigest ?? card.digest)?.hexString,
            sourceRef: message.wireID ?? message.id.uuidString)
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

    // MARK: - Card re-verification (docs/CARDS.md)

    /// Re-check a card's signature RIGHT NOW, rather than reporting that we
    /// checked it once when it arrived.
    ///
    /// This runs the SAME check the receive path already ran — no new signature
    /// scheme (SDS §2) — but against a force-refreshed directory entry, so a
    /// signing device that was REVOKED after the card landed makes the card
    /// fail rather than pass. That is the case an arrival-time check can never
    /// catch, and on a card carrying a wallet address it's the one that matters.
    ///
    /// `.failed` and `.unavailable` are kept apart on purpose: "the signature
    /// is bad" and "I couldn't reach the directory" have opposite consequences
    /// for someone about to send money, and collapsing them into one grey state
    /// would be a lie in whichever direction it resolved.
    func verifyCard(_ message: ChatMessage) async -> CardVerification {
        // Demo fixtures are trusted by construction and never signed (FR-22).
        if DemoFixtures.isActive { return .demo }
        guard let proof = message.proof else {
            return .unavailable("This card arrived before this build kept re-checkable proofs. It was verified when it was received.")
        }
        let aad = Self.messageAAD(groupID: proof.groupID, epoch: proof.epoch,
                                  sender: message.senderHash, index: proof.chainIndex,
                                  prevHash: proof.prevMessageHash)
        let entry: (RootIdentity, [DeviceEndorsement])?
        do {
            entry = try await directoryEntry(for: message.senderHash, forceRefresh: true)
        } catch {
            return .unavailable("Couldn't reach the directory to re-check this card. It was verified when it was received.")
        }
        guard let entry else {
            return .failed("This sender is no longer in the public directory.")
        }
        let wire = SyncEngine.WireMessage(ciphertext: proof.ciphertext,
                                          senderDevicePublicKey: proof.signerDevicePublicKey,
                                          signature: proof.signature,
                                          sentAt: message.sentAt)
        guard verifyInbound(wire, aad: aad, entry: entry) else {
            ChatEngine.msgLog.error("card: re-verify FAILED (sender=\(message.senderHash, privacy: .public) signer=\(proof.signerFingerprint, privacy: .public))")
            return .failed("This card's signature no longer checks out against \(entry.0.displayName)'s published keys. Don't act on it.")
        }
        // The signature covers the CIPHERTEXT, and the message key that opened
        // it is long gone (per-message forward secrecy), so a passing signature
        // alone doesn't establish that the card on screen is what was inside.
        // The digest recorded at decryption time closes that on our side. See
        // MessageProof.cardDigest for precisely what it does and doesn't cover.
        guard let recorded = proof.cardDigest else {
            // Shouldn't happen — this build always records one. Report it
            // rather than skipping the comparison and returning `.sealed`,
            // which would claim a check that never ran.
            return .unavailable("This card's signature checks out, but it was recorded before this build kept content digests, so the stored copy can't be compared against what was received.")
        }
        // A nil digest here (encode failure) compares unequal to a recorded
        // one, so this fails closed.
        guard let card = message.card, card.digest == recorded else {
            ChatEngine.msgLog.error("card: stored card does not match the digest recorded at decryption (sender=\(message.senderHash, privacy: .public))")
            return .failed("The stored copy of this card doesn't match what was received. Don't act on it — ask \(entry.0.displayName) to send it again.")
        }
        return .sealed(signerFingerprint: proof.signerFingerprint, sender: entry.0)
    }

    /// A directory entry already fetched this session, if there is one.
    /// Synchronous and cache-only — it never reaches the network.
    ///
    /// Exists so a card bubble can show a group member's real name and tier
    /// when they aren't in the FriendStore (you can share a colony with someone
    /// you've never forged with) without doing a fetch per row. `refresh`
    /// populates this for every sender it processes, so it's warm in practice.
    func cachedIdentity(for hash: String) -> RootIdentity? {
        directoryCache[hash]?.0
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
