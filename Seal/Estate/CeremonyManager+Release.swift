import Foundation
import CryptoKit
import AuthenticationServices

//  CeremonyManager+Release.swift
//  Seal
//
//  The one new ceremony: a custodian taps THEIR OWN key on THEIR OWN phone
//  to authorise a release. Same machinery as sign-in (own credential, own
//  tier), different challenge: `ReleaseChallenge.challenge` binds the
//  estate, epoch, claim and record head, so the assertion means exactly
//  "I, this credential, authorise this claim on this history" and nothing
//  else.

extension CeremonyManager {

    func signReleaseAuthorization(challenge: Data, myRoot: RootIdentity) async throws -> WebAuthnAssertion {
        guard let credentialID = myRoot.rawCredentialID else { throw CeremonyError.missingCredentialID }
        phase = .searching
        do {
            let credential = try await performRequest(
                makeAssertionRequest(tier: myRoot.tier, challenge: challenge, allowedCredentialID: credentialID))
            guard let assertion = credential as? ASAuthorizationPublicKeyCredentialAssertion else {
                throw CeremonyError.unexpectedCredential
            }
            phase = .reading
            let stored = WebAuthnAssertion(credentialID: assertion.credentialID,
                                           clientDataJSON: assertion.rawClientDataJSON,
                                           authenticatorData: assertion.rawAuthenticatorData,
                                           signature: assertion.signature)
            let publicKey = try P256.Signing.PublicKey(rawRepresentation: myRoot.publicKey)
            guard stored.verify(with: publicKey),
                  Self.clientDataChallengeMatches(stored.clientDataJSON, expected: challenge) else {
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
}
