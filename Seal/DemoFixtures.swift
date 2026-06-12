import SwiftUI
import CryptoKit

/// FR-22/23 demo fixtures (SDS §3): synthetic local state for App Store
/// screenshots and, later, App Review. Compiled in but inert unless the app
/// is launched with `-SealDemoMode` (Scheme ▸ Run ▸ Arguments Passed On Launch).
///
/// Demo mode is purely local: no CloudKit, no WebAuthn, no push. Demo
/// identities cannot befriend or message real users (FR-23) — `ChatEngine`
/// short-circuits sends so nothing ever leaves the device, and `HomeView`
/// skips identity publishing, subscriptions, and sync.
///
/// Watermark (FR-23) is on by default; add `-SealDemoHideWatermark` for
/// marketing screenshot capture.
enum DemoFixtures {
    static let demoArgument = "-SealDemoMode"
    static let hideWatermarkArgument = "-SealDemoHideWatermark"

    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains(demoArgument)
    }

    static var showWatermark: Bool {
        isActive && !ProcessInfo.processInfo.arguments.contains(hideWatermarkArgument)
    }

    // MARK: - Synthetic identities (deterministic, NOT real keys)

    /// Demo "public keys" are 64 hash bytes shaped like a P-256 raw
    /// representation. Nothing in demo mode signs or verifies — fixtures are
    /// trusted by construction and never touch the verification paths.
    private static func publicKey(_ seed: String) -> Data {
        Data(SHA256.hash(data: Data("seal.demo.pub.a.\(seed)".utf8)))
            + Data(SHA256.hash(data: Data("seal.demo.pub.b.\(seed)".utf8)))
    }

    private static func hashString(_ seed: String) -> String {
        SHA256.hash(data: Data("seal.demo.id.\(seed)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func identity(_ name: String, tier: IdentityTier) -> RootIdentity {
        RootIdentity(credentialIDHash: hashString(name), publicKey: publicKey(name),
                     tier: tier, displayName: name, rawCredentialID: nil)
    }

    static let me = identity("Nathan", tier: .verified)

    private struct DemoFriend {
        let identity: RootIdentity
        let forgedDaysAgo: Int
    }

    private static let friends: [DemoFriend] = [
        DemoFriend(identity: identity("Maya", tier: .verified), forgedDaysAgo: 146),
        DemoFriend(identity: identity("Sam", tier: .verified), forgedDaysAgo: 104),
        DemoFriend(identity: identity("Alex", tier: .passkey), forgedDaysAgo: 69),
        DemoFriend(identity: identity("Mom", tier: .passkey), forgedDaysAgo: 34),
        DemoFriend(identity: identity("Dad", tier: .passkey), forgedDaysAgo: 34),
    ]

    private static func friendIdentity(_ name: String) -> RootIdentity {
        friends.first { $0.identity.displayName == name }!.identity
    }

    // MARK: - Install / uninstall

    /// Call from `SealApp.init`, BEFORE any view (and therefore any store)
    /// is created. Rebuilds fixtures fresh on every demo launch so
    /// screenshots are deterministic; restores the real identity when the
    /// app is next launched without the flag.
    static func prepare() {
        if isActive { install() } else { uninstallIfPresent() }
    }

    private static let backupIdentityKey = "seal.demo.backup.rootIdentity"
    private static let backupEndorsementKey = "seal.demo.backup.deviceEndorsement"

    private static func install() {
        // Park any real identity so demo mode is non-destructive.
        if let real = KeychainStore.load(IdentityManager.identityKey),
           (try? JSONDecoder().decode(RootIdentity.self, from: real))?.credentialIDHash != me.credentialIDHash {
            KeychainStore.save(real, for: backupIdentityKey)
            if let endorsement = KeychainStore.load(IdentityManager.endorsementKey) {
                KeychainStore.save(endorsement, for: backupEndorsementKey)
            }
        }
        KeychainStore.delete(IdentityManager.endorsementKey)
        if let data = try? JSONEncoder().encode(me) {
            KeychainStore.save(data, for: IdentityManager.identityKey)
        }

        // Fresh, deterministic state every launch.
        let owner = me.credentialIDHash
        FriendStore.wipe(ownerHash: owner)
        ChatEngine.wipe(ownerHash: owner)

        // Friends + forge log (FR-5/FR-6 shapes, synthetic attestations).
        let stored = friends.map { f in
            FriendStore.StoredFriend(
                identity: f.identity,
                friendship: Friendship(friendRootID: f.identity.credentialIDHash,
                                       attestation: Data("seal.demo.attestation".utf8),
                                       reverseAttestation: Data("seal.demo.attestation".utf8),
                                       forgedAt: daysAgo(f.forgedDaysAgo)))
        }
        if let data = try? JSONEncoder().encode(stored) {
            KeychainStore.save(data, for: "seal.friends.\(owner)")   // FriendStore format
        }

        let (chats, messages) = seedConversations(owner: owner)
        if let data = try? JSONEncoder().encode(chats) {
            KeychainStore.save(data, for: "seal.chats.\(owner)")     // ChatEngine format
        }
        if let data = try? JSONEncoder().encode(messages) {
            KeychainStore.save(data, for: "seal.messages.\(owner)")  // ChatEngine format
        }
    }

    /// Launched without the flag: remove demo state, restore the real identity.
    private static func uninstallIfPresent() {
        guard let data = KeychainStore.load(IdentityManager.identityKey),
              (try? JSONDecoder().decode(RootIdentity.self, from: data))?.credentialIDHash == me.credentialIDHash
        else { return }
        FriendStore.wipe(ownerHash: me.credentialIDHash)
        ChatEngine.wipe(ownerHash: me.credentialIDHash)
        KeychainStore.delete(IdentityManager.identityKey)
        if let real = KeychainStore.load(backupIdentityKey) {
            KeychainStore.save(real, for: IdentityManager.identityKey)
            KeychainStore.delete(backupIdentityKey)
        }
        if let endorsement = KeychainStore.load(backupEndorsementKey) {
            KeychainStore.save(endorsement, for: IdentityManager.endorsementKey)
            KeychainStore.delete(backupEndorsementKey)
        }
    }

    // MARK: - Conversations

    private static func seedConversations(owner: String)
        -> ([ChatEngine.Chat], [UUID: [ChatEngine.ChatMessage]]) {

        let maya = friendIdentity("Maya"), sam = friendIdentity("Sam")
        let alex = friendIdentity("Alex"), mom = friendIdentity("Mom")
        let dad = friendIdentity("Dad")

        var chats: [ChatEngine.Chat] = []
        var messages: [UUID: [ChatEngine.ChatMessage]] = [:]

        func add(_ chat: ChatEngine.Chat, _ lines: [(String, String, TimeInterval)]) {
            chats.append(chat)
            messages[chat.id] = lines.map { senderHash, text, minutesAgo in
                ChatEngine.ChatMessage(
                    id: UUID(), senderHash: senderHash, text: text,
                    sentAt: Date.now.addingTimeInterval(-minutesAgo * 60),
                    delivered: true,
                    expiresAt: chat.ttl.map { Date.now.addingTimeInterval($0) },
                    mediaRef: nil, mediaKey: nil)
            }
        }

        // Group: friends planning to meet (the product in one screenshot).
        add(ChatEngine.Chat(id: UUID(), name: "haul out 🦭",
                            memberHashes: [owner, maya.credentialIDHash, alex.credentialIDHash, sam.credentialIDHash],
                            ttl: nil, epoch: 0, creatorHash: owner),
            [(maya.credentialIDHash, "who's in for the climbing gym saturday", 38),
             (alex.credentialIDHash, "in. bringing my brother — he wants his ring forged after", 31),
             (owner, "I'll bring the spare key for him", 24),
             (sam.credentialIDHash, "another one joins the colony 🦭", 17),
             (maya.credentialIDHash, "10am. don't be late nathan", 6)])

        // 1:1 with disappearing messages on (FR-12 visible in the chat).
        add(ChatEngine.Chat(id: ChatEngine.pairChatID(owner, maya.credentialIDHash),
                            name: "Maya",
                            memberHashes: [owner, maya.credentialIDHash], ttl: 86_400),
            [(maya.credentialIDHash, "ok the new place on 5th is actually good", 47),
             (owner, "told you", 45),
             (maya.credentialIDHash, "their oat latte >>>", 25)])

        // Family group.
        add(ChatEngine.Chat(id: UUID(), name: "family",
                            memberHashes: [owner, mom.credentialIDHash, dad.credentialIDHash],
                            ttl: nil, epoch: 0, creatorHash: owner),
            [(mom.credentialIDHash, "Dinner sunday? Grandma's coming", 130),
             (dad.credentialIDHash, "I'll grill", 122),
             (owner, "I'll be there at 5", 118),
             (mom.credentialIDHash, "Bring that photo from the lake!", 112)])

        add(ChatEngine.Chat(id: ChatEngine.pairChatID(owner, alex.credentialIDHash),
                            name: "Alex",
                            memberHashes: [owner, alex.credentialIDHash], ttl: nil),
            [(alex.credentialIDHash, "forged with two people at the meetup last night", 1_320),
             (owner, "your forge log is growing fast", 1_290)])

        add(ChatEngine.Chat(id: ChatEngine.pairChatID(owner, sam.credentialIDHash),
                            name: "Sam",
                            memberHashes: [owner, sam.credentialIDHash], ttl: nil),
            [(sam.credentialIDHash, "see you saturday 🦭", 2_700)])

        return (chats, messages)
    }

    private static func daysAgo(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .now
    }
}

/// FR-23: demo sessions are visually watermarked. Non-interactive overlay.
struct DemoWatermark: View {
    var body: some View {
        Text("DEMO")
            .font(.system(.caption2, design: .rounded, weight: .heavy))
            .tracking(1.5)
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.orange.opacity(0.85), in: Capsule())
            .padding(.top, 4)
            .padding(.trailing, 12)
            .allowsHitTesting(false)
    }
}
