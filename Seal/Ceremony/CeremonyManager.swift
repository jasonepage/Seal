import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

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

        var errorDescription: String? {
            switch self {
            case .cancelled: "The ceremony was cancelled. Tap to try again."
            case .unexpectedCredential: "That wasn't the response we expected. Tap to try again."
            case .keyUnreadable: "Couldn't read the key's response. Try holding it still against the top of your phone."
            case .verificationFailed: "That key doesn't match this person's identity. The forge was NOT completed."
            case .missingCredentialID: "This person registered before credential publishing — they need to update their identity."
            }
        }
    }

    // MARK: - Registration (U1, FR-1/FR-2/FR-21)

    /// Creates the root credential (hardware key or passkey), then a Secure
    /// Enclave device key, then asks the root credential to sign an
    /// endorsement committing to the device key (SDS §2).
    func register(tier: IdentityTier, displayName: String) async throws -> RootIdentity {
        phase = .searching
        do {
            // 1. Create the root WebAuthn credential.
            let challenge = Self.randomChallenge()
            let userID = Self.randomChallenge(16)
            let registration = try await performRequest(
                makeRegistrationRequest(tier: tier, name: displayName, challenge: challenge, userID: userID)
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

            // 3. Create this device's Secure Enclave signing key.
            let deviceKey = try identity.createDeviceKey()
            let devicePub = deviceKey.publicKey.x963Representation

            // 4. Endorsement: root credential signs a challenge that commits
            //    to the device public key — "this root vouches for this device."
            phase = .endorsing
            let commitment = Data(SHA256.hash(data: Data("seal.endorse.v1".utf8) + devicePub))
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
                createdAt: .now,
                revokedAt: nil
            )

            // 5. Persist. (CloudKit publish is SyncEngine's job — next milestone.)
            identity.completeRegistration(identity: root, endorsement: endorsement)
            phase = .sealed
            SealTheme.sealHaptic()
            return root
        } catch let error as ASAuthorizationError where error.code == .canceled {
            phase = .failed(CeremonyError.cancelled.localizedDescription)
            throw CeremonyError.cancelled
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "Something went wrong. Tap to try again.")
            throw error
        }
    }

    func resetPhase() { phase = .idle }

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
    private func makeFriendAssertionRequests(friendCredentialID: Data, challenge: Data) -> [ASAuthorizationRequest] {
        let securityKey = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(
            relyingPartyIdentifier: Self.relyingPartyID)
        let skRequest = securityKey.createCredentialAssertionRequest(challenge: challenge)
        skRequest.allowedCredentials = [
            ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor(
                credentialID: friendCredentialID,
                transports: ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport.allSupported)
        ]
        let platform = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: Self.relyingPartyID)
        let pkRequest = platform.createCredentialAssertionRequest(challenge: challenge)
        pkRequest.allowedCredentials = [
            ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: friendCredentialID)
        ]
        return [skRequest, pkRequest]
    }

    /// Device add (U4): hardware-key assertion commits to the new device's key.
    func endorseNewDevice(devicePublicKey: Data) async throws -> DeviceEndorsement {
        fatalError("unimplemented — next milestone")
    }

    // MARK: - Request building

    private func makeRegistrationRequest(tier: IdentityTier, name: String, challenge: Data, userID: Data) -> ASAuthorizationRequest {
        switch tier {
        case .passkey:
            let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
                relyingPartyIdentifier: Self.relyingPartyID)
            return provider.createCredentialRegistrationRequest(
                challenge: challenge, name: name, userID: userID)
        case .verified:
            let provider = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(
                relyingPartyIdentifier: Self.relyingPartyID)
            let request = provider.createCredentialRegistrationRequest(
                challenge: challenge, displayName: name, name: name, userID: userID)
            request.credentialParameters = [ASAuthorizationPublicKeyCredentialParameters(algorithm: .ES256)]
            request.residentKeyPreference = .discouraged
            // .discouraged avoids iOS forcing PIN setup on PIN-less keys mid-ceremony.
            // Revisit for Verified tier policy (key presence is still required).
            request.userVerificationPreference = .discouraged
            request.attestationPreference = .direct   // SDS §6: request, don't enforce
            return request
        }
    }

    private func makeAssertionRequest(tier: IdentityTier, challenge: Data, allowedCredentialID: Data) -> ASAuthorizationRequest {
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
            return request
        }
    }

    private func performRequest(_ request: ASAuthorizationRequest) async throws -> ASAuthorizationCredential {
        try await performRequests([request])
    }

    private func performRequests(_ requests: [ASAuthorizationRequest]) async throws -> ASAuthorizationCredential {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: requests)
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    private static func randomChallenge(_ count: Int = 32) -> Data {
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
