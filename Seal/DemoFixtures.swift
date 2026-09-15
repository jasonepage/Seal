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
    /// Parent Mode screenshots (docs/UI.md §Parent Mode). Implies demo mode —
    /// one argument produces the whole screenshot state rather than requiring
    /// a pair that can be half-set. Combine with -SealDemoHideWatermark for
    /// marketing shots exactly as before.
    static let parentDemoArgument = "-SealParentDemo"

    /// Reviewer access code. Typed as the name on the registration screen, it
    /// drops into the fully-local demo account — no key, no Face ID, no
    /// network. NEVER the default: only this exact code activates it, so App
    /// Review can explore every feature without a hardware key while real users
    /// see the normal registration flow.
    static let accessCode = "SEALDEMO"

    /// Runtime activation (the access code). Session-scoped on purpose: a
    /// force-quit + relaunch without the code leaves demo via `prepare()` →
    /// `uninstallIfPresent()`, so a reviewer is never silently stuck in demo.
    private static var runtimeActive = false

    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains(demoArgument)
            || parentDemoRequested || runtimeActive
    }

    /// Read by `ParentMode.init` to force the mode on WITHOUT writing the
    /// keychain flag, so a screenshot run can never leave the setting behind.
    static var parentDemoRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(parentDemoArgument)
    }

    static var showWatermark: Bool {
        isActive && !ProcessInfo.processInfo.arguments.contains(hideWatermarkArgument)
    }

    /// Enter demo at runtime (from the access code). Seeds the local fixtures;
    /// the caller reloads the identity so the app drops into the demo account.
    static func activate() {
        runtimeActive = true
        install()
    }

    /// Leave demo (sign out / delete). Clears the runtime flag; the identity
    /// itself is removed by the caller's sign-out/reset.
    static func deactivate() {
        runtimeActive = false
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
        /// Set for a LINKED friend (docs/INTRODUCTIONS.md): the display name
        /// of the mutual friend who vouched. The fixture then carries a real
        /// `IntroductionProof`, so the silver link ring, the provenance line
        /// and the "you haven't met them" copy all render from the same field
        /// a real linked friendship uses — nothing about the tier is faked at
        /// the view layer.
        var introducedBy: String? = nil
    }

    private static let friends: [DemoFriend] = [
        DemoFriend(identity: identity("Maya", tier: .verified), forgedDaysAgo: 146),
        DemoFriend(identity: identity("Sam", tier: .verified), forgedDaysAgo: 104),
        DemoFriend(identity: identity("Alex", tier: .passkey), forgedDaysAgo: 69),
        DemoFriend(identity: identity("Mom", tier: .passkey), forgedDaysAgo: 34),
        DemoFriend(identity: identity("Dad", tier: .passkey), forgedDaysAgo: 34),
        // The introduction story, already finished: Mom is brass with both of
        // us, and vouched for Linda nine days ago.
        DemoFriend(identity: identity("Aunt Linda", tier: .passkey), forgedDaysAgo: 9,
                   introducedBy: "Mom"),
    ]

    /// People who exist in the directory but are NOT friends — the other end
    /// of the introduction that is still pending in the Mom chat.
    private static let strangers: [RootIdentity] = [
        identity("Uncle Ray", tier: .passkey)
    ]

    private static func friendIdentity(_ name: String) -> RootIdentity {
        friends.first { $0.identity.displayName == name }!.identity
    }

    /// Any demo person by root hash — friends, strangers, or the demo user.
    /// Used by `ChatEngine.demoAccept` to complete an introduction locally.
    static func person(hash: String) -> RootIdentity? {
        if hash == me.credentialIDHash { return me }
        return friends.first { $0.identity.credentialIDHash == hash }?.identity
            ?? strangers.first { $0.credentialIDHash == hash }
    }

    /// A synthetic, UNSIGNED introduction statement. Nothing in demo mode
    /// verifies anything (fixtures are trusted by construction, FR-22), so
    /// the signature is a label rather than a signature — exactly like the
    /// synthetic friendship attestations beside it.
    private static func demoStatement(introducer: RootIdentity,
                                      _ first: RootIdentity,
                                      _ second: RootIdentity,
                                      days: Int) -> IntroductionStatement {
        let pair = Introduction.canonical(
            (hash: first.credentialIDHash, publicKey: first.publicKey),
            (hash: second.credentialIDHash, publicKey: second.publicKey))
        return IntroductionStatement(
            introducerHash: introducer.credentialIDHash,
            introducerDevicePublicKey: publicKey("device.\(introducer.displayName)"),
            partyAHash: pair.a.hash, partyAPublicKey: pair.a.publicKey,
            partyBHash: pair.b.hash, partyBPublicKey: pair.b.publicKey,
            createdAtEpoch: Int64(daysAgo(days).timeIntervalSince1970),
            signature: Data("seal.demo.introduction".utf8))
    }

    private static func demoAcceptance(_ hash: String, statement: IntroductionStatement,
                                       days: Int) -> IntroductionAcceptance {
        IntroductionAcceptance(introductionCommitment: statement.commitment,
                               accepterHash: hash,
                               accepterDevicePublicKey: publicKey("device.accept.\(hash)"),
                               acceptedAtEpoch: Int64(daysAgo(days).timeIntervalSince1970),
                               signature: Data("seal.demo.acceptance".utf8))
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
        // Presentation flags too: a demo launch must render identically every
        // time, whatever a previous session toggled.
        ParentMode.wipe(ownerHash: owner)

        // Friends + forge log (FR-5/FR-6 shapes, synthetic attestations).
        let stored = friends.map { f -> FriendStore.StoredFriend in
            guard let introducerName = f.introducedBy,
                  let introducer = friends.first(where: { $0.identity.displayName == introducerName })?.identity
            else {
                return FriendStore.StoredFriend(
                    identity: f.identity,
                    friendship: Friendship(friendRootID: f.identity.credentialIDHash,
                                           attestation: Data("seal.demo.attestation".utf8),
                                           reverseAttestation: Data("seal.demo.attestation".utf8),
                                           forgedAt: daysAgo(f.forgedDaysAgo)))
            }
            let statement = demoStatement(introducer: introducer, me, f.identity,
                                          days: f.forgedDaysAgo)
            let proof = IntroductionProof(
                statement: statement,
                acceptances: [demoAcceptance(statement.partyAHash, statement: statement, days: f.forgedDaysAgo),
                              demoAcceptance(statement.partyBHash, statement: statement, days: f.forgedDaysAgo)])
            return FriendStore.StoredFriend(
                identity: f.identity,
                friendship: Friendship(friendRootID: f.identity.credentialIDHash,
                                       attestation: (try? JSONEncoder().encode(proof)) ?? Data(),
                                       reverseAttestation: nil,
                                       forgedAt: daysAgo(f.forgedDaysAgo),
                                       autoReciprocated: nil,
                                       introduction: proof))
        }
        if let data = try? JSONEncoder().encode(stored) {
            KeychainStore.save(data, for: "seal.friends.\(owner)")   // FriendStore format
        }

        let (chats, messages, readMarks) = seedConversations(owner: owner)
        if let data = try? JSONEncoder().encode(chats) {
            KeychainStore.save(data, for: "seal.chats.\(owner)")     // ChatEngine format
        }
        if let data = try? JSONEncoder().encode(messages) {
            KeychainStore.save(data, for: "seal.messages.\(owner)")  // ChatEngine format
        }
        if let data = try? JSONEncoder().encode(readMarks) {
            KeychainStore.save(data, for: "seal.readmarks.\(owner)") // ChatEngine format
        }
    }

    /// Launched without the flag: remove demo state, restore the real identity.
    private static func uninstallIfPresent() {
        guard let data = KeychainStore.load(IdentityManager.identityKey),
              (try? JSONDecoder().decode(RootIdentity.self, from: data))?.credentialIDHash == me.credentialIDHash
        else { return }
        FriendStore.wipe(ownerHash: me.credentialIDHash)
        ChatEngine.wipe(ownerHash: me.credentialIDHash)
        ParentMode.wipe(ownerHash: me.credentialIDHash)
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

    /// One scripted line. `reactions` (reactorHash → emoji) and `replyTo`
    /// (index of an earlier line in the same chat) drive the reaction pills and
    /// quoted headers in screenshots; `card` renders a Sealed Card instead of a
    /// bubble (docs/CARDS.md).
    private struct Line {
        let sender: String
        let text: String
        let minutesAgo: TimeInterval
        var reactions: [String: String]? = nil
        var replyTo: Int? = nil
        var card: SealedCard? = nil
        /// An inbound introduction card (docs/INTRODUCTIONS.md), already
        /// checked — which in demo means "trusted by construction", the same
        /// short-circuit every other fixture takes.
        var introduction: IntroductionOffer? = nil
    }

    /// The seeded Sealed Card (docs/CARDS.md), so App Review and the App Store
    /// screenshots show the feature without a hardware key or a second phone.
    ///
    /// The address is a synthetic string: bech32-shaped and in the bech32
    /// character set so it renders and chunks realistically, but not a real
    /// wallet — its checksum doesn't compute, so any wallet would reject it
    /// outright. Demo fixtures are never signed (nothing in demo mode touches
    /// the verification paths), so the card's detail sheet reports `.demo`
    /// rather than claiming a signature it doesn't have.
    private static let demoCard = SealedCard(
        cardType: .cryptoAddress,
        title: "My BTC wallet",
        value: "bc1qzr5x8g2tvdw0s3jn54khce6mua7lqpzry9x8gf",
        asset: "BTC",
        note: "Cold wallet — not the exchange one.",
        fallbackText: SealedCard.fallbackText(for: .cryptoAddress, asset: "BTC"))

    /// The second seeded card: an inbound PAYMENT INSTRUCTIONS card, which is
    /// what Parent Mode's scam-pause hangs off (docs/UI.md §Parent Mode). The
    /// crypto card above exercises the other money-request type; between them
    /// both branches are on screen without a hardware key or a second phone.
    ///
    /// Every number here is synthetic and deliberately shaped so nobody could
    /// mistake it for a live account: zero-padded, no real routing number.
    /// Multi-line on purpose — payment instructions are prose, they are never
    /// chunked, and this is the fixture that shows a value wrapping rather
    /// than truncating at accessibility sizes.
    private static let demoPaymentCard = SealedCard(
        cardType: .paymentInstructions,
        title: "Roof deposit — Northgate Roofing",
        value: "Northgate Roofing LLC\nNorthgate Credit Union\nAccount 0000 1234 5678\nRouting 000000000\nReference: PAGE-ROOF-DEPOSIT",
        asset: nil,
        note: "They gave me these at the house — half now, half when it's finished.",
        fallbackText: SealedCard.fallbackText(for: .paymentInstructions, asset: nil))

    private static func seedConversations(owner: String)
        -> ([ChatEngine.Chat], [UUID: [ChatEngine.ChatMessage]], [UUID: [String: Date]]) {

        let maya = friendIdentity("Maya").credentialIDHash
        let sam = friendIdentity("Sam").credentialIDHash
        let alex = friendIdentity("Alex").credentialIDHash
        let mom = friendIdentity("Mom").credentialIDHash
        let dad = friendIdentity("Dad").credentialIDHash
        let linda = friendIdentity("Aunt Linda").credentialIDHash
        let ray = strangers[0]
        // The third party of the walkthrough: Mom is brass with Nathan and
        // brass with Ray, and has just introduced them. This is the card the
        // Accept / Not now flow runs on with `-SealDemoMode`.
        let rayIntroduction = IntroductionOffer.verified(
            demoStatement(introducer: friendIdentity("Mom"), me, ray, days: 0),
            counterpart: ray)

        var chats: [ChatEngine.Chat] = []
        var messages: [UUID: [ChatEngine.ChatMessage]] = [:]
        var readMarks: [UUID: [String: Date]] = [:]

        func add(_ chat: ChatEngine.Chat, _ lines: [Line]) {
            chats.append(chat)
            let cid = chat.id.uuidString
            messages[chat.id] = lines.enumerated().map { i, line in
                var replyTo: String?, replyPreview: String?, replySender: String?
                if let r = line.replyTo {
                    replyTo = "demo.\(cid).\(r)"
                    replyPreview = String(lines[r].text.prefix(80))
                    replySender = lines[r].sender
                }
                return ChatEngine.ChatMessage(
                    id: UUID(), senderHash: line.sender, text: line.text,
                    sentAt: Date.now.addingTimeInterval(-line.minutesAgo * 60),
                    delivered: true,
                    expiresAt: chat.ttl.map { Date.now.addingTimeInterval($0) },
                    mediaRef: nil, mediaKey: nil,
                    kind: line.card != nil ? "card"
                        : (line.introduction != nil ? Introduction.offerKind : nil),
                    wireID: "demo.\(cid).\(i)",
                    reactions: line.reactions,
                    replyTo: replyTo, replyPreview: replyPreview, replySenderHash: replySender,
                    card: line.card,
                    proof: nil,
                    introduction: line.introduction)
            }
            // Everyone else has caught up — drives the "Read" / "Read by N" labels.
            readMarks[chat.id] = Dictionary(uniqueKeysWithValues:
                chat.memberHashes.filter { $0 != owner }.map { ($0, Date.now) })
        }

        // Group: friends planning to meet — reactions + a quote-reply in the
        // hero screenshot (the product in one frame).
        add(ChatEngine.Chat(id: UUID(), name: "cabin trip 🦭",
                            memberHashes: [owner, maya, alex, sam],
                            ttl: nil, epoch: 0, creatorHash: owner),
            [Line(sender: maya, text: "who's in for the climbing gym saturday", minutesAgo: 38),
             Line(sender: alex, text: "in. bringing my brother, he wants to get set up after",
                  minutesAgo: 31, reactions: [maya: "🔥", owner: "👍"]),
             Line(sender: owner, text: "I'll bring the spare key for him", minutesAgo: 24),
             Line(sender: sam, text: "one more of us 🦭",
                  minutesAgo: 17, reactions: [owner: "❤️", maya: "🦭"]),
             Line(sender: maya, text: "10am. don't be late nathan", minutesAgo: 6, replyTo: 2)])

        // 1:1 with disappearing messages on (FR-12 visible in the chat).
        add(ChatEngine.Chat(id: ChatEngine.pairChatID(owner, maya),
                            name: "Maya",
                            memberHashes: [owner, maya], ttl: 86_400),
            [Line(sender: maya, text: "ok the new place on 5th is actually good", minutesAgo: 47),
             Line(sender: owner, text: "told you", minutesAgo: 45),
             Line(sender: maya, text: "their oat latte >>>", minutesAgo: 25, reactions: [owner: "❤️"])])

        // Family group.
        add(ChatEngine.Chat(id: UUID(), name: "family",
                            memberHashes: [owner, mom, dad],
                            ttl: nil, epoch: 0, creatorHash: owner),
            [Line(sender: mom, text: "Dinner sunday? Grandma's coming", minutesAgo: 130),
             Line(sender: dad, text: "I'll grill", minutesAgo: 122, reactions: [owner: "👍", mom: "❤️"]),
             Line(sender: owner, text: "I'll be there at 5", minutesAgo: 118),
             Line(sender: mom, text: "Bring that photo from the lake!", minutesAgo: 112),
             Line(sender: owner, text: "dad what's the account for the roof deposit?", minutesAgo: 34),
             Line(sender: dad, text: demoPaymentCard.fallbackText, minutesAgo: 26,
                  card: demoPaymentCard)])

        // 1:1 with Mom — the introducer. Carries the pending introduction.
        add(ChatEngine.Chat(id: ChatEngine.pairChatID(owner, mom),
                            name: "Mom",
                            memberHashes: [owner, mom], ttl: nil),
            [Line(sender: mom, text: "Your uncle Ray finally got a phone that works",
                  minutesAgo: 64),
             Line(sender: owner, text: "no way", minutesAgo: 61),
             Line(sender: mom,
                  text: "Mom would like to introduce you to Uncle Ray. Update Seal to accept.",
                  minutesAgo: 58, introduction: rayIntroduction)])

        // 1:1 with the friendship an introduction already produced.
        add(ChatEngine.Chat(id: ChatEngine.pairChatID(owner, linda),
                            name: "Aunt Linda",
                            memberHashes: [owner, linda], ttl: nil),
            [Line(sender: linda, text: "Your mother says you're the one to ask about the photos",
                  minutesAgo: 210),
             Line(sender: owner, text: "sending them tonight", minutesAgo: 205,
                  reactions: [linda: "❤️"])])

        add(ChatEngine.Chat(id: ChatEngine.pairChatID(owner, alex),
                            name: "Alex",
                            memberHashes: [owner, alex], ttl: nil),
            [Line(sender: alex, text: "added two people at the meetup last night",
                  minutesAgo: 1_320, reactions: [owner: "🔥"]),
             Line(sender: owner, text: "your history is growing fast", minutesAgo: 1_290)])

        // 1:1 carrying the Sealed Card (docs/CARDS.md). The card is INBOUND on
        // purpose: the recipient's side is the one with the Copy button and the
        // full detail sheet, so this is the frame worth showing. `text` holds
        // the same fallback string the wire would carry, so the fixture matches
        // a real card byte for byte in every field the UI reads.
        add(ChatEngine.Chat(id: ChatEngine.pairChatID(owner, sam),
                            name: "Sam",
                            memberHashes: [owner, sam], ttl: nil),
            [Line(sender: sam, text: "see you saturday 🦭", minutesAgo: 2_700),
             Line(sender: owner, text: "also — what's your wallet for the gym half?", minutesAgo: 128),
             Line(sender: sam, text: demoCard.fallbackText, minutesAgo: 120, card: demoCard),
             Line(sender: owner, text: "sent 🫡", minutesAgo: 116, reactions: [sam: "👍"])])

        return (chats, messages, readMarks)
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
