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
///   1. The NEW key is tapped to create a credential. Nothing is trusted yet —
///      at this point it is just a keypair that exists.
///   2. The ROOT key is tapped to sign a statement committing to that
///      credential's ID and public key. THAT is the authorisation, and it is
///      why adding a backup requires already holding the identity: an attacker
///      with physical access to the phone but not the root key gets as far as
///      step 1 and no further.
///
/// The same shape as every other ceremony in Seal — the tap that matters is
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
            // 0. Everything already in the directory — roots AND existing
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

            // 2. The ROOT key signs the authorisation. Both providers are
            //    offered because the root might be a hardware key (NFC/USB-C)
            //    or a passkey (Face ID) — same request builder the friend
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

            // 3. Verify our OWN work before publishing it. Every other client
            //    will run exactly this check (BackupCredential.verified), so a
            //    statement that fails it is a dud that would sit in the
            //    directory looking like a safety net while being none —
            //    precisely the failure mode a backup key must not have.
            let rootPub = try P256.Signing.PublicKey(rawRepresentation: myRoot.publicKey)
            guard stored.verify(with: rootPub),
                  Self.clientDataChallengeMatches(stored.clientDataJSON, expected: commitment) else {
                throw CeremonyError.verificationFailed
            }

            let backup = BackupCredential(
                credentialID: registration.credentialID,
                publicKey: backupPublicKey,
                tier: tier,
                label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                assertion: try JSONEncoder().encode(stored),
                createdAt: .now)

            // 4. Publish. A backup nobody can read about is not a backup: the
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
            // Not the 1-key-1-identity deterrent this time — the person tried
            // to back up a key with itself.
            setPhase(.failed(BackupCeremonyError.selfBackup.localizedDescription))
            throw BackupCeremonyError.selfBackup
        } catch {
            setPhase(.failed((error as? LocalizedError)?.errorDescription
                             ?? "Couldn't add that backup key. Tap to try again."))
            throw error
        }
    }

    /// Revoke a backup credential. The ROOT key signs, exactly as it does for
    /// a device (FR-19) — and ONLY the root key can, which is the deliberate
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
            // Same reasoning as adding: verify before publishing. A revocation
            // that doesn't verify is worse than a failed one — it looks like
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
                revokedAt: .now)
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
