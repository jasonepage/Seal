// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import AuthenticationServices
import CryptoKit

//  CeremonyManager+FindKey.swift
//  Seal
//
//  ADD SOMEONE BACK BY TAPPING THEIR KEY (1.3).
//
//  The gap. A person you set up a kit key for (SponsoredKeyView) has no app,
//  so there is no seal of theirs to scan. Sign out, or move to a new
//  iPhone, and People is empty; the key cannot be set up again either,
//  because it already holds their account (one key, one identity). Before
//  this, the only way back was to retire their account, which would have cut
//  them off from every envelope already sealed to them.
//
//  What proves it. One tap on their key, here, now. The tap must verify
//  against the key published for that account, and against this phone's
//  pin if it still has one. That is the same trust as the evening the key
//  was set up: the key is in your hand.
//
//  What it refuses.
//    - A backup key: it has no account of its own (RetireKeyCeremony.swift).
//    - A retired account.
//    - Someone who uses Seal on their own phone. They have a seal to scan,
//      and the in-person scan is the stronger, two-way check.
//
//  Nothing is written to the directory. The person is added to People on
//  this phone only, marked `sponsored` like the day their key was set up.

extension CeremonyManager {

    enum FindKeyError: LocalizedError {
        case notSetUp, isBackup, retired, usesTheApp, keyChanged, yours

        var errorDescription: String? {
            switch self {
            case .notSetUp:
                "This key is not set up for anyone yet. Use \"Use a key from your kit\" to set it up."
            case .isBackup:
                "This is someone's spare key. Tap their main key instead."
            case .retired:
                "The person on this key deleted their Seal account."
            case .usesTheApp:
                "This person has Seal on their own phone. Ask them to open People so you can scan their seal."
            case .yours:
                "That is your own key. Tap the key you set up for them."
            case .keyChanged:
                KeyPinStore.PinError.publicKeyChanged(hash: "").errorDescription
                    ?? "This key does not match the one you set up before."
            }
        }
    }

    /// One tap on a key you set up for someone earlier. Returns that person,
    /// the tap, and the challenge it signed, already checked.
    func findKeyOwner(directory: SyncEngine) async throws -> (root: RootIdentity, tap: WebAuthnAssertion, challenge: Data) {
        setPhase(.searching)
        do {
            let credentials: [SyncEngine.DirectoryCredential]
            do {
                credentials = try await directory.fetchDirectoryCredentials()
            } catch {
                throw CeremonyError.directoryUnavailable
            }
            guard !credentials.isEmpty else { throw CeremonyError.directoryEmpty }

            // A security key answers only for an ID on the list, so the list
            // is every live credential in the directory (as in sign-in).
            let challenge = Self.randomChallenge()
            let provider = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(
                relyingPartyIdentifier: Self.relyingPartyID)
            let request = provider.createCredentialAssertionRequest(challenge: challenge)
            request.userVerificationPreference = .preferred
            request.allowedCredentials = credentials.map {
                ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor(
                    credentialID: $0.credentialID,
                    transports: ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport.allSupported)
            }

            let credential = try await performRequest(request)
            guard let assertion = credential as? ASAuthorizationPublicKeyCredentialAssertion else {
                throw CeremonyError.unexpectedCredential
            }
            setPhase(.reading)

            let tap = WebAuthnAssertion(
                credentialID: assertion.credentialID,
                clientDataJSON: assertion.rawClientDataJSON,
                authenticatorData: assertion.rawAuthenticatorData,
                signature: assertion.signature)
            guard Self.clientDataChallengeMatches(tap.clientDataJSON, expected: challenge) else {
                throw CeremonyError.verificationFailed
            }

            let hash = Data(SHA256.hash(data: assertion.credentialID)).hexString
            let mine = identity.rootIdentity?.credentialIDHash
            if hash == mine || credentials.contains(where: { $0.isBackup && $0.credentialIDHash == hash && $0.ownerHash == mine }) {
                throw FindKeyError.yours
            }
            if credentials.contains(where: { $0.isBackup && $0.credentialIDHash == hash }) {
                throw FindKeyError.isBackup
            }
            if try await directory.isTombstoned(credentialIDHash: hash) {
                throw FindKeyError.retired
            }
            guard let (root, endorsements) = try await directory.fetchIdentity(credentialIDHash: hash) else {
                throw FindKeyError.notSetUp
            }
            guard let key = try? P256.Signing.PublicKey(rawRepresentation: root.publicKey),
                  tap.verify(with: key) else {
                throw CeremonyError.verificationFailed
            }
            if KeyPinStore.check(hash: hash, publicKey: root.publicKey, pins: KeyPinStore.load()) == .mismatch {
                throw FindKeyError.keyChanged
            }
            guard endorsements.contains(where: \.isSponsored) else {
                throw FindKeyError.usesTheApp
            }

            resetPhase()
            return (root, tap, challenge)
        } catch let error as ASAuthorizationError where error.code == .canceled {
            setPhase(.failed(CeremonyError.cancelled.localizedDescription))
            throw CeremonyError.cancelled
        } catch {
            setPhase(.failed((error as? LocalizedError)?.errorDescription ?? "Something went wrong. Tap to try again."))
            throw error
        }
    }
}
