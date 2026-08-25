import Foundation

/// "This phone was recovered with a backup key" (FR-3).
///
/// A recovered phone is in a genuinely reduced state, and the reduction is
/// invisible: the identity is back, the friends are back, everything looks
/// normal — but the root credential is gone, so this phone can neither add
/// another backup key nor revoke the one it used (both ceremonies need a root
/// tap, and the root is what was lost). The identity is frozen at one
/// credential, and ONE more loss takes it for good.
///
/// v1 does not fix that with crypto — a backup key gaining root authority is
/// exactly the takeover the asymmetry exists to prevent, and a quorum design
/// is a v2 problem. What v1 owes the person instead is the truth, said loudly
/// enough that the frozen state is a BRIDGE rather than a destination: start a
/// fresh identity with new keys when you can, and re-friend your family.
///
/// Stored per identity in the keychain, presence = set, exactly like the app
/// lock and Simplified mode (`seal.recovered.<hash>`), so it is wiped by
/// sign-out and by delete along with every other local flag. Two states, not
/// one: the flag itself (this phone was recovered) and an acknowledgement
/// (the one-time card has been seen). The card shows once; the panel notice
/// stays for as long as the phone is in this state, because a bridge nobody
/// is reminded of is a destination.
enum RecoveryNotice {
    private static func flagKey(_ hash: String) -> String { "seal.recovered.\(hash)" }
    private static func seenKey(_ hash: String) -> String { "seal.recovered.seen.\(hash)" }

    /// Record that THIS sign-in used a backup credential. Called only after a
    /// sign-in has fully succeeded — a resolution that later fails
    /// verification, or a ceremony the user cancels mid-way, must not leave a
    /// phone claiming a recovery that never happened.
    static func record(ownerHash: String) {
        KeychainStore.save(Data([1]), for: flagKey(ownerHash))
    }

    /// True while this phone is running on a recovered identity.
    static func isRecovered(ownerHash: String) -> Bool {
        KeychainStore.load(flagKey(ownerHash)) != nil
    }

    /// True when the one-time card still needs to be shown.
    static func needsAcknowledgement(ownerHash: String) -> Bool {
        isRecovered(ownerHash: ownerHash) && KeychainStore.load(seenKey(ownerHash)) == nil
    }

    static func acknowledge(ownerHash: String) {
        KeychainStore.save(Data([1]), for: seenKey(ownerHash))
    }

    static func wipe(ownerHash: String) {
        KeychainStore.delete(flagKey(ownerHash))
        KeychainStore.delete(seenKey(ownerHash))
    }
}
