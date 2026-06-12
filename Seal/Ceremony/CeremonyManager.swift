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

        var errorDescription: String? {
            switch self {
            case .cancelled: "The ceremony was cancelled. Tap to try again."
            case .unexpectedCredential: "That wasn't the response we expected. Tap to try again."
            case .keyUnreadable: "Couldn't read the key's response. Try holding it still against the top of your phone."
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
                displayName: displayName
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
                kemBundlePublicKeys: Data(),    // TODO: HybridKEM bundle (SDS §2)
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

    /// Friend forge (U2): challenge commits to (our root, their claimed root,
    /// timestamp); the friend taps THEIR key on THIS phone (SDS §5).
    func forgeFriendship(claimedFriend: RootIdentity) async throws -> Friendship {
        fatalError("unimplemented — next milestone")
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
            request.userVerificationPreference = .preferred
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
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
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
}
