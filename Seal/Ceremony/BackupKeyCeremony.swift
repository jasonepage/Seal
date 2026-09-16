// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import AuthenticationServices
import CryptoKit

/// Backup-key ceremonies (FR-3, `seal.backup.v1`). The trust argument lives in
/// Seal/Identity/BackupCredential.swift; the directory side in
/// Seal/Sync/BackupDirectory.swift. This file is only the choreography.
///
/// Adding a backup key is a TWO-TAP ceremony on two different authenticators,
/// and the order matters:
///
///   1. The NEW key is tapped to create a credential. Nothing is trusted yet, 
///      at this point it is just a keypair that exists.
///   2. The ROOT key is tapped to sign a statement committing to that
///      credential's ID and public key. THAT is the authorisation, and it is
///      why adding a backup requires already holding the identity: an attacker
///      with physical access to the phone but not the root key gets as far as
///      step 1 and no further.
///
/// The same shape as every other ceremony in Seal, the tap that matters is
/// the one that signs a commitment somebody else can recompute.
extension CeremonyManager {

    /// Register `tier`'s authenticator as a backup credential for `myRoot`.
    ///
    /// The exclusion list is passed deliberately, and its refusal is a
    /// FEATURE here rather than the deterrent it is at registration: the key
    /// or phone you already sign in with cannot become its own backup. A
    /// "backup" that dies with the thing it was backing up is worse than no
    /// backup, because the person stops worrying.
    @discardableResult
    func addBackupKey(tier: IdentityTier, label: String,
                      myRoot: RootIdentity, directory: SyncEngine) async throws -> BackupCredential {
        guard let rootCredentialID = myRoot.rawCredentialID else {
            throw CeremonyError.missingCredentialID
        }
        setPhase(.searching)
        do {
            // 0. Everything already in the directory, roots AND existing
            //    backups (fetchAllCredentialIDs covers both since FR-3). Our
            //    own root credential is appended even if the directory read
            //    failed, because "don't let this key back itself up" must not
            //    depend on the network.
            var excluded = (try? await directory.fetchAllCredentialIDs()) ?? []
            if !excluded.contains(rootCredentialID) { excluded.append(rootCredentialID) }

            // 1. Create a credential on the NEW authenticator.
            let challenge = Self.randomChallenge()
            let userID = Self.randomChallenge(16)
            let registration = try await performRequest(
                makeRegistrationRequest(tier: tier, name: myRoot.displayName, challenge: challenge,
                                        userID: userID, excluding: excluded)
            ) as? ASAuthorizationPublicKeyCredentialRegistration
            guard let registration, let attestation = registration.rawAttestationObject else {
                throw CeremonyError.unexpectedCredential
            }
            setPhase(.reading)
            let parsed = try WebAuthnParsing.parseRegistration(attestationObject: attestation)
            let backupPublicKey = parsed.publicKey.rawRepresentation
            // Tier from what iOS ACTUALLY made, not from the button pressed.
            // The two normally agree, but the button is a request and this is
            // the answer, and the ring colour, the icon and the recovery
            // instructions all key off it, so a mislabelled backup key would
            // send someone hunting for a security key that is really a passkey
            // at the worst possible moment.
            let actualTier: IdentityTier =
                registration is ASAuthorizationPlatformPublicKeyCredentialRegistration ? .passkey : .verified

            // 2. The NEW key signs its ACCEPTANCE: "I belong to this root."
            //
            // Why a second tap on the same key rather than trusting step 1:
            // registration attestation is signed by a batch attestation key
            // (or, with attestation "none", not at all), so it is not a
            // dependable proof of possession of the credential's OWN key. And
            // without proof of possession the endorsement is a one-sided
            // claim, a credential ID and public key are public, so any
            // identity could list somebody else's backup key in its own
            // record, signed by its own root, and it would verify. The
            // commitment names the root, so this signature cannot be lifted
            // into another identity's record either.
            let acceptCommitment = BackupCredential.acceptanceCommitment(
                rootIDHash: myRoot.credentialIDHash,
                credentialID: registration.credentialID,
                publicKey: backupPublicKey)
            let acceptCredential = try await performRequests(
                makeFriendAssertionRequests(friendCredentialID: registration.credentialID,
                                            challenge: acceptCommitment))
            guard let acceptAssertion = acceptCredential as? ASAuthorizationPublicKeyCredentialAssertion else {
                throw CeremonyError.unexpectedCredential
            }
            let acceptance = WebAuthnAssertion(
                credentialID: acceptAssertion.credentialID,
                clientDataJSON: acceptAssertion.rawClientDataJSON,
                authenticatorData: acceptAssertion.rawAuthenticatorData,
                signature: acceptAssertion.signature)
            guard let backupPub = try? P256.Signing.PublicKey(rawRepresentation: backupPublicKey),
                  acceptance.verify(with: backupPub),
                  Self.clientDataChallengeMatches(acceptance.clientDataJSON, expected: acceptCommitment) else {
                throw CeremonyError.verificationFailed
            }

            // 3. The ROOT key signs the authorisation. Both providers are
            //    offered because the root might be a hardware key (NFC/USB-C)
            //    or a passkey (Face ID), same request builder the friend
            //    forge and device revocation use.
            setPhase(.endorsing)
            let commitment = BackupCredential.endorsementCommitment(
                credentialID: registration.credentialID, publicKey: backupPublicKey)
            let credential = try await performRequests(
                makeFriendAssertionRequests(friendCredentialID: rootCredentialID, challenge: commitment))
            guard let assertion = credential as? ASAuthorizationPublicKeyCredentialAssertion else {
                throw CeremonyError.unexpectedCredential
            }
            let stored = WebAuthnAssertion(
                credentialID: assertion.credentialID,
                clientDataJSON: assertion.rawClientDataJSON,
                authenticatorData: assertion.rawAuthenticatorData,
                signature: assertion.signature)

            // 4. Verify our OWN work before publishing it. Every other client
            //    will run exactly this check (BackupCredential.verified), so a
            //    statement that fails it is a dud that would sit in the
            //    directory looking like a safety net while being none, 
            //    precisely the failure mode a backup key must not have.
            let rootPub = try P256.Signing.PublicKey(rawRepresentation: myRoot.publicKey)
            guard stored.verify(with: rootPub),
                  Self.clientDataChallengeMatches(stored.clientDataJSON, expected: commitment) else {
                throw CeremonyError.verificationFailed
            }

            let backup = BackupCredential(
                credentialID: registration.credentialID,
                publicKey: backupPublicKey,
                tier: actualTier,
                label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                assertion: try JSONEncoder().encode(stored),
                acceptance: try JSONEncoder().encode(acceptance),
                createdAt: Clocks.current.now)

            // 5. Publish. A backup nobody can read about is not a backup: the
            //    recovering phone finds this key through the directory, so the
            //    ceremony is not done until the write lands.
            try await directory.publishBackupCredential(backup, for: myRoot.credentialIDHash)
            setPhase(.sealed)
            SealTheme.sealHaptic()
            return backup
        } catch let error as ASAuthorizationError where error.code == .canceled {
            setPhase(.failed(CeremonyError.cancelled.localizedDescription))
            throw CeremonyError.cancelled
        } catch let error as ASAuthorizationError where error.code == .matchedExcludedCredential {
            // Not the 1-key-1-identity deterrent this time, the person tried
            // to back up a key with itself.
            setPhase(.failed(BackupCeremonyError.selfBackup.localizedDescription))
            throw BackupCeremonyError.selfBackup
        } catch {
            setPhase(.failed((error as? LocalizedError)?.errorDescription
                             ?? "Couldn't add that backup key. Tap to try again."))
            throw error
        }
    }

    /// **Both ceremonies in this file need the ROOT key**, which has a
    /// consequence worth stating where it will be read: a phone recovered WITH
    /// a backup key cannot add another backup key or revoke the one it used,
    /// because the root credential is the thing that was lost. That identity
    /// is frozen at one credential until the root turns up. It follows
    /// directly from the v1 asymmetry (a backup carries the identity forward,
    /// it never gains root authority), and the honest options are: keep the
    /// root key safe, or start a fresh identity. The UI says so rather than
    /// letting a recovered user discover it by tapping for a key that no
    /// longer exists.
    ///
    /// Revoke a backup credential. The ROOT key signs, exactly as it does for
    /// a device (FR-19), and ONLY the root key can, which is the deliberate
    /// asymmetry documented in BackupCredential.swift: a backup carries the
    /// identity forward but can never demote the credential that created it.
    ///
    /// Consequence, stated where it will be read: if the root key was STOLEN
    /// rather than lost, there is no move here that evicts the thief. Delete
    /// the identity and start fresh. Improvising a backup-revokes-root path
    /// would turn every stolen backup key into a full takeover.
    func revokeBackupCredential(_ backup: BackupCredential,
                                myRoot: RootIdentity, directory: SyncEngine) async throws {
        guard let rootCredentialID = myRoot.rawCredentialID else {
            throw CeremonyError.missingCredentialID
        }
        setPhase(.searching)
        do {
            let commitment = BackupCredential.revocationCommitment(publicKey: backup.publicKey)
            // One provider, by the owner's tier. Both in one request sends a
            // passkey owner straight to the security key sheet (revokeDevice).
            let credential = try await performRequest(
                makeAssertionRequest(tier: myRoot.tier, challenge: commitment, allowedCredentialID: rootCredentialID))
            guard let assertion = credential as? ASAuthorizationPublicKeyCredentialAssertion else {
                throw CeremonyError.unexpectedCredential
            }
            let stored = WebAuthnAssertion(
                credentialID: assertion.credentialID,
                clientDataJSON: assertion.rawClientDataJSON,
                authenticatorData: assertion.rawAuthenticatorData,
                signature: assertion.signature)
            // Same reasoning as adding: verify before publishing. A revocation
            // that doesn't verify is worse than a failed one, it looks like
            // the key is dead while every client still honours it.
            let rootPub = try P256.Signing.PublicKey(rawRepresentation: myRoot.publicKey)
            guard stored.verify(with: rootPub),
                  Self.clientDataChallengeMatches(stored.clientDataJSON, expected: commitment) else {
                throw CeremonyError.verificationFailed
            }
            // Stored in the SAME `revocations` list as device revocations. The
            // domain string inside the commitment is what says which kind of
            // subject it is about, so no new field and no ambiguity.
            let revocation = DeviceRevocation(
                devicePublicKey: backup.publicKey,
                assertion: try JSONEncoder().encode(stored),
                revokedAt: Clocks.current.now)
            try await directory.publishRevocation(revocation, for: myRoot.credentialIDHash)
            setPhase(.sealed)
            SealTheme.sealHaptic()
        } catch let error as ASAuthorizationError where error.code == .canceled {
            setPhase(.failed(CeremonyError.cancelled.localizedDescription))
            throw CeremonyError.cancelled
        } catch {
            setPhase(.failed((error as? LocalizedError)?.errorDescription ?? "Couldn't revoke that backup key."))
            throw error
        }
    }
}

/// Errors specific to the backup-key ceremony. Kept out of
/// `CeremonyManager.CeremonyError` so this feature adds no cases to the enum
/// every other ceremony switches over.
enum BackupCeremonyError: LocalizedError {
    case selfBackup

    var errorDescription: String? {
        switch self {
        case .selfBackup:
            "That's a key this identity already uses. A backup has to be a different key, or a different phone."
        }
    }
}
