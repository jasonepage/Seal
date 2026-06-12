import Foundation
import CloudKit

/// CloudKit transport (SDS §1, §4): public DB for the identity directory,
/// one custom zone per group shared via CKShare. Transport-level share
/// membership is NOT trusted — cryptographic membership is the signed
/// MembershipLog + key epochs.
@Observable
final class SyncEngine {
    /// All inbound records pass the VerificationGate before persistence.
    // TODO: adopt CKSyncEngine; outbox queue for offline sends (NFR-5);
    //       CKSubscription push fan-out; Message/KeyEnvelope/MediaAsset record types.
}

/// Validates every inbound record's signature chain before it reaches
/// the model layer (SDS §3). Unverifiable records are dropped, never shown.
struct VerificationGate {
    let identity: IdentityManager

    func admit(recordPayload: Data, signature: Data, deviceKey: Data, claimedRoot: RootIdentity) -> Bool {
        identity.verify(signature: signature, over: recordPayload, deviceKey: deviceKey, claimedRoot: claimedRoot)
    }
}
