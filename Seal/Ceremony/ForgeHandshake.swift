import Foundation
import CryptoKit
import os

//  ForgeHandshake.swift
//  Seal
//
//  One ceremony, both directions.
//
//  THE PROBLEM THIS SOLVES
//  ----------------------
//  The forge ceremony is one-directional. When B taps their key on A's phone,
//  A ends up holding cryptographic proof of B — and B holds nothing, because
//  B's phone was never involved. `Friendship.reverseAttestation` has been nil
//  since day one with the comment "their phone runs the mirror ceremony", which
//  meant the whole ritual had to run TWICE, once on each phone, and the second
//  run is the step everyone forgets. That doubling is the single largest source
//  of friction in onboarding.
//
//  THE FIX
//  -------
//  A's Secure Enclave device key is ALREADY endorsed by A's root WebAuthn
//  credential (SDS §2), so a device-key signature is transitively rooted in A's
//  identity and verifiable by anyone through the published endorsement chain.
//  Right after the ceremony, A signs a commitment naming both parties plus the
//  ceremony nonce and publishes it to the directory. B's phone picks it up on
//  its next refresh — B already gets a push for it, since the record reuses the
//  GroupInvite type B is subscribed to — verifies it, and completes the
//  friendship with ZERO user actions.
//
//  HONESTY ABOUT WHAT THIS PROVES (important — do not paper over this)
//  ------------------------------------------------------------------
//  A's side of the edge is unchanged: a hardware/passkey root assertion,
//  produced by a key physically present on A's phone. Full strength.
//
//  B's side is WEAKER. It proves A controls A's identity and named B, but B's
//  phone never witnessed the meeting and cannot check the nonce is fresh. It is
//  proof of intent, not proof of presence. So the friendship B stores is marked
//  `autoReciprocated = true`, and ForgeRank (docs/TRUST.md §5.1) MUST weight
//  those edges below real ceremonies — they are closer to the "vouched edge"
//  in VISION.md than to a forged one. B can always upgrade to a full edge by
//  running the ceremony properly; that overwrites this entry.
//
//  NO SCHEMA CHANGE. Reuses the existing GroupInvite record type and its
//  already-queryable `recipient` field, so nothing new has to be deployed to
//  Production. A handshake payload simply fails to decode as a GroupInvite and
//  vice versa, so the two coexist in the same query results harmlessly.
//  (Transport lives in SyncEngine.publishForgeHandshake — publicDB is private
//  to that file.)

/// A's device-signed statement: "I forged with B, at this ceremony."
struct ForgeHandshake: Codable, Hashable {
    let senderHash: String          // A — the phone that ran the ceremony
    let recipientHash: String       // B — the person who tapped their key
    let senderDevicePublicKey: Data // A's Secure Enclave signing key (x963)
    let nonce: Data                 // the ceremony nonce, binding this to that forge
    let signature: Data             // A's device-key signature, DER
    let forgedAt: Date
}

/// Publishes and completes reciprocal halves of the forge ceremony.
enum ForgeHandshakeService {
    private static let log = Logger(subsystem: "io.github.jasonepage.Seal", category: "forge")

    /// Everything A does after a successful ceremony. Best-effort and silent:
    /// the ceremony already succeeded on A's side, and B can still run the
    /// mirror ceremony the old way, so a failure here must never make a good
    /// forge look broken.
    static func publish(myRoot: RootIdentity,
                        friend: RootIdentity,
                        friendship: Friendship,
                        identity: IdentityManager,
                        sync: SyncEngine) async {
        guard !DemoFixtures.isActive else { return }
        guard let deviceKey = identity.deviceKey else {
            log.error("publish: no device key — B will have to forge manually")
            return
        }
        let devicePub = deviceKey.publicKey.x963Representation
        // Recover the nonce from the attestation we just stored, so the
        // reciprocal proof is bound to THIS ceremony rather than to a fresh,
        // meaningless random value.
        guard let attestation = try? JSONDecoder().decode(FriendshipAttestation.self,
                                                          from: friendship.attestation) else {
            log.error("publish: couldn't read the ceremony nonce")
            return
        }
        let commitment = CeremonyManager.reciprocalChallenge(
            senderHash: myRoot.credentialIDHash,
            recipientHash: friend.credentialIDHash,
            nonce: attestation.nonce)
        do {
            let signature = try deviceKey.signature(for: commitment)
            try await sync.publishForgeHandshake(ForgeHandshake(
                senderHash: myRoot.credentialIDHash,
                recipientHash: friend.credentialIDHash,
                senderDevicePublicKey: devicePub,
                nonce: attestation.nonce,
                signature: signature.derRepresentation,
                forgedAt: .now))
            log.info("publish: handshake sent to \(friend.credentialIDHash, privacy: .public)")
        } catch {
            log.error("publish: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Everything B does. Called on launch and whenever a push wakes the app.
    /// Idempotent: handshake records are never deleted, so this runs against
    /// the same records forever and must no-op once the friendship exists.
    @discardableResult
    static func check(myRoot: RootIdentity,
                      identity: IdentityManager,
                      friendStore: FriendStore,
                      sync: SyncEngine) async -> Int {
        guard !DemoFixtures.isActive else { return 0 }
        guard let payloads = try? await sync.fetchGroupInvites(
            recipientHash: myRoot.credentialIDHash) else { return 0 }

        var added = 0
        for payload in payloads {
            // Group invites share this query; they simply don't decode here.
            guard let handshake = try? JSONDecoder().decode(ForgeHandshake.self, from: payload)
            else { continue }

            // Addressed to us, and not somehow from us.
            guard handshake.recipientHash == myRoot.credentialIDHash,
                  handshake.senderHash != myRoot.credentialIDHash else { continue }

            // Already friends — including the normal case where WE ran the
            // ceremony and hold the STRONG edge. Never downgrade it.
            guard !friendStore.isFriend(handshake.senderHash) else { continue }

            // Verify against the sender's PUBLISHED endorsement chain: the
            // signing device must be one their root credential vouched for,
            // and the signature must cover a commitment naming both of us.
            guard let (senderRoot, endorsements) = try? await sync.fetchIdentity(
                    credentialIDHash: handshake.senderHash) else { continue }

            let commitment = CeremonyManager.reciprocalChallenge(
                senderHash: handshake.senderHash,
                recipientHash: handshake.recipientHash,
                nonce: handshake.nonce)

            guard identity.verify(signature: handshake.signature,
                                  over: commitment,
                                  deviceKey: handshake.senderDevicePublicKey,
                                  claimedRoot: senderRoot,
                                  endorsements: endorsements) else {
                log.error("check: handshake from \(handshake.senderHash, privacy: .public) failed verification — dropped")
                continue
            }

            // Store the WEAKER side of the edge, flagged as such. `attestation`
            // carries the handshake itself, so the claim stays re-verifiable
            // offline exactly like a real attestation.
            guard let encoded = try? JSONEncoder().encode(handshake) else { continue }
            friendStore.add(identity: senderRoot,
                            friendship: Friendship(friendRootID: handshake.senderHash,
                                                   attestation: encoded,
                                                   reverseAttestation: nil,
                                                   forgedAt: handshake.forgedAt,
                                                   autoReciprocated: true))
            added += 1
            log.info("check: auto-completed friendship with \(handshake.senderHash, privacy: .public)")
        }
        return added
    }
}
