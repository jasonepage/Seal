// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import CryptoKit
import AuthenticationServices
import os

//  CeremonyManager+Sponsored.swift
//  Seal
//
//  REGISTERING A KEY FOR SOMEBODY ELSE (Identity/SponsoredKey.swift).
//
//  Two taps on the spare key, both on the owner's phone:
//
//    1. Registration. Creates the recipient's root credential on the key,
//       asking the key whether it supports PRF. A key that cannot is
//       refused before anything is published.
//    2. Endorsement. The root signs the virtual device's commitment (the
//       same `seal.endorse.v3` every phone signs) and, in the same tap,
//       evaluates PRF over a fresh salt. The output locks the private
//       halves. The locked blob and the salt ride in the endorsement.
//
//  Then the identity is published, pinned on this phone, and returned so
//  the People screen can add them. The owner's phone keeps no private
//  material for the new identity and never held its own device key for it.
//
//  Sign-in on the recipient's future phone is the ordinary sign-in, with
//  one addition in `signIn`: when the directory says the identity is
//  sponsored, the endorsement tap also evaluates PRF over the stored salt
//  and unlocks the halves into that phone's keychain.
//
//  The PRF properties on the security key request and result types are
//  iOS 26.4 (Apple docs); the app requires 26.5.

extension CeremonyManager {

    func registerSponsoredKey(displayName: String, directory: SyncEngine) async throws -> RootIdentity {
        setPhase(.searching)
        do {
            var excluded: [Data] = []
            do { excluded = try await directory.fetchAllCredentialIDs() } catch {
                WebAuthnDiag.log.error("sponsored: exclusion query failed: \(error.localizedDescription, privacy: .public)")
            }

            // 1. The root credential on the spare key, with a PRF check.
            let challenge = Self.randomChallenge()
            let userID = Self.randomChallenge(16)
            let registrationRequest = makeRegistrationRequest(tier: .verified, name: displayName, challenge: challenge,
                                                              userID: userID, excluding: excluded)
            Self.askPRFSupport(on: registrationRequest)
            let registration = try await performRequest(registrationRequest) as? ASAuthorizationPublicKeyCredentialRegistration
            guard let registration, let attestation = registration.rawAttestationObject else {
                throw CeremonyError.unexpectedCredential
            }
            guard Self.prfSupported(in: registration) else { throw SponsoredKey.Failure.prfUnsupported }
            setPhase(.reading)
            let parsed = try WebAuthnParsing.parseRegistration(attestationObject: attestation)
            let root = RootIdentity(
                credentialIDHash: Data(SHA256.hash(data: registration.credentialID)).hexString,
                publicKey: parsed.publicKey.rawRepresentation,
                tier: .verified,
                displayName: displayName,
                rawCredentialID: registration.credentialID)

            // 2. The virtual device, endorsed and locked in one tap.
            let halves = SponsoredKey.makeHalves()
            let parts = try SponsoredKey.publicParts(of: halves)
            let salt = SponsoredKey.randomSalt()
            let commitment = IdentityManager.endorsementCommitment(
                devicePublicKey: parts.devicePublicKey, kemBundlePublicKeys: parts.kemBundle)
            setPhase(.endorsing)
            let endorseRequest = makeAssertionRequest(tier: .verified, challenge: commitment,
                                                      allowedCredentialID: registration.credentialID)
            Self.attachPRF(salt: salt, to: endorseRequest)
            let endorseCredential = try await performRequest(endorseRequest)
            guard let assertion = endorseCredential as? ASAuthorizationPublicKeyCredentialAssertion else {
                throw CeremonyError.unexpectedCredential
            }
            guard let prf = Self.prfOutput(of: endorseCredential) else { throw SponsoredKey.Failure.prfMissing }
            let stored = WebAuthnAssertion(credentialID: assertion.credentialID,
                                           clientDataJSON: assertion.rawClientDataJSON,
                                           authenticatorData: assertion.rawAuthenticatorData,
                                           signature: assertion.signature)
            let rootKey = try P256.Signing.PublicKey(rawRepresentation: root.publicKey)
            guard stored.verify(with: rootKey),
                  Self.clientDataChallengeMatches(stored.clientDataJSON, expected: commitment) else {
                throw CeremonyError.verificationFailed
            }
            let locked = try SponsoredKey.lock(halves, prf: prf, salt: salt)
            // Prove the lock opens with this key's answer before publishing,
            // so a key that answers differently next time is caught now.
            _ = try SponsoredKey.unlock(locked, prf: prf, salt: salt)
            let endorsement = DeviceEndorsement(devicePublicKey: parts.devicePublicKey,
                                                kemBundlePublicKeys: parts.kemBundle,
                                                assertion: try JSONEncoder().encode(stored),
                                                createdAt: Clocks.current.now,
                                                lockedPrivate: locked, prfSalt: salt)

            // 3. Publish. The halves go out of scope here and nowhere else.
            let outcome = await directory.publishIdentity(root, endorsement: endorsement)
            guard outcome == .published else { throw CeremonyError.directoryUnavailable }
            KeyPinStore.pin(hash: root.credentialIDHash, publicKey: root.publicKey)
            setPhase(.sealed)
            SealTheme.sealHaptic()
            return root
        } catch let error as ASAuthorizationError where error.code == .canceled {
            setPhase(.failed(CeremonyError.cancelled.localizedDescription))
            throw CeremonyError.cancelled
        } catch let error as ASAuthorizationError where error.code == .matchedExcludedCredential {
            setPhase(.failed(CeremonyError.alreadyRegistered.localizedDescription))
            throw CeremonyError.alreadyRegistered
        } catch {
            setPhase(.failed((error as? LocalizedError)?.errorDescription ?? "Something went wrong. Tap to try again."))
            throw error
        }
    }

    // MARK: - PRF plumbing (iOS 26.4 security key API)

    // Guarded, because one build configuration still carries an older
    // deployment target. Below 26.4 a security key simply reports "cannot
    // carry a secret", which is the truth on that OS.

    static func askPRFSupport(on request: ASAuthorizationRequest) {
        if #available(iOS 26.4, *),
           let r = request as? ASAuthorizationSecurityKeyPublicKeyCredentialRegistrationRequest {
            r.prf = .checkForSupport
        }
    }

    static func prfSupported(in registration: ASAuthorizationPublicKeyCredentialRegistration) -> Bool {
        if #available(iOS 26.4, *) {
            return (registration as? ASAuthorizationSecurityKeyPublicKeyCredentialRegistration)?.prf?.isSupported ?? false
        }
        return false
    }

    static func attachPRF(salt: Data, to request: ASAuthorizationRequest) {
        if #available(iOS 26.4, *),
           let r = request as? ASAuthorizationSecurityKeyPublicKeyCredentialAssertionRequest {
            r.prf = .inputValues(.init(saltInput1: salt, saltInput2: nil))
        }
    }

    static func prfOutput(of credential: ASAuthorizationCredential) -> SymmetricKey? {
        if #available(iOS 26.4, *) {
            return (credential as? ASAuthorizationSecurityKeyPublicKeyCredentialAssertion)?.prf?.first
        }
        return nil
    }
}
