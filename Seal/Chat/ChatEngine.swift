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
    }

    struct ChatMessage: Codable, Identifiable, Hashable {
        let id: UUID
        let senderHash: String
        let text: String
        let sentAt: Date
        var delivered: Bool             // round-tripped through CloudKit
    }

    private struct ChainState: Codable {
        var chainKey: Data
        var index: UInt64
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

    init(identity: IdentityManager, sync: SyncEngine) {
        self.identity = identity
        self.sync = sync
        load()
    }

    // MARK: - Chats

    func ensureChat(with friend: RootIdentity, myHash: String) -> Chat {
        if let existing = chats.first(where: {
            Set($0.memberHashes) == Set([myHash, friend.credentialIDHash])
        }) { return existing }
        let chat = Chat(id: UUID(), name: friend.displayName,
                        memberHashes: [myHash, friend.credentialIDHash])
        chats.append(chat)
        persist()
        return chat
    }

    func ensureNoteToSelf(myHash: String) -> Chat {
        if let existing = chats.first(where: { $0.memberHashes == [myHash] }) { return existing }
        let chat = Chat(id: UUID(), name: "Note to self", memberHashes: [myHash])
        chats.append(chat)
        persist()
        return chat
    }

    func messages(for chat: Chat) -> [ChatMessage] {
        (messagesByChat[chat.id] ?? []).sorted { $0.sentAt < $1.sentAt }
    }

    // MARK: - Send

    func send(_ text: String, in chat: Chat, from myRoot: RootIdentity) async {
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

            // 3. Encrypt. AAD binds group, sender, and index (SDS §2).
            let aad = Data("seal.msg.v1|\(groupID)|\(myHash)|\(index)".utf8)
            let sealed = try AES.GCM.seal(Data(text.utf8), using: messageKey, authenticating: aad)
            let ciphertext = sealed.combined!

            // 4. Sign ciphertext‖aad with the Secure Enclave device key.
            let signature = try deviceKey.signature(for: ciphertext + aad)

            // 5. Ship it.
            try await sync.saveMessage(
                groupID: groupID, senderHash: myHash, chainIndex: index,
                message: .init(ciphertext: ciphertext,
                               senderDevicePublicKey: devicePub,
                               signature: signature.derRepresentation,
                               sentAt: .now))

            chains["send.\(chat.id)"] = state
            var local = messagesByChat[chat.id] ?? []
            local.append(ChatMessage(id: UUID(), senderHash: myHash, text: text,
                                     sentAt: .now, delivered: true))
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

                    let aad = Data("seal.msg.v1|\(groupID)|\(sender)|\(chain.index)".utf8)

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

                    var local = messagesByChat[chat.id] ?? []
                    local.append(ChatMessage(
                        id: UUID(), senderHash: sender,
                        text: String(decoding: plaintext, as: UTF8.self),
                        sentAt: wire.sentAt, delivered: true))
                    messagesByChat[chat.id] = local
                    _ = idx
                }
                chains["recv.\(chat.id).\(sender)"] = chain
                persist()
            } catch {
                lastError = "Sync failed: \(error.localizedDescription)"
            }
        }
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
        if let data = try? JSONEncoder().encode(chats) { KeychainStore.save(data, for: "seal.chats") }
        if let data = try? JSONEncoder().encode(messagesByChat) { KeychainStore.save(data, for: "seal.messages") }
        if let data = try? JSONEncoder().encode(chains) { KeychainStore.save(data, for: "seal.chains") }
    }

    private func load() {
        if let data = KeychainStore.load("seal.chats"),
           let decoded = try? JSONDecoder().decode([Chat].self, from: data) { chats = decoded }
        if let data = KeychainStore.load("seal.messages"),
           let decoded = try? JSONDecoder().decode([UUID: [ChatMessage]].self, from: data) { messagesByChat = decoded }
        if let data = KeychainStore.load("seal.chains"),
           let decoded = try? JSONDecoder().decode([String: ChainState].self, from: data) { chains = decoded }
    }
}
