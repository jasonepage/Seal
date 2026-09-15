import Foundation
import AuthenticationServices
import CryptoKit
import UIKit
import os   // Logger interpolation (privacy:) resolves at the call site

/// Drives the three tap ceremonies (SDS §5): registration, friend forge, device add.
/// UI choreography spec: docs/UI.md §3.1–3.2.
@Observable
final class CeremonyManager: NSObject {
    /// State machine backing the ceremony UI (UI.md §4).
    enum Phase: Equatable {
        case idle
        case searching      // NFC coaching sheet up / Face ID prompt
        case reading        // key detected, assertion in flight
        case endorsing      // second tap: hardware key vouches for this device
        case sealed         // success — play brass seal animation
        case failed(String) // plain-language reason, one-tap retry
    }

    private(set) var phase: Phase = .idle

    /// WebAuthn RP ID — must match the AASA file served at this domain (SDS §6).
    static let relyingPartyID = "sealmessenger.com"

    let identity: IdentityManager
    private var continuation: CheckedContinuation<ASAuthorizationCredential, Error>?

    init(identity: IdentityManager) {
        self.identity = identity
    }

    enum CeremonyError: LocalizedError {
        case cancelled
        case unexpectedCredential
        case keyUnreadable
        case verificationFailed
        case missingCredentialID
        case identityNotFound
        case identityDeleted
        case alreadyRegistered
        case directoryUnavailable
        case directoryEmpty

        var errorDescription: String? {
            switch self {
            case .cancelled: "The ceremony was cancelled. Tap to try again."
            case .unexpectedCredential: "That wasn't the response we expected. Tap to try again."
            case .keyUnreadable: "Couldn't read the key's response. Try holding it still against the top of your phone."
            case .verificationFailed: "That key doesn't match this person's identity. You were NOT connected."
            case .missingCredentialID: "This person registered before credential publishing — they need to update their identity."
            case .identityNotFound: "No identity in the directory matches that key. Register instead?"
            case .identityDeleted: "This identity was permanently deleted and can't be restored. Register a new one instead."
            case .alreadyRegistered: "This key already holds a Seal identity — one key, one identity. Use \"Sign in\" instead."
            case .directoryUnavailable: "Couldn't reach the identity directory to look up your key. Check your connection and iCloud sign-in, then tap to try again."
            case .directoryEmpty: "No identities are published in the directory yet, so there's nothing for your security key to match. (If you just registered, give iCloud a moment to sync — or the Identity record type may not be Queryable in this CloudKit environment.)"
            }
        }
    }

    // MARK: - Registration (U1, FR-1/FR-2/FR-21)

    /// Creates the root credential (hardware key or passkey), then a Secure
    /// Enclave device key, then asks the root credential to sign an
    /// endorsement committing to the device key (SDS §2).
    func register(tier: IdentityTier, displayName: String, directory: SyncEngine? = nil) async throws -> RootIdentity {
        phase = .searching
        do {
            // 0. One key ≈ one identity: exclude every credential ID already
            //    in the directory, so an authenticator that minted a Seal
            //    identity refuses to mint another (the authenticator itself
            //    recognizes its own credential IDs, even non-discoverable
            //    ones). Best-effort by design: directory unreachable →
            //    proceed; deterrence, not an invariant (SDS §7).
            // Best-effort by design (deterrence, not an invariant), but log
            // the outcome: if this query fails or returns 0 here, security-key
            // SIGN-IN will also come up empty (same query), which is the usual
            // root cause of a "No Credentials" sign-in — Identity not Queryable
            // in this CloudKit environment, or iCloud unreachable.
            var excluded: [Data] = []
            do {
                excluded = try await directory?.fetchAllCredentialIDs() ?? []
                WebAuthnDiag.log.info("register: directory exclusion query returned \(excluded.count, privacy: .public) credential ID(s)")
            } catch {
                WebAuthnDiag.log.error("register: directory exclusion query FAILED (sign-in by key will also fail): \(error.localizedDescription, privacy: .public)")
            }

            // 1. Create the root WebAuthn credential.
            let challenge = Self.randomChallenge()
            let userID = Self.randomChallenge(16)
            let registration = try await performRequest(
                makeRegistrationRequest(tier: tier, name: displayName, challenge: challenge,
                                        userID: userID, excluding: excluded)
            ) as? ASAuthorizationPublicKeyCredentialRegistration
            guard let registration, let attestation = registration.rawAttestationObject else {
                throw CeremonyError.unexpectedCredential
            }
            phase = .reading

            // 2. Extract the root public key from the attestation object.
            let parsed = try WebAuthnParsing.parseRegistration(attestationObject: attestation)
            let root = RootIdentity(
                credentialIDHash: Data(SHA256.hash(data: registration.credentialID)).hexString,
                publicKey: parsed.publicKey.rawRepresentation,
                tier: tier,
                displayName: displayName,
                rawCredentialID: registration.credentialID
            )

            // 3. Create this device's Secure Enclave signing key (scoped to
            //    the new identity).
            let deviceKey = try identity.createDeviceKey(for: root.credentialIDHash)
            let devicePub = deviceKey.publicKey.x963Representation

            // 4. Endorsement: root credential signs a challenge committing to
            //    BOTH the signing key and the KEM key — binding authentication
            //    and encryption together. Committing to only the signing key
            //    would let a tampered directory swap the KEM key and MITM
            //    every sender-key envelope.
            phase = .endorsing
            let kemPub = identity.kemPublicKeyData ?? Data()
            let commitment = IdentityManager.endorsementCommitment(
                devicePublicKey: devicePub, kemBundlePublicKeys: kemPub)
            let assertion = try await performRequest(
                makeAssertionRequest(tier: tier, challenge: commitment, allowedCredentialID: registration.credentialID)
            ) as? ASAuthorizationPublicKeyCredentialAssertion
            guard let assertion else { throw CeremonyError.unexpectedCredential }

            let stored = WebAuthnAssertion(
                credentialID: assertion.credentialID,
                clientDataJSON: assertion.rawClientDataJSON,
                authenticatorData: assertion.rawAuthenticatorData,
                signature: assertion.signature
            )
            let endorsement = DeviceEndorsement(
                devicePublicKey: devicePub,
                kemBundlePublicKeys: identity.kemPublicKeyData ?? Data(),
                assertion: try JSONEncoder().encode(stored),
                createdAt: .now
            )

            // 5. Persist locally.
            identity.completeRegistration(identity: root, endorsement: endorsement)

            // 6. Publish to the directory NOW, as part of registration — not
            //    deferred to HomeView's .task. A security-key account that
            //    isn't in the directory cannot be signed back into (sign-in
            //    builds its allow-list from the directory), so a lazy publish
            //    that was skipped (status-gated) or cancelled (user navigated
            //    away / signed out before the CloudKit save finished) looked
            //    like "sign-out deleted my account." Publishing here guarantees
            //    the record exists before the user can leave this screen.
            //    Best-effort: if offline, HomeView's .task republishes later.
            if let directory {
                await directory.publishIdentity(root, endorsement: endorsement)
                WebAuthnDiag.log.info("register: published identity to directory (hash=\(root.credentialIDHash, privacy: .public))")
            } else {
                WebAuthnDiag.log.error("register: no directory handle — identity NOT published (key sign-in will fail until it syncs)")
            }
            phase = .sealed
            SealTheme.sealHaptic()
            return root
        } catch let error as ASAuthorizationError where error.code == .canceled {
            phase = .failed(CeremonyError.cancelled.localizedDescription)
            throw CeremonyError.cancelled
        } catch let error as ASAuthorizationError where error.code == .matchedExcludedCredential {
            phase = .failed(CeremonyError.alreadyRegistered.localizedDescription)
            throw CeremonyError.alreadyRegistered
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "Something went wrong. Tap to try again.")
            throw error
        }
    }

    func resetPhase() { phase = .idle }

    /// Drive the ceremony state machine from a ceremony defined in an
    /// extension in another file (FR-3 backup keys — BackupKeyCeremony.swift).
    /// `phase` stays `private(set)` so the only way to move it from outside
    /// this file is this deliberate, greppable call rather than an assignment
    /// anywhere in the module.
    func setPhase(_ phase: Phase) { self.phase = phase }

    /// Reviewer/demo access: enter the fully-local demo account (no ceremony,
    /// no key). Triggered only by the access code in RegistrationView.
    func activateDemo() { identity.activateDemo() }

    // MARK: - Sign in (existing identity, this or a new device)

    /// Assert with an existing credential for our RP, look the identity up in
    /// the directory, verify the assertion against its public key, then endorse
    /// THIS device with a second tap. Chats/friends are device-local and do
    /// not follow the identity — the UI says so.
    ///
    /// `tier` selects the method explicitly. We do NOT bundle the passkey and
    /// security-key providers into one request: with both present iOS jumps
    /// straight to the security-key (NFC/USB) modal instead of offering Face
    /// ID, which broke passkey sign-in. The caller asks the user which they
    /// have and we fire exactly one provider.
    func signIn(directory: SyncEngine, tier: IdentityTier) async throws -> RootIdentity {
        phase = .searching
        do {
            // 1. Who are you? One provider only, chosen by `tier`.
            let challenge = Self.randomChallenge()
            let request: ASAuthorizationRequest
            switch tier {
            case .passkey:
                // Passkeys are discoverable: empty allow-list → the system
                // shows every passkey for this RP and authenticates via Face ID.
                let platform = ASAuthorizationPlatformPublicKeyCredentialProvider(
                    relyingPartyIdentifier: Self.relyingPartyID)
                request = platform.createCredentialAssertionRequest(challenge: challenge)
            case .verified:
                // Security-key credentials are NON-discoverable (registration
                // mints them with residentKey .discouraged to dodge the CTAP2
                // PIN ceremony), so an empty allow-list finds nothing. Instead
                // we hand the request EVERY credentialID published in the
                // directory: a non-resident authenticator recognizes its own
                // credential when its ID is in the allow-list (the credential
                // is key-wrapped into the ID), so it asserts without being
                // discoverable and without the PIN ceremony. Directory
                // unreachable → empty list → the key has nothing to match,
                // surfaced as identityNotFound below (SDS §7).
                let security = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(
                    relyingPartyIdentifier: Self.relyingPartyID)
                let securityRequest = security.createCredentialAssertionRequest(challenge: challenge)
                // .preferred, not .discouraged — see makeRegistrationRequest.
                // A PIN'd key forces UV via always_uv; .discouraged would put
                // iOS and the key in the "wrong PIN" conflict. Pinless keys are
                // unaffected (.preferred prompts only when a PIN is set).
                securityRequest.userVerificationPreference = .preferred
                // Build the allow-list from the directory. Do NOT swallow a
                // fetch failure into an empty list: an empty allow-list makes
                // iOS report the key's generic "No Credentials" error, which
                // masks the real cause (directory unreachable, or the Identity
                // record type isn't Queryable in this CloudKit environment).
                // Distinguish the two and fail with an honest message.
                let directoryCredentialIDs: [Data]
                do {
                    directoryCredentialIDs = try await directory.fetchAllCredentialIDs()
                } catch {
                    WebAuthnDiag.log.error("signIn(.verified): directory fetch FAILED: \(error.localizedDescription, privacy: .public)")
                    throw CeremonyError.directoryUnavailable
                }
                WebAuthnDiag.log.info("signIn(.verified): directory returned \(directoryCredentialIDs.count, privacy: .public) credential ID(s)")
                guard !directoryCredentialIDs.isEmpty else {
                    throw CeremonyError.directoryEmpty
                }
                securityRequest.allowedCredentials = directoryCredentialIDs.map {
                    ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor(
                        credentialID: $0,
                        transports: ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport.allSupported)
                }
                request = securityRequest
            }
            let credential = try await performRequest(request)
            guard let assertion = credential as? ASAuthorizationPublicKeyCredentialAssertion else {
                throw CeremonyError.unexpectedCredential
            }
            phase = .reading

            // 2. Directory lookup by credential hash. The tapped credential
            //    may be the identity's ROOT credential or one of its BACKUP
            //    credentials (FR-3) — `resolveSignInCredential` handles both,
            //    checks the tombstone on whichever identity would be
            //    recovered, and hands back the public key this particular tap
            //    must verify against. Permanently-deleted identities refuse
            //    sign-in even if their Identity record was revived during a
            //    CloudKit propagation window: the write-once tombstone is
            //    authoritative.
            let hash = Data(SHA256.hash(data: assertion.credentialID)).hexString
            let resolved = try await directory.resolveSignInCredential(credentialIDHash: hash)
            let root = resolved.root

            // 3. Verify the assertion against the directory's published key
            //    for THAT credential — proves the tapper controls the
            //    credential they're claiming. For a backup key this is the
            //    backup's own public key; checking it against the root's would
            //    fail every time, since a backup credential signs with its own
            //    key and is authorised by the root's separate `seal.backup.v1`
            //    endorsement (already verified inside resolve).
            let stored = WebAuthnAssertion(
                credentialID: assertion.credentialID,
                clientDataJSON: assertion.rawClientDataJSON,
                authenticatorData: assertion.rawAuthenticatorData,
                signature: assertion.signature)
            guard stored.verify(with: resolved.publicKey),
                  Self.clientDataChallengeMatches(stored.clientDataJSON, expected: challenge) else {
                throw CeremonyError.verificationFailed
            }
            if resolved.backup != nil {
                WebAuthnDiag.log.info("signIn: recovering identity via a backup credential")
            }

            // 4. Endorse this device. REUSE this phone's existing key for this
            //    identity if it survived a prior sign-out — that keeps the
            //    device public key stable so the directory recognizes the same
            //    device instead of logging a duplicate. Only a genuinely new
            //    phone mints a fresh key here.
            let deviceKey = try identity.loadOrCreateDeviceKey(for: root.credentialIDHash)
            let devicePub = deviceKey.publicKey.x963Representation
            phase = .endorsing
            let kemPub = identity.kemPublicKeyData ?? Data()
            let commitment = IdentityManager.endorsementCommitment(
                devicePublicKey: devicePub, kemBundlePublicKeys: kemPub)
            // Endorse with the SAME provider used to identify — passing both
            // would re-trigger the NFC modal for passkey users — and with the
            // SAME credential that just asserted. That second part is what
            // makes FR-3 recovery actually work: sign in on a new phone with a
            // BACKUP key and the endorsement this device gets is signed by the
            // backup, which peers accept because `verifiedDevices` verifies
            // against the whole authority set rather than the root alone.
            let endorseCredential = try await performRequest(
                makeAssertionRequest(tier: tier, challenge: commitment, allowedCredentialID: assertion.credentialID))
            guard let endorseAssertion = endorseCredential as? ASAuthorizationPublicKeyCredentialAssertion else {
                throw CeremonyError.unexpectedCredential
            }
            let endorsement = DeviceEndorsement(
                devicePublicKey: devicePub,
                kemBundlePublicKeys: kemPub,
                assertion: try JSONEncoder().encode(WebAuthnAssertion(
                    credentialID: endorseAssertion.credentialID,
                    clientDataJSON: endorseAssertion.rawClientDataJSON,
                    authenticatorData: endorseAssertion.rawAuthenticatorData,
                    signature: endorseAssertion.signature)),
                createdAt: .now)

            identity.completeRegistration(identity: root, endorsement: endorsement)
            // Recovered with a backup key? Remember it (FR-3). Recorded HERE,
            // after the assertion verified and the device endorsement exists,
            // never at resolution time — a resolution that fails verification
            // or a ceremony the user abandons must not leave this phone
            // telling its owner their main key is gone when it isn't.
            if resolved.backup != nil {
                RecoveryNotice.record(ownerHash: root.credentialIDHash)
            }
            // Publish the appended endorsement immediately (same reasoning as
            // registration step 6): don't rely on a deferred view task that can
            // be skipped or cancelled before the CloudKit save lands.
            await directory.publishIdentity(root, endorsement: endorsement)
            WebAuthnDiag.log.info("signIn: published appended endorsement (hash=\(root.credentialIDHash, privacy: .public))")
            phase = .sealed
            SealTheme.sealHaptic()
            return root
        } catch let error as ASAuthorizationError where error.code == .canceled {
            phase = .failed(CeremonyError.cancelled.localizedDescription)
            throw CeremonyError.cancelled
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "Sign-in failed. Tap to try again.")
            throw error
        }
    }

    // MARK: - Friend forge & device add (next milestones)

    /// Friend forge (U2): the friend taps THEIR key on THIS phone, signing a
    /// challenge that commits to both identities + a fresh nonce (SDS §5).
    /// We verify the signature against the friend's public key as fetched
    /// from the directory — proof they control the identity they claim.
    func forgeFriendship(myRoot: RootIdentity, friend: RootIdentity) async throws -> Friendship {
        guard let friendCredentialID = friend.rawCredentialID else {
            throw CeremonyError.missingCredentialID
        }
        phase = .searching
        do {
            let nonce = Self.randomChallenge()
            let challenge = Self.friendChallenge(
                myHash: myRoot.credentialIDHash,
                theirHash: friend.credentialIDHash,
                nonce: nonce
            )
            let credential = try await performRequests(
                makeFriendAssertionRequests(friendCredentialID: friendCredentialID, challenge: challenge)
            )
            guard let assertion = credential as? ASAuthorizationPublicKeyCredentialAssertion else {
                throw CeremonyError.unexpectedCredential
            }
            phase = .reading

            let stored = WebAuthnAssertion(
                credentialID: assertion.credentialID,
                clientDataJSON: assertion.rawClientDataJSON,
                authenticatorData: assertion.rawAuthenticatorData,
                signature: assertion.signature
            )

            // Verify: right key (directory public key) over the right challenge.
            let friendPublicKey = try P256.Signing.PublicKey(rawRepresentation: friend.publicKey)
            guard stored.verify(with: friendPublicKey),
                  Self.clientDataChallengeMatches(stored.clientDataJSON, expected: challenge) else {
                throw CeremonyError.verificationFailed
            }
            // The tap just proved this person controls this key. Pin it now,
            // at the moment of proof, not later when the store is written.
            KeyPinStore.pin(hash: friend.credentialIDHash, publicKey: friend.publicKey)

            let attestation = FriendshipAttestation(nonce: nonce, timestamp: .now, assertion: stored)
            let friendship = Friendship(
                friendRootID: friend.credentialIDHash,
                attestation: try JSONEncoder().encode(attestation),
                reverseAttestation: nil,    // their phone runs the mirror ceremony
                forgedAt: .now
            )
            phase = .sealed
            SealTheme.sealHaptic()
            return friendship
        } catch let error as ASAuthorizationError where error.code == .canceled {
            phase = .failed(CeremonyError.cancelled.localizedDescription)
            throw CeremonyError.cancelled
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "Something went wrong. Tap to try again.")
            throw error
        }
    }

    /// Handover ceremony (CustodyReceipt.swift). Identical machinery to the
    /// friend forge — the counterparty taps THEIR key on THIS phone — but the
    /// challenge is a receipt commitment binding both identities to a specific
    /// item, photo hash and moment. It inherits the same guarantee: it cannot
    /// be produced remotely, and the signature is the receiver saying "I took
    /// this," not the giver claiming they handed it over.
    ///
    /// Throws rather than returning anything unverified — an unverified receipt
    /// is worse than no receipt, because it still looks like evidence.
    /// Takes the receipt's FIELDS, never raw bytes, and builds the commitment
    /// itself. The previous signature accepted a `Data` and asked the
    /// counterparty's ROOT credential to sign whatever arrived — a signing
    /// oracle one careless caller away from a root signature over a
    /// `seal.backup.v1` or `seal.endorse.v3` commitment, which is a permanent
    /// takeover from a tap the victim believes is a handover receipt. The one
    /// caller today is well-behaved, so nothing was exploitable; the point is
    /// that the type system now guarantees it instead of a convention.
    func signReceipt(receiptID: String,
                     giverHash: String,
                     receiverHash: String,
                     itemDescription: String,
                     photoSHA256: Data?,
                     signedAtEpoch: Int64,
                     nonce: Data,
                     counterparty: RootIdentity) async throws -> WebAuthnAssertion {
        let commitment = CustodyReceipt.commitment(
            receiptID: receiptID,
            giverHash: giverHash,
            receiverHash: receiverHash,
            itemDescription: itemDescription,
            photoSHA256: photoSHA256,
            signedAtEpoch: signedAtEpoch,
            nonce: nonce)
        return try await signReceipt(commitment: commitment, counterparty: counterparty)
    }

    private func signReceipt(commitment: Data, counterparty: RootIdentity) async throws -> WebAuthnAssertion {
        guard let credentialID = counterparty.rawCredentialID else {
            throw CeremonyError.missingCredentialID
        }
        phase = .searching
        do {
            let credential = try await performRequests(
                makeFriendAssertionRequests(friendCredentialID: credentialID, challenge: commitment))
            guard let assertion = credential as? ASAuthorizationPublicKeyCredentialAssertion else {
                throw CeremonyError.unexpectedCredential
            }
            phase = .reading
            let stored = WebAuthnAssertion(
                credentialID: assertion.credentialID,
                clientDataJSON: assertion.rawClientDataJSON,
                authenticatorData: assertion.rawAuthenticatorData,
                signature: assertion.signature)

            // Verify against the directory's published key, and confirm the
            // authenticator signed OUR commitment rather than something else.
            let publicKey = try P256.Signing.PublicKey(rawRepresentation: counterparty.publicKey)
            guard stored.verify(with: publicKey),
                  Self.clientDataChallengeMatches(stored.clientDataJSON, expected: commitment) else {
                throw CeremonyError.verificationFailed
            }
            phase = .sealed
            SealTheme.sealHaptic()
            return stored
        } catch let error as ASAuthorizationError where error.code == .canceled {
            phase = .failed(CeremonyError.cancelled.localizedDescription)
            throw CeremonyError.cancelled
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "Something went wrong. Tap to try again.")
            throw error
        }
    }

    /// Commitment for the RECIPROCAL half of a forge (see ForgeHandshake.swift).
    /// Deliberately a different domain string from `friendChallenge` so a
    /// device-key reciprocal signature can never be replayed as, or mistaken
    /// for, a root-key ceremony assertion — the two prove different things and
    /// must stay cryptographically distinguishable. Argument order is
    /// (whoever ran the ceremony, whoever tapped), and both sides recompute it
    /// the same way, so the commitment is unambiguous about direction.
    static func reciprocalChallenge(senderHash: String, recipientHash: String, nonce: Data) -> Data {
        Data(SHA256.hash(data: Data("seal.forge.reverse.v1".utf8)
                         + Data(senderHash.utf8) + Data(recipientHash.utf8) + nonce))
    }

    /// Domain-separated commitment binding both identities + a fresh nonce.
    static func friendChallenge(myHash: String, theirHash: String, nonce: Data) -> Data {
        Data(SHA256.hash(data: Data("seal.friend.v1".utf8) + Data(myHash.utf8) + Data(theirHash.utf8) + nonce))
    }

    static func clientDataChallengeMatches(_ clientDataJSON: Data, expected: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: clientDataJSON) as? [String: Any],
              let challenge = obj["challenge"] as? String else { return false }
        return challenge == expected.base64URLEncodedString()
    }

    /// Both providers with the same challenge: a hardware key answers via
    /// NFC/USB-C; a passkey friend answers via the nearby-device (hybrid) flow.
    func makeFriendAssertionRequests(friendCredentialID: Data, challenge: Data) -> [ASAuthorizationRequest] {
        let securityKey = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(
            relyingPartyIdentifier: Self.relyingPartyID)
        let skRequest = securityKey.createCredentialAssertionRequest(challenge: challenge)
        skRequest.allowedCredentials = [
            ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor(
                credentialID: friendCredentialID,
                transports: ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport.allSupported)
        ]
        // Match registration's UV policy: .preferred — see
        // makeRegistrationRequest for the full rationale. A PIN-protected key
        // forces the clientPIN ceremony regardless (always_uv); .preferred
        // makes iOS and the key agree so it completes, instead of the
        // .discouraged conflict that surfaced as "wrong PIN despite correct
        // PIN". Pinless keys still tap through with no prompt. (Platform/passkey
        // UV is unaffected: the passkey side verifies via Face ID.)
        skRequest.userVerificationPreference = .preferred
        let platform = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: Self.relyingPartyID)
        let pkRequest = platform.createCredentialAssertionRequest(challenge: challenge)
        pkRequest.allowedCredentials = [
            ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: friendCredentialID)
        ]
        return [skRequest, pkRequest]
    }

    /// Revoke a device (FR-19): the ROOT key signs a challenge committing to
    /// the device being killed. Only the root key holder can do this.
    func revokeDevice(devicePublicKey: Data, myRoot: RootIdentity, directory: SyncEngine) async throws {
        guard let credentialID = myRoot.rawCredentialID else { throw CeremonyError.missingCredentialID }
        phase = .searching
        do {
            let commitment = Data(SHA256.hash(data: Data("seal.revoke.v1".utf8) + devicePublicKey))
            let credential = try await performRequests(
                makeFriendAssertionRequests(friendCredentialID: credentialID, challenge: commitment))
            guard let assertion = credential as? ASAuthorizationPublicKeyCredentialAssertion else {
                throw CeremonyError.unexpectedCredential
            }
            let stored = WebAuthnAssertion(
                credentialID: assertion.credentialID,
                clientDataJSON: assertion.rawClientDataJSON,
                authenticatorData: assertion.rawAuthenticatorData,
                signature: assertion.signature)
            let revocation = DeviceRevocation(
                devicePublicKey: devicePublicKey,
                assertion: try JSONEncoder().encode(stored),
                revokedAt: .now)
            try await directory.publishRevocation(revocation, for: myRoot.credentialIDHash)
            phase = .sealed
            SealTheme.sealHaptic()
        } catch let error as ASAuthorizationError where error.code == .canceled {
            phase = .failed(CeremonyError.cancelled.localizedDescription)
            throw CeremonyError.cancelled
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "Revocation failed.")
            throw error
        }
    }

    // MARK: - Request building
    //
    // Internal rather than private: the backup-key ceremonies (FR-3) live in
    // Seal/Ceremony/BackupKeyCeremony.swift as an extension on this type and
    // build their requests through exactly these functions. Re-deriving them
    // there would mean two places holding the UV / residentKey policy that
    // the 6/26 "wrong PIN" fix depends on, and one of them drifting.

    func makeRegistrationRequest(tier: IdentityTier, name: String, challenge: Data,
                                         userID: Data, excluding: [Data] = []) -> ASAuthorizationRequest {
        switch tier {
        case .passkey:
            let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
                relyingPartyIdentifier: Self.relyingPartyID)
            let request = provider.createCredentialRegistrationRequest(
                challenge: challenge, name: name, userID: userID)
            request.excludedCredentials = excluding.map {
                ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)
            }
            return request
        case .verified:
            let provider = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(
                relyingPartyIdentifier: Self.relyingPartyID)
            let request = provider.createCredentialRegistrationRequest(
                challenge: challenge, displayName: name, name: name, userID: userID)
            request.credentialParameters = [ASAuthorizationPublicKeyCredentialParameters(algorithm: .ES256)]
            request.excludedCredentials = excluding.map {
                ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor(
                    credentialID: $0,
                    transports: ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport.allSupported)
            }
            // Non-discoverable credentials: keeps sign-in working off an
            // allow-list — signIn() hands the request every directory
            // credentialID, so a non-resident key still recognizes its own
            // credential. Scale ceiling = directory size in the allow-list;
            // fine at current scale (SDS §7). NOTE: residentKey is orthogonal
            // to the PIN — making creds non-discoverable does NOT avoid the
            // clientPIN ceremony (that's the userVerification axis, below).
            request.residentKeyPreference = .discouraged
            // UV policy — CANONICAL comment, referenced by the other three
            // security-key requests. Use .preferred, NOT .discouraged.
            //
            // Modern FIDO2.1 keys ship with `always_uv` enabled once a PIN is
            // set, so they FORCE the CTAP2 clientPIN ceremony regardless of what
            // the RP requests. Asking for .discouraged against such a key makes
            // iOS and the key disagree (RP says "no UV"; key insists on UV).
            // iOS then drives the PIN path in that contradictory state, which is
            // the "wrong PIN despite correct PIN" failure we kept hitting.
            // .preferred aligns iOS with the key so the ceremony completes.
            // Pinless keys are unaffected: .preferred prompts only "if a PIN is
            // set" (FIDO spec), so they stay tap-only with no prompt. (.required
            // would also fix PIN'd keys but forces PIN SETUP on pinless keys —
            // rejected to preserve the tap-only flow.)
            request.userVerificationPreference = .preferred
            request.attestationPreference = .direct   // SDS §6: request, don't enforce
            return request
        }
    }

    func makeAssertionRequest(tier: IdentityTier, challenge: Data, allowedCredentialID: Data) -> ASAuthorizationRequest {
        switch tier {
        case .passkey:
            let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
                relyingPartyIdentifier: Self.relyingPartyID)
            let request = provider.createCredentialAssertionRequest(challenge: challenge)
            request.allowedCredentials = [
                ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: allowedCredentialID)
            ]
            return request
        case .verified:
            let provider = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(
                relyingPartyIdentifier: Self.relyingPartyID)
            let request = provider.createCredentialAssertionRequest(challenge: challenge)
            request.allowedCredentials = [
                ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor(
                    credentialID: allowedCredentialID,
                    transports: ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport.allSupported)
            ]
            // Same UV policy as registration (.preferred) — see makeRegistrationRequest.
            request.userVerificationPreference = .preferred
            return request
        }
    }

    func performRequest(_ request: ASAuthorizationRequest) async throws -> ASAuthorizationCredential {
        try await performRequests([request])
    }

    func performRequests(_ requests: [ASAuthorizationRequest]) async throws -> ASAuthorizationCredential {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: requests)
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    static func randomChallenge(_ count: Int = 32) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}

// MARK: - ASAuthorizationController delegate

extension CeremonyManager: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        continuation?.resume(returning: authorization.credential)
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
