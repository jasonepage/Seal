import Foundation
import CryptoKit

/// Redemption flow + local store for the user's OWN verified perks
/// (keychain JSON, namespaced per identity like every other store).
///
/// Flow (SDS §10): code → hash → fetch grant → verify founder signature →
/// sign claim with this device's endorsed key → create pclaim record (first
/// creator wins) → publish attestation to our Identity record.
@Observable
final class PerkRedeemer {
    enum RedeemError: LocalizedError {
        case notRecognized, invalidGrant, alreadyClaimed, noDeviceKey, offline(String)

        var errorDescription: String? {
            switch self {
            case .notRecognized: "That code isn't recognized. Check it against the card in your pack."
            case .invalidGrant: "This code's grant didn't pass verification — it wasn't signed by Seal."
            case .alreadyClaimed: "This code has already been claimed by someone else."
            case .noDeviceKey: "This device has no endorsed key yet — finish registration first."
            case .offline(let detail): detail
            }
        }
    }

    private(set) var perks: [PerkAttestation] = []
    let ownerHash: String
    private let identity: IdentityManager
    private let sync: SyncEngine
    private var storageKey: String { "seal.perks.\(ownerHash)" }

    init(ownerHash: String, identity: IdentityManager, sync: SyncEngine) {
        self.ownerHash = ownerHash
        self.identity = identity
        self.sync = sync
        load()
    }

    static func wipe(ownerHash: String) {
        KeychainStore.delete("seal.perks.\(ownerHash)")
    }

    /// Redeem a claim code. Idempotent for the same identity: re-entering a
    /// code you already claimed succeeds and just re-publishes.
    func redeem(code: String, myRoot: RootIdentity) async throws -> PerkAttestation {
        guard let deviceKey = identity.deviceKey,
              let endorsement = identity.deviceEndorsement else { throw RedeemError.noDeviceKey }

        let codeHash = PerkAuthority.codeHashHex(code: code)

        // 1. Fetch + verify the grant — founder signature first, always.
        let grant: PerkGrant?
        do { grant = try await sync.fetchPerkGrant(codeHashHex: codeHash) }
        catch { throw RedeemError.offline("Couldn't reach iCloud — try again when you're online.") }
        guard let grant else { throw RedeemError.notRecognized }
        guard PerkAuthority.verifyGrant(grant, enteredCodeHashHex: codeHash) else {
            throw RedeemError.invalidGrant
        }

        // 2. Sign the claim with this device's endorsed key.
        let claimedAt = Int64(Date.now.timeIntervalSince1970)
        let devicePub = endorsement.devicePublicKey
        let message = PerkAuthority.claimMessage(
            codeHashHex: codeHash, rootID: myRoot.credentialIDHash,
            devicePublicKey: devicePub, claimedAtUnix: claimedAt)
        let signature = try deviceKey.signature(for: message)
        let claim = PerkClaim(codeHashHex: codeHash, rootID: myRoot.credentialIDHash,
                              devicePublicKey: devicePub, claimedAtUnix: claimedAt,
                              signature: signature.derRepresentation)

        // 3. First creator wins. If a claim already exists it's either ours
        //    (re-redeem → fine) or someone else's (→ honest error).
        let attestation: PerkAttestation
        do {
            if let existing = try await sync.createPerkClaim(claim) {
                guard existing.rootID == myRoot.credentialIDHash else { throw RedeemError.alreadyClaimed }
                attestation = PerkAttestation(grant: grant, claim: existing)
            } else {
                attestation = PerkAttestation(grant: grant, claim: claim)
            }
            // 4. Bind to our Identity record so friends' clients can verify.
            try await sync.publishPerk(attestation, for: myRoot.credentialIDHash)
        } catch let error as RedeemError {
            throw error
        } catch {
            throw RedeemError.offline("Couldn't reach iCloud — try again when you're online.")
        }

        perks.removeAll { $0.grant.codeHashHex == codeHash }
        perks.append(attestation)
        save()
        return attestation
    }

    private func save() {
        if let data = try? JSONEncoder().encode(perks) {
            KeychainStore.save(data, for: storageKey)
        }
    }

    private func load() {
        if let data = KeychainStore.load(storageKey),
           let decoded = try? JSONDecoder().decode([PerkAttestation].self, from: data) {
            perks = decoded
        }
    }
}
