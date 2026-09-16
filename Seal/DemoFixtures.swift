// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import CryptoKit

/// FR-22/23 demo fixtures: synthetic local state for App Store screenshots
/// and App Review. Compiled in but inert unless the app is launched with
/// `-SealDemoMode` or the reviewer types the access code as their name.
///
/// Demo mode is purely local: no CloudKit, no WebAuthn, no push. Demo
/// identities cannot reach real users (FR-23): `EstateEngine` refuses to
/// publish, heartbeat or refresh while demo is active, and `HomeView` skips
/// identity publishing, subscriptions and sync.
///
/// What it seeds: the story from the brief. Nathan, 58, four envelopes on a
/// Sunday night, three custodians (wife, brother, attorney), any two to open
/// after 90 days of silence.
///
/// Watermark (FR-23) is on by default; add `-SealDemoHideWatermark` for
/// marketing screenshot capture.
enum DemoFixtures {
    static let demoArgument = "-SealDemoMode"
    static let hideWatermarkArgument = "-SealDemoHideWatermark"
    /// Bigger text screenshots. Implies demo mode.
    static let parentDemoArgument = "-SealParentDemo"

    /// Reviewer access code. Typed as the name on the registration screen, it
    /// drops into the fully local demo account with no key, no Face ID and no
    /// network. NEVER the default: only this exact code activates it.
    static let accessCode = "SEALDEMO"

    private static var runtimeActive = false

    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains(demoArgument)
            || parentDemoRequested || runtimeActive
    }

    static var parentDemoRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(parentDemoArgument)
    }

    static var showWatermark: Bool {
        isActive && !ProcessInfo.processInfo.arguments.contains(hideWatermarkArgument)
    }

    static func activate() {
        runtimeActive = true
        install()
    }

    static func deactivate() {
        runtimeActive = false
    }

    // MARK: - Synthetic identities (deterministic, NOT real keys)

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
        DemoFriend(identity: identity("Karen", tier: .verified), forgedDaysAgo: 146),
        DemoFriend(identity: identity("Dave", tier: .verified), forgedDaysAgo: 104),
        DemoFriend(identity: identity("Ruth Ellison", tier: .verified), forgedDaysAgo: 69),
        DemoFriend(identity: identity("Emma", tier: .passkey), forgedDaysAgo: 34),
        DemoFriend(identity: identity("Jason", tier: .passkey), forgedDaysAgo: 34),
        DemoFriend(identity: identity("Marco", tier: .passkey), forgedDaysAgo: 20),
    ]

    private static func friendIdentity(_ name: String) -> RootIdentity {
        friends.first { $0.identity.displayName == name }!.identity
    }

    static func person(hash: String) -> RootIdentity? {
        if hash == me.credentialIDHash { return me }
        return friends.first { $0.identity.credentialIDHash == hash }?.identity
    }

    // MARK: - Install / uninstall

    static func prepare() {
        if isActive { install() } else { uninstallIfPresent() }
    }

    private static let backupIdentityKey = "seal.demo.backup.rootIdentity"
    private static let backupEndorsementKey = "seal.demo.backup.deviceEndorsement"

    private static func install() {
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

        let owner = me.credentialIDHash
        FriendStore.wipe(ownerHash: owner)
        EstateEngine.wipe(ownerHash: owner)
        ParentMode.wipe(ownerHash: owner)

        let stored = friends.map { f in
            FriendStore.StoredFriend(
                identity: f.identity,
                friendship: Friendship(friendRootID: f.identity.credentialIDHash,
                                       attestation: Data("seal.demo.attestation".utf8),
                                       reverseAttestation: Data("seal.demo.attestation".utf8),
                                       forgedAt: daysAgo(f.forgedDaysAgo)))
        }
        if let data = try? JSONEncoder().encode(stored) {
            KeychainStore.save(data, for: "seal.friends.\(owner)")
        }
        EstateStore.save(seedEstate(owner: owner))
    }

    private static func uninstallIfPresent() {
        guard let data = KeychainStore.load(IdentityManager.identityKey),
              (try? JSONDecoder().decode(RootIdentity.self, from: data))?.credentialIDHash == me.credentialIDHash
        else { return }
        FriendStore.wipe(ownerHash: me.credentialIDHash)
        EstateEngine.wipe(ownerHash: me.credentialIDHash)
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

    // MARK: - The estate

    /// Four envelopes, three custodians, the default rule. Sealed locally so
    /// the screens render their "sealed" state; nothing is published.
    private static func seedEstate(owner: String) -> Estate {
        let now = Clocks.current.now
        var estate = Estate.new(ownerHash: owner, now: daysAgo(12))
        estate.policy = ReleasePolicy(threshold: 2)
        let karen = friendIdentity("Karen"), dave = friendIdentity("Dave"), ruth = friendIdentity("Ruth Ellison")
        let emma = friendIdentity("Emma"), jason = friendIdentity("Jason"), marco = friendIdentity("Marco")
        estate.custodians = [
            Custodian(rootHash: karen.credentialIDHash, displayName: "Karen", addedAt: daysAgo(12), handoverReceiptID: nil),
            Custodian(rootHash: dave.credentialIDHash, displayName: "Dave", addedAt: daysAgo(12), handoverReceiptID: nil),
            Custodian(rootHash: ruth.credentialIDHash, displayName: "Ruth Ellison", addedAt: daysAgo(11), handoverReceiptID: nil),
        ]
        estate.recipients = [karen, emma, jason, marco].map { Recipient(rootHash: $0.credentialIDHash, displayName: $0.displayName) }

        func envelope(_ to: RootIdentity, _ title: String, _ letter: String, _ secrets: [SealedCard], order: Int) -> Envelope {
            var e = Envelope.new(recipientHash: to.credentialIDHash, title: title, now: daysAgo(12), revealOrder: order)
            e.letter = letter
            e.secrets = secrets
            e.sealed = true
            e.payloadBlobID = UUID().uuidString
            e.updatedAt = now
            return e
        }
        estate.envelopes = [
            envelope(karen, "Everything you need",
                     "Karen, if you are reading this then the boring part of my life is now your problem, and I am sorry. Everything is in here. Start with the passwords, then the drawer in the study.",
                     [
                        try! SealedCard.validated(cardType: .password, title: "Password manager", value: "Bitwarden, user nathan@page.family, master phrase: correct horse battery staple 1967"),
                        try! SealedCard.validated(cardType: .location, title: "The documents", value: "Bottom drawer of the study desk, brown accordion file. Deed, insurance, the will. The safe deposit key is taped inside the front cover."),
                        try! SealedCard.validated(cardType: .combination, title: "Gun safe", value: "38-12-77"),
                     ], order: 1),
            envelope(emma, "For Emma", "Em, you were the bravest of us and you still are. I have watched you decide things I never could. Do not let anyone talk you out of the garden.", [], order: 1),
            envelope(jason, "For Jason", "Jay, you built things I did not understand and I was proud of every one of them. Keep building. Your mother needs you to be patient with her about the computer.", [], order: 1),
            envelope(marco, "The domain and the registrar",
                     "Marco, the business is yours to wind down or keep. The domain renews in March.",
                     [try! SealedCard.validated(cardType: .password, title: "Registrar login", value: "Porkbun, user pagehardware, password Maple!Street!2214")],
                     order: 1),
        ]
        estate.epoch = 1
        estate.epochPublished = true
        estate.publishedCustodianHashes = estate.custodians.map(\.rootHash)
        estate.publishedThreshold = 2
        return estate
    }

    private static func daysAgo(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: Clocks.current.now) ?? Clocks.current.now
    }
}

/// FR-23: demo sessions are visually watermarked. Non-interactive, and it is
/// placed in a reserved strip along the bottom edge (ContentView), never over
/// the toolbar, so it hides no button.
struct DemoWatermark: View {
    var body: some View {
        Text("DEMO")
            .font(.system(.caption2, design: .rounded, weight: .heavy))
            .tracking(1.5)
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.orange.opacity(0.85), in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .padding(.bottom, 2)
            .allowsHitTesting(false)
    }
}
