import Foundation
import CryptoKit

/// E2EE chat over CloudKit (SDS §2, §5). Each member has a per-chat sender
/// chain; per-message keys ratchet forward and are never reused. Inbound
/// messages pass the full verification chain (root → endorsement → signature)
/// before display — unverifiable messages are dropped, never shown.
@Observable
final class ChatEngine {
    struct Chat: Codable, Identifiable, Hashable {
        let id: UUID
        var name: String
        var memberHashes: [String]      // root credentialIDHashes, including me
        var ttl: TimeInterval?          // disappearing messages (FR-12), nil = keep
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
    }

    /// What actually gets encrypted — TTL and the media content key travel
    /// inside the sealed payload, invisible to the server.
    private struct MessagePayload: Codable {
        let text: String
        let ttl: TimeInterval?
        var mediaRef: String?
        var mediaKey: Data?
    }

    private struct ChainState: Codable {
        var chainKey: Data
        var index: UInt64
        /// Transcript chain (SDS §2): hash of this sender's previous ciphertext.
        /// Bound into the AAD and signature of the next message, so the server
        /// can't substitute, drop, or reorder a sender's messages undetected.
        var lastMessageHash: Data?
    }

    /// AAD v2 binds group, sender, index, AND the previous message hash.
    private static func messageAAD(groupID: String, sender: String, index: UInt64, prevHash: Data?) -> Data {
        Data("seal.msg.v2|\(groupID)|\(sender)|\(index)|\((prevHash ?? Data()).hexString)".utf8)
    }

    private(set) var chats: [Chat] = []
    private(set) var messagesByChat: [UUID: [ChatMessage]] = [:]
    private(set) var lastError: String?

    private let identity: IdentityManager
    private let sync: SyncEngine
    // chains["send.<chatID>"] = my sending chain
    // chains["recv.<chatID>.<senderHash>"] = a member's receiving chain
    private var chains: [String: ChainState] = [:]
    // directory cache: rootHash → (identity, verified endorsements)
    private var directoryCache: [String: (RootIdentity, [DeviceEndorsement])] = [:]

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
    }

    func createGroup(name: String, friendHashes: [String], myRoot: RootIdentity) async -> Chat? {
        guard let deviceKey = identity.deviceKey,
              let devicePub = identity.deviceKey?.publicKey.x963Representation else {
            lastError = "No device key — re-register."; return nil
        }
        let chat = Chat(id: UUID(), name: name,
                        memberHashes: [myRoot.credentialIDHash] + friendHashes, ttl: nil)
        chats.append(chat)
        persist()
        do {
            let chatData = try JSONEncoder().encode(chat)
            let signature = try deviceKey.signature(for: chatData)
            let invite = GroupInvite(chatData: chatData,
                                     senderHash: myRoot.credentialIDHash,
                                     senderDevicePub: devicePub,
                                     signature: signature.derRepresentation)
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
        var added = false
        for payload in payloads {
            guard let invite = try? JSONDecoder().decode(GroupInvite.self, from: payload),
                  let chat = try? JSONDecoder().decode(Chat.self, from: invite.chatData),
                  !chats.contains(where: { $0.id == chat.id }),
                  chat.memberHashes.contains(myRoot.credentialIDHash),
                  friendStore.isFriend(invite.senderHash),
                  let (root, endorsements) = try? await directoryEntry(for: invite.senderHash),
                  identity.verify(signature: invite.signature, over: invite.chatData,
                                  deviceKey: invite.senderDevicePub,
                                  claimedRoot: root, endorsements: endorsements)
            else { continue }
            chats.append(chat)
            added = true
        }
        if added { persist() }
    }

    /// Full sync pass: surface 1:1 chats for every friend, accept invites,
    /// pull new messages everywhere. Called on launch, foreground, and push.
    func refreshAll(myRoot: RootIdentity, friendStore: FriendStore) async {
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
        (messagesByChat[chat.id] ?? []).sorted { $0.sentAt < $1.sentAt }
    }

    // MARK: - Send

    func send(_ text: String, in chat: Chat, from myRoot: RootIdentity) async {
        let ttl = chats.first(where: { $0.id == chat.id })?.ttl
        await sendPayload(MessagePayload(text: text, ttl: ttl), in: chat, from: myRoot)
    }

    /// Encrypt a photo with a fresh content key, park the blob in CloudKit,
    /// and send a message carrying the key inside the E2EE payload.
    func sendPhoto(_ jpeg: Data, in chat: Chat, from myRoot: RootIdentity) async {
        do {
            let contentKey = SymmetricKey(size: .bits256)
            let sealed = try AES.GCM.seal(jpeg, using: contentKey).combined!
            let mediaRef = try await sync.saveMediaAsset(sealed)
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
        guard let deviceKey = identity.deviceKey,
              let devicePub = identity.deviceKey?.publicKey.x963Representation else {
            lastError = "No device key — re-register."; return
        }
        let myHash = myRoot.credentialIDHash
        let groupID = chat.id.uuidString
        do {
            // 1. Sending chain: create + distribute on first message.
            var chain = chains["send.\(chat.id)"]
            if chain == nil {
                let fresh = ChainState(chainKey: Self.randomBytes(32), index: 0)
                for member in chat.memberHashes where member != myHash {
                    guard let (_, endorsements) = try await directoryEntry(for: member),
                          let recipientKEM = endorsements.first?.kemBundlePublicKeys,
                          !recipientKEM.isEmpty else {
                        lastError = "A member's identity has no message keys — they need to re-register."
                        return
                    }
                    let envelope = try HybridKEM.wrap(fresh.chainKey, to: recipientKEM)
                    try await sync.saveKeyEnvelope(
                        groupID: groupID, senderHash: myHash,
                        recipientHash: member, envelope: envelope)
                }
                chain = fresh
            }
            var state = chain!

            // 2. Ratchet: derive this message's key, advance the chain.
            let (messageKey, index) = Self.ratchet(&state)

            // 3. Encrypt. AAD binds group, sender, index, and prev-message hash.
            let payload = try JSONEncoder().encode(payloadValue)
            let aad = Self.messageAAD(groupID: groupID, sender: myHash,
                                      index: index, prevHash: state.lastMessageHash)
            let sealed = try AES.GCM.seal(payload, using: messageKey, authenticating: aad)
            let ciphertext = sealed.combined!

            // 4. Sign ciphertext‖aad with the Secure Enclave device key.
            let signature = try deviceKey.signature(for: ciphertext + aad)

            // 5. Ship it.
            try await sync.saveMessage(
                groupID: groupID, senderHash: myHash, chainIndex: index,
                message: .init(ciphertext: ciphertext,
                               senderDevicePublicKey: devicePub,
                               signature: signature.derRepresentation,
                               sentAt: .now),
                recipients: chat.memberHashes.filter { $0 != myHash })

            // Advance the transcript chain.
            state.lastMessageHash = Data(SHA256.hash(data: ciphertext))
            chains["send.\(chat.id)"] = state
            var local = messagesByChat[chat.id] ?? []
            local.append(ChatMessage(id: UUID(), senderHash: myHash, text: payloadValue.text,
                                     sentAt: .now, delivered: true,
                                     expiresAt: payloadValue.ttl.map { Date.now.addingTimeInterval($0) },
                                     mediaRef: payloadValue.mediaRef,
                                     mediaKey: payloadValue.mediaKey))
            messagesByChat[chat.id] = local
            persist()
        } catch {
            lastError = "Send failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Receive

    /// Pull new messages from every other member, in chain order.
    func refresh(_ chat: Chat, myRoot: RootIdentity) async {
        let myHash = myRoot.credentialIDHash
        let groupID = chat.id.uuidString
        for sender in chat.memberHashes where sender != myHash {
            do {
                // Receiving chain: unwrap their envelope once.
                var state = chains["recv.\(chat.id).\(sender)"]
                if state == nil {
                    guard let kemKey = identity.kemPrivateKey,
                          let envelope = try await sync.fetchKeyEnvelope(
                            groupID: groupID, senderHash: sender, recipientHash: myHash)
                    else { continue }   // they haven't sent anything yet
                    let chainKey = try HybridKEM.unwrap(envelope, with: kemKey)
                    state = ChainState(chainKey: chainKey, index: 0)
                }
                var chain = state!

                // Fetch next expected index until there are no more.
                while let wire = try await sync.fetchMessage(
                    groupID: groupID, senderHash: sender, chainIndex: chain.index) {

                    // Our own tracked prev-hash goes into the expected AAD —
                    // if the server swapped any earlier message, this (and the
                    // signature) stop matching and the transcript visibly breaks.
                    let aad = Self.messageAAD(groupID: groupID, sender: sender,
                                              index: chain.index, prevHash: chain.lastMessageHash)

                    // Full verification chain before decryption is even attempted.
                    guard let (root, endorsements) = try await directoryEntry(for: sender),
                          identity.verify(signature: wire.signature,
                                          over: wire.ciphertext + aad,
                                          deviceKey: wire.senderDevicePublicKey,
                                          claimedRoot: root,
                                          endorsements: endorsements) else {
                        lastError = "Dropped a message that failed verification."
                        Self.advance(&chain)    // skip the bad slot, don't stall the chain
                        continue
                    }

                    let (messageKey, idx) = Self.ratchet(&chain)
                    let sealedBox = try AES.GCM.SealedBox(combined: wire.ciphertext)
                    let plaintext = try AES.GCM.open(sealedBox, using: messageKey, authenticating: aad)

                    let payload = (try? JSONDecoder().decode(MessagePayload.self, from: plaintext))
                        ?? MessagePayload(text: String(decoding: plaintext, as: UTF8.self), ttl: nil)
                    var local = messagesByChat[chat.id] ?? []
                    local.append(ChatMessage(
                        id: UUID(), senderHash: sender,
                        text: payload.text,
                        sentAt: wire.sentAt, delivered: true,
                        expiresAt: payload.ttl.map { wire.sentAt.addingTimeInterval($0) },
                        mediaRef: payload.mediaRef,
                        mediaKey: payload.mediaKey))
                    messagesByChat[chat.id] = local
                    chain.lastMessageHash = Data(SHA256.hash(data: wire.ciphertext))
                    _ = idx
                }
                chains["recv.\(chat.id).\(sender)"] = chain
                persist()
            } catch {
                lastError = "Sync failed: \(error.localizedDescription)"
            }
        }
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

    private func directoryEntry(for hash: String) async throws -> (RootIdentity, [DeviceEndorsement])? {
        if let cached = directoryCache[hash] { return cached }
        guard let (root, endorsements) = try await sync.fetchIdentity(credentialIDHash: hash) else { return nil }
        let verified = IdentityManager.verifiedDevices(root: root, endorsements: endorsements)
        directoryCache[hash] = (root, verified)
        return (root, verified)
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
    }

    private func load() {
        if let data = KeychainStore.load("seal.chats.\(ownerHash)"),
           let decoded = try? JSONDecoder().decode([Chat].self, from: data) { chats = decoded }
        if let data = KeychainStore.load("seal.messages.\(ownerHash)"),
           let decoded = try? JSONDecoder().decode([UUID: [ChatMessage]].self, from: data) { messagesByChat = decoded }
        if let data = KeychainStore.load("seal.chains.\(ownerHash)"),
           let decoded = try? JSONDecoder().decode([String: ChainState].self, from: data) { chains = decoded }
    }
}
