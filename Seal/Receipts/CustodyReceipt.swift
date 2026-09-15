import Foundation
import CryptoKit
import Security
import os

//  CustodyReceipt.swift
//  Seal
//
//  PROOF OF HANDOVER.
//
//  The friend ceremony proves "we met." A receipt proves "I handed you THIS,
//  you took it, and neither of us can deny it later." That is a different
//  product from messaging, and it is the one thing Seal can do that Signal,
//  iMessage and World ID structurally cannot: they secure a pipe, or attest an
//  anonymous human. Only Seal can bind two specific hardware-rooted identities
//  to a specific object at a specific moment, in person.
//
//  WHAT A RECEIPT ACTUALLY PROVES
//  ------------------------------
//  Both parties sign one commitment that covers BOTH identities, the item
//  description, the SHA-256 of a photo taken at handover, the timestamp, and a
//  fresh nonce:
//
//      SHA256( "seal.receipt.v1" | giver | receiver | photoHash | desc | at | nonce )
//
//  * The RECEIVER signs it with their ROOT credential — a hardware key or
//    passkey, physically tapped on the giver's phone. That is the strong half:
//    it cannot be produced remotely, and it is the receiver saying "I took
//    this," not the giver claiming they handed it over.
//  * The GIVER signs the same commitment with their Secure Enclave device key,
//    which their root credential already endorsed, so the issuer is pinned too.
//
//  Anyone can verify both signatures later against the public directory, with
//  no server and no account — see `verify(against:)`. Change one character of
//  the description, or swap the photo, and both signatures fail.
//
//  WHAT IT DELIBERATELY DOES NOT PROVE
//  -----------------------------------
//  That a credential belongs to a named legal person. Seal proves credential A
//  handed something to credential B. Binding a credential to a passport is what
//  notaries sell and Seal does not do it — do not let the UI imply otherwise.
//  Also: the photo hash proves the photo hasn't changed since signing, NOT that
//  the photo depicts the truth. It's evidence, not omniscience.

/// One signed handover. Self-contained: everything needed to re-verify it
/// offline years later, given only the public directory.
struct CustodyReceipt: Codable, Identifiable, Hashable {
    var id: String { receiptID }
    let receiptID: String

    let giverHash: String
    let receiverHash: String
    /// Display names as they stood at signing time. Snapshotted deliberately:
    /// names are mutable metadata, and a receipt has to read correctly later
    /// even if somebody renames themselves. The HASHES are the identity.
    let giverName: String
    let receiverName: String

    let itemDescription: String
    /// SHA-256 of the JPEG shown at handover. This is what binds the receipt to
    /// a physical object; the image itself is stored separately and privately.
    let photoSHA256: Data?
    /// Whole seconds since 1970, stored as an integer ON PURPOSE. A `Date` is
    /// encoded by JSONEncoder as a Double, and this value is rebuilt into a
    /// signed commitment on the verifier's machine — an integer round-trips
    /// exactly, and more importantly it cannot carry a hostile magnitude like
    /// 1e300 into a trapping `Int64(_: Double)` conversion and crash the app.
    let signedAtEpoch: Int64
    let nonce: Data

    var signedAt: Date { Date(timeIntervalSince1970: TimeInterval(signedAtEpoch)) }

    /// Receiver's ROOT-credential assertion over the commitment — the strong half.
    let receiverAssertion: WebAuthnAssertion
    /// Giver's Secure Enclave device signature over the same commitment.
    let giverSignature: Data
    let giverDevicePublicKey: Data

    /// Encrypted photo in CloudKit + its content key. Local/private only —
    /// never published in the clear (see ReceiptService.publish).
    var mediaRef: String?
    var mediaKey: Data?

    // MARK: - Commitment

    /// Domain-separated so a receipt signature can never be replayed as a
    /// friend ceremony (`seal.friend.v1`) or a reciprocal handshake
    /// (`seal.forge.reverse.v1`), and vice versa. Field order is fixed and
    /// lengths are delimited, so no two different receipts can produce the
    /// same commitment by shuffling bytes between fields.
    static func commitment(receiptID: String,
                           giverHash: String,
                           receiverHash: String,
                           itemDescription: String,
                           photoSHA256: Data?,
                           signedAtEpoch: Int64,
                           nonce: Data) -> Data {
        var input = Data("seal.receipt.v1".utf8)
        func field(_ data: Data) {
            var length = UInt32(data.count).bigEndian
            withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
            input.append(data)
        }
        // receiptID is signed too, so a valid receipt can't simply be re-emitted
        // under fresh ids to manufacture N handovers from one real ceremony.
        field(Data(receiptID.utf8))
        field(Data(giverHash.utf8))
        field(Data(receiverHash.utf8))
        field(Data(itemDescription.utf8))
        // Presence byte: "no photo" and "empty photo" must not collide in a
        // construction whose entire job is being unambiguous.
        input.append(photoSHA256 == nil ? 0x00 : 0x01)
        field(photoSHA256 ?? Data())
        field(Data(String(signedAtEpoch).utf8))
        field(nonce)
        return Data(SHA256.hash(data: input))
    }

    var commitment: Data {
        Self.commitment(receiptID: receiptID, giverHash: giverHash, receiverHash: receiverHash,
                        itemDescription: itemDescription, photoSHA256: photoSHA256,
                        signedAtEpoch: signedAtEpoch, nonce: nonce)
    }

    // MARK: - Verification

    enum Verdict: Equatable {
        case valid
        case receiverSignatureFailed
        case giverSignatureFailed
        case photoAltered
        case identityMissing

        var isValid: Bool { self == .valid }
    }

    /// Re-verify from scratch against the public directory. `directory` maps a
    /// root hash to that identity and its VERIFIED device endorsements — the
    /// same thing SyncEngine.fetchIdentity returns.
    ///
    /// `photo` is optional: pass the bytes to also confirm the image still
    /// matches what was signed. Omit it and everything except the image is
    /// still checked, which is the right behaviour when only the counterparty
    /// kept a copy of the picture.
    func verify(against directory: [String: (RootIdentity, [DeviceEndorsement])],
                photo: Data? = nil,
                using identity: IdentityManager) -> Verdict {
        guard let (giver, giverEndorsements) = directory[giverHash],
              let (receiver, _) = directory[receiverHash] else { return .identityMissing }

        if let photo, let expected = photoSHA256,
           Data(SHA256.hash(data: photo)) != expected {
            return .photoAltered
        }

        let commitment = self.commitment

        // Receiver's root assertion: they physically tapped their key on the
        // giver's phone and signed exactly this commitment.
        guard let receiverKey = try? P256.Signing.PublicKey(rawRepresentation: receiver.publicKey),
              receiverAssertion.verify(with: receiverKey),
              CeremonyManager.clientDataChallengeMatches(receiverAssertion.clientDataJSON,
                                                        expected: commitment)
        else { return .receiverSignatureFailed }

        // Giver's device key, chained back to their root credential.
        guard identity.verify(signature: giverSignature, over: commitment,
                              deviceKey: giverDevicePublicKey,
                              claimedRoot: giver, endorsements: giverEndorsements)
        else { return .giverSignatureFailed }

        return .valid
    }
}

// MARK: - Local store

/// Receipts this device holds, as giver or receiver. Keychain-JSON namespaced
/// per identity, same pattern as FriendStore — a receipt is evidence, so it
/// must survive app relaunch and must never leak across identities.
@Observable
final class ReceiptStore {
    private(set) var receipts: [CustodyReceipt] = []
    let ownerHash: String
    private var storageKey: String { "seal.receipts.\(ownerHash)" }

    /// Deliberately does NOT read the keychain — this is constructed inside a
    /// NavigationLink destination, which SwiftUI evaluates on every parent body
    /// pass. Call `loadIfNeeded()` from a `.task` instead.
    init(ownerHash: String) {
        self.ownerHash = ownerHash
    }

    private var didLoad = false
    /// True when a stored blob existed but wouldn't decode. Saving is then
    /// refused, because `save()` writes the whole array — one unreadable blob
    /// would otherwise silently overwrite every receipt the user owns the
    /// moment they added a new one. Receipts are evidence; losing them quietly
    /// is worse than failing loudly.
    private(set) var loadFailed = false

    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = KeychainStore.load(storageKey) else { return }
        if let decoded = try? JSONDecoder().decode([CustodyReceipt].self, from: data) {
            receipts = decoded
        } else {
            loadFailed = true
            ReceiptService.log.error("ReceiptStore: stored receipts wouldn't decode — refusing to overwrite them")
        }
    }

    static func wipe(ownerHash: String) {
        KeychainStore.delete("seal.receipts.\(ownerHash)")
    }

    var sorted: [CustodyReceipt] { receipts.sorted { $0.signedAt > $1.signedAt } }

    func add(_ receipt: CustodyReceipt) {
        loadIfNeeded()
        guard !receipts.contains(where: { $0.receiptID == receipt.receiptID }) else { return }
        receipts.append(receipt)
        save()
    }

    private func save() {
        guard !loadFailed, let data = try? JSONEncoder().encode(receipts) else { return }
        KeychainStore.save(data, for: storageKey)
    }
}

// MARK: - Issue & deliver

enum ReceiptService {
    static let log = Logger(subsystem: "io.github.jasonepage.Seal", category: "receipt")

    /// Fresh 32 bytes so two handovers of identical items between the same two
    /// people can never share a commitment (and so one signature can never be
    /// replayed as the other). CeremonyManager's equivalent is private, so this
    /// keeps the dependency one-way.
    static func randomNonce(_ count: Int = 32) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    enum ReceiptError: LocalizedError {
        case noDeviceKey
        case noRecipientKeys
        var errorDescription: String? {
            switch self {
            case .noDeviceKey: return "This device has no signing key — re-register."
            case .noRecipientKeys: return "They have no message keys published — they need to reopen Seal."
            }
        }
    }

    /// Run the handover ceremony. The RECEIVER taps their key on this (the
    /// giver's) phone, exactly like the friend ceremony — so this must be
    /// called with both people physically present.
    static func issue(item: String,
                      photo: Data?,
                      to receiver: RootIdentity,
                      from myRoot: RootIdentity,
                      identity: IdentityManager,
                      ceremony: CeremonyManager) async throws -> CustodyReceipt {
        guard let deviceKey = identity.deviceKey else { throw ReceiptError.noDeviceKey }

        let nonce = randomNonce()
        let receiptID = UUID().uuidString
        let signedAtEpoch = Int64(Clocks.current.now.timeIntervalSince1970)
        let photoHash = photo.map { Data(SHA256.hash(data: $0)) }

        let commitment = CustodyReceipt.commitment(
            receiptID: receiptID,
            giverHash: myRoot.credentialIDHash,
            receiverHash: receiver.credentialIDHash,
            itemDescription: item,
            photoSHA256: photoHash,
            signedAtEpoch: signedAtEpoch,
            nonce: nonce)

        // Strong half: their hardware key, on this phone, over this commitment.
        // The ceremony rebuilds the commitment from these fields rather than
        // trusting bytes we hand it — see signReceipt.
        let assertion = try await ceremony.signReceipt(
            receiptID: receiptID,
            giverHash: myRoot.credentialIDHash,
            receiverHash: receiver.credentialIDHash,
            itemDescription: item,
            photoSHA256: photoHash,
            signedAtEpoch: signedAtEpoch,
            nonce: nonce,
            counterparty: receiver)
        // Our half: device key, already endorsed by our root credential.
        let signature = try deviceKey.signature(for: commitment)

        return CustodyReceipt(
            receiptID: receiptID,
            giverHash: myRoot.credentialIDHash,
            receiverHash: receiver.credentialIDHash,
            giverName: myRoot.displayName,
            receiverName: receiver.displayName,
            itemDescription: item,
            photoSHA256: photoHash,
            signedAtEpoch: signedAtEpoch,
            nonce: nonce,
            receiverAssertion: assertion,
            giverSignature: signature.derRepresentation,
            giverDevicePublicKey: deviceKey.publicKey.x963Representation,
            mediaRef: nil,
            mediaKey: nil)
    }

    /// Give the receiver their copy. Both halves are E2EE: the photo with its
    /// own content key, and the receipt JSON (which carries that key) wrapped
    /// to the receiver's KEM keys. The public database is world-readable, so
    /// nothing here may be published in the clear.
    static func publish(_ receipt: CustodyReceipt,
                        photo: Data?,
                        receiverEndorsements: [DeviceEndorsement],
                        sync: SyncEngine) async throws -> CustodyReceipt {
        guard !DemoFixtures.isActive else { return receipt }
        var receipt = receipt

        if let photo {
            let contentKey = SymmetricKey(size: .bits256)
            let sealed = try AES.GCM.seal(photo, using: contentKey).combined!
            let ref = "media.\(UUID().uuidString)"
            try await sync.saveMediaAsset(sealed, name: ref)
            receipt.mediaRef = ref
            receipt.mediaKey = contentKey.withUnsafeBytes { Data($0) }
        }

        // Wrap to EVERY endorsed device, same reasoning as message envelopes:
        // our view of "their latest device" may be stale.
        let kems = receiverEndorsements.map(\.kemBundlePublicKeys).filter { !$0.isEmpty }
        guard !kems.isEmpty else { throw ReceiptError.noRecipientKeys }

        let payloadKey = SymmetricKey(size: .bits256)
        let payload = try JSONEncoder().encode(receipt)
        let sealedPayload = try AES.GCM.seal(payload, using: payloadKey).combined!
        let envelope = try HybridKEM.wrapToAll(payloadKey.withUnsafeBytes { Data($0) }, to: kems)

        try await sync.publishReceipt(receiptID: receipt.receiptID,
                                      recipientHash: receipt.receiverHash,
                                      envelope: envelope,
                                      ciphertext: sealedPayload)
        log.info("publish: receipt \(receipt.receiptID, privacy: .public) delivered")
        return receipt
    }

    /// Pull any receipts issued to me. Idempotent — records are never deleted,
    /// so this runs against the same ones forever and must no-op once stored.
    @discardableResult
    static func check(myRoot: RootIdentity,
                      identity: IdentityManager,
                      store: ReceiptStore,
                      sync: SyncEngine) async -> Int {
        guard !DemoFixtures.isActive, let kemKey = identity.kemPrivateKey else { return 0 }
        guard let inbound = try? await sync.fetchReceipts(recipientHash: myRoot.credentialIDHash)
        else { return 0 }

        var added = 0
        for item in inbound {
            guard !store.receipts.contains(where: { $0.receiptID == item.receiptID }) else { continue }
            guard let keyData = try? HybridKEM.unwrap(item.envelope, with: kemKey),
                  let box = try? AES.GCM.SealedBox(combined: item.ciphertext),
                  let plain = try? AES.GCM.open(box, using: SymmetricKey(data: keyData)),
                  let receipt = try? JSONDecoder().decode(CustodyReceipt.self, from: plain)
            else {
                log.error("check: couldn't open receipt \(item.receiptID, privacy: .public)")
                continue
            }
            // Naming us as the receiver proves NOTHING — receiverHash is a
            // field the sender chose, and the public database accepts writes
            // from anyone. Without the signature check below, a stranger could
            // read our public KEM key, wrap any JSON they liked to it, and
            // plant permanent fake evidence in our ledger claiming we took
            // delivery of anything. Verify first, store second.
            guard receipt.receiverHash == myRoot.credentialIDHash,
                  receipt.giverHash != myRoot.credentialIDHash else { continue }

            var directory: [String: (RootIdentity, [DeviceEndorsement])] = [:]
            for hash in [receipt.giverHash, receipt.receiverHash] {
                if let entry = try? await sync.fetchIdentity(credentialIDHash: hash) {
                    directory[hash] = entry
                }
            }
            // No `photo:` — the image lives in CloudKit and isn't needed to
            // check the signatures; the photo HASH is already inside them.
            let verdict = receipt.verify(against: directory, using: identity)
            guard verdict.isValid else {
                log.error("check: REJECTED receipt \(item.receiptID, privacy: .public) — \(String(describing: verdict), privacy: .public)")
                continue
            }
            store.add(receipt)
            added += 1
            log.info("check: stored receipt \(receipt.receiptID, privacy: .public)")
        }
        return added
    }
}
