// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import AuthenticationServices
import CryptoKit
import os

//  RetireKeyCeremony.swift
//  Seal
//
//  THE ESCAPE HATCH. Tombstone an identity WITHOUT signing into it.
//
//  Why. Deleting an identity lives on the You screen, which needs a
//  sign-in first. When sign-in refuses (a record that fails a check, a
//  directory in a bad state, a half-finished registration) the identity
//  is unreachable and its credential keeps blocking "Set up with Face ID"
//  through the one-key-one-identity exclusion list. That is a person
//  locked out of making an account with their own Face ID, by a record
//  nobody can touch.
//
//  What proves the right to retire. One tap on the credential. The tap
//  produces an assertion; if the directory publishes a key under that
//  credential's hash, the assertion must verify against it, so nobody can
//  tombstone a record they do not hold the key for. If the directory
//  publishes nothing under that name, the hash is still derived from a
//  credential the tapper just used, so it can only be their own.
//
//  What is REFUSED. A backup key. A backup credential has no directory
//  record of its own: it lives inside the root identity's record, under
//  backupEndorsements. So a backup tap finds nothing published under its
//  hash, skips the match check above, and would tombstone the BACKUP's
//  hash while the root identity stays alive. From then on sign-in refuses
//  that backup key and says the identity was deleted, which is not true.
//  The person most likely to reach for the spare key is the person whose
//  main key is already giving them trouble, and that is the person this
//  would strand. So a backup tap is refused and sent to Delete identity.
//
//  Then it is the ordinary delete: write-once tombstone marker on the
//  server, the hash into this phone's graveyard, best-effort flip of the
//  live record. Nothing is signed in to, no device is endorsed.

extension CeremonyManager {

    enum RetireError: LocalizedError {
        case keyDoesNotMatchRecord
        case keyIsABackup
        case identityAlreadyRetired

        var errorDescription: String? {
            switch self {
            case .keyDoesNotMatchRecord:
                "That key does not match the identity published under its name, so Seal did not retire anything."
            case .keyIsABackup:
                "That is a backup key for an identity that is still in use, so Seal did not retire anything. A backup key is not an identity of its own. To delete that identity, sign in to it and use Delete identity on the You screen."
            case .identityAlreadyRetired:
                "That is a backup key for an identity that was already deleted. Nothing was changed."
            }
        }
    }

    /// Returns the retired credential's hash.
    func retireCredential(directory: SyncEngine, tier: IdentityTier) async throws -> String {
        setPhase(.searching)
        do {
            let challenge = Self.randomChallenge()
            // Kept so the backup check after the tap does not scan twice.
            var scanned: [SyncEngine.DirectoryCredential]?
            let request: ASAuthorizationRequest
            switch tier {
            case .passkey:
                // Empty allow list on purpose: the whole point is reaching a
                // passkey the normal sign-in no longer offers.
                let platform = ASAuthorizationPlatformPublicKeyCredentialProvider(
                    relyingPartyIdentifier: Self.relyingPartyID)
                request = platform.createCredentialAssertionRequest(challenge: challenge)
            case .verified:
                let security = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(
                    relyingPartyIdentifier: Self.relyingPartyID)
                let securityRequest = security.createCredentialAssertionRequest(challenge: challenge)
                securityRequest.userVerificationPreference = .preferred
                // Dead identities included: a non-discoverable key can only
                // answer for an ID that is on the list.
                do {
                    scanned = try await directory.fetchDirectoryCredentials(includingDead: true)
                } catch {
                    throw CeremonyError.directoryUnavailable
                }
                let ids = (scanned ?? []).map(\.credentialID)
                guard !ids.isEmpty else { throw CeremonyError.directoryEmpty }
                securityRequest.allowedCredentials = ids.map {
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
            setPhase(.reading)

            let hash = Data(SHA256.hash(data: assertion.credentialID)).hexString
            let stored = WebAuthnAssertion(
                credentialID: assertion.credentialID,
                clientDataJSON: assertion.rawClientDataJSON,
                authenticatorData: assertion.rawAuthenticatorData,
                signature: assertion.signature)
            guard Self.clientDataChallengeMatches(stored.clientDataJSON, expected: challenge) else {
                throw CeremonyError.verificationFailed
            }

            // REFUSE A BACKUP KEY (see the note at the top of this file).
            // Fails closed: without the directory there is no way to tell a
            // root credential from a backup one, and a tombstone cannot be
            // written without the directory anyway, so nothing is lost.
            let all: [SyncEngine.DirectoryCredential]
            if let scanned {
                all = scanned
            } else {
                do {
                    all = try await directory.fetchDirectoryCredentials(includingDead: true)
                } catch {
                    WebAuthnDiag.log.error("retire: directory unreachable, refusing to retire \(hash, privacy: .public) unchecked")
                    throw CeremonyError.directoryUnavailable
                }
            }
            if let backup = all.first(where: { $0.isBackup && $0.credentialIDHash == hash }) {
                let ownerRetired: Bool
                do {
                    ownerRetired = try await directory.isTombstoned(credentialIDHash: backup.ownerHash)
                } catch {
                    throw CeremonyError.directoryUnavailable
                }
                WebAuthnDiag.log.error("retire: refused, \(hash, privacy: .public) is a backup credential for \(backup.ownerHash, privacy: .public) (owner retired: \(ownerRetired, privacy: .public))")
                throw ownerRetired ? RetireError.identityAlreadyRetired : RetireError.keyIsABackup
            }

            // If a record is published under this name, the tap must match it.
            if let published = try await directory.publishedPublicKey(credentialIDHash: hash) {
                guard let key = try? P256.Signing.PublicKey(rawRepresentation: published),
                      stored.verify(with: key) else {
                    WebAuthnDiag.log.error("retire: tap did not verify against the record published under \(hash, privacy: .public)")
                    throw RetireError.keyDoesNotMatchRecord
                }
            }

            try await directory.deleteIdentity(credentialIDHash: hash)
            WebAuthnDiag.log.info("retire: tombstoned \(hash, privacy: .public) without sign-in")
            resetPhase()
            return hash
        } catch let error as ASAuthorizationError where error.code == .canceled {
            setPhase(.failed(CeremonyError.cancelled.localizedDescription))
            throw CeremonyError.cancelled
        } catch {
            setPhase(.failed((error as? LocalizedError)?.errorDescription ?? "Something went wrong. Tap to try again."))
            throw error
        }
    }
}
