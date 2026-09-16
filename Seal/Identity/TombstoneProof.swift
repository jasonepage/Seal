// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import CryptoKit

//  TombstoneProof.swift
//  Seal
//
//  A DELETE MARKER ONLY THE ACCOUNT'S OWN KEY CAN WRITE.
//
//  The write-once "tomb.<hash>" record used to carry nothing but a tier
//  string. The one tap in RetireKeyCeremony was checked inside the app and
//  nowhere else, so anybody with a modified client could create
//  "tomb.<anybody's hash>" in the public database. From then on that person
//  could not sign in, and every phone that met them showed them as deleted.
//
//  Now the marker carries the tap: a WebAuthn assertion by the identity's
//  root credential over a challenge in its own domain,
//  SHA256("seal.identity.delete.v1" || nonce). Readers check that
//    1. the credential in the assertion hashes to the marker's name,
//    2. the challenge is the delete challenge for the stored nonce,
//    3. the signature (and the relying party, user presence and type
//       checks inside `verify`) holds under the identity's key: the key
//       this phone PINNED when it met them, or failing that the key the
//       live directory record publishes.
//  A marker that fails is ignored, and says so in the log.
//
//  Where it is stored: the marker is an `Identity` record, and the proof
//  goes in that record type's existing `revocations` Bytes field. No new
//  field, no schema deploy. Nothing else reads `revocations` on a
//  "tomb." record.
//
//  Old unsigned markers still count on the phone that wrote them, through
//  DeletedIdentityLedger, and a live record whose tier was flipped to the
//  deleted sentinel still counts everywhere, because only the record's
//  creator could have flipped it.

struct TombstoneProof: Codable, Hashable {
    let nonce: Data
    let assertion: WebAuthnAssertion

    static let domain = "seal.identity.delete.v1"
    /// The Identity field the proof rides in on a "tomb." record.
    static let field = "revocations"

    static func challenge(nonce: Data) -> Data {
        Data(SHA256.hash(data: Data(domain.utf8) + nonce))
    }

    /// True when this proof deletes exactly `hash` and was signed by `publicKey`.
    func proves(deletionOf hash: String, publicKey: Data) -> Bool {
        guard Data(SHA256.hash(data: assertion.credentialID)).hexString == hash,
              let key = try? P256.Signing.PublicKey(rawRepresentation: publicKey),
              CeremonyManager.clientDataChallengeMatches(assertion.clientDataJSON,
                                                         expected: Self.challenge(nonce: nonce)) else {
            return false
        }
        return assertion.verify(with: key)
    }

    /// The decision every reader makes about a marker it found.
    /// - `proofData`: what the marker's `revocations` field held, or nil.
    /// - `knownKey`: the pinned key, else the live record's key, else nil.
    /// With no key anywhere there is no identity for the marker to hurt
    /// (the retire ceremony's never-published case), so it counts.
    static func markerCounts(hash: String, proofData: Data?, knownKey: Data?) -> Bool {
        guard let knownKey else { return true }
        guard let proofData, let proof = try? JSONDecoder().decode(TombstoneProof.self, from: proofData) else {
            return false
        }
        return proof.proves(deletionOf: hash, publicKey: knownKey)
    }
}
