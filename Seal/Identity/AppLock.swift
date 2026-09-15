import SwiftUI
import LocalAuthentication

/// Face ID app lock (SRS TODO → done): gates the app's content behind
/// device-owner authentication on launch and on return from background.
/// Per-identity setting, stored in the keychain like every other local
/// state (`seal.applock.<hash>`); wiped on sign-out.
///
/// Uses `.deviceOwnerAuthentication` (biometry with passcode fallback) so a
/// Face ID lockout can't brick the app. Fail-open when no passcode is set, 
/// a passcode-less device has no keychain protection to add anyway.
@Observable
final class AppLock {
    private(set) var isEnabled: Bool
    private(set) var isLocked: Bool
    let ownerHash: String

    private var storageKey: String { "seal.applock.\(ownerHash)" }

    init(ownerHash: String) {
        self.ownerHash = ownerHash
        let enabled = KeychainStore.load("seal.applock.\(ownerHash)") != nil
        isEnabled = enabled
        // Demo mode never locks, fixtures must screenshot cleanly.
        isLocked = enabled && !DemoFixtures.isActive
    }

    static func wipe(ownerHash: String) {
        KeychainStore.delete("seal.applock.\(ownerHash)")
        KeychainStore.delete("seal.cardlock.\(ownerHash)")
    }

    var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// Toggling either way requires authenticating first, otherwise anyone
    /// holding an unlocked phone could quietly disable the lock.
    func setEnabled(_ enabled: Bool) async {
        guard await Self.authenticate(reason: enabled
            ? "Confirm to require Face ID for Seal"
            : "Confirm to remove the Face ID lock") else { return }
        if enabled {
            KeychainStore.save(Data([1]), for: storageKey)
            isEnabled = true
        } else {
            KeychainStore.delete(storageKey)
            isEnabled = false
            isLocked = false
        }
    }

    /// Call when the app leaves the foreground.
    func lockIfEnabled() {
        if isEnabled, !DemoFixtures.isActive { isLocked = true }
    }

    func unlock() async {
        guard isLocked else { return }
        if await Self.authenticate(reason: "Unlock Seal") {
            isLocked = false
        }
    }

    // MARK: - Sealed-card confirmation

    /// "Face ID to seal a card": a second, independent per-identity flag
    /// (`seal.cardlock.<hash>`). Static API on purpose: the envelope editor is
    /// constructed without an AppLock instance, and the check is a
    /// single keychain read plus one LAContext prompt at the commit moment,
    /// not ongoing state. Protects against someone holding the UNLOCKED phone
    /// sending a sealed money request as its owner; it is unrelated to SIM
    /// swapping, which never touched Seal in the first place.
    private static func cardLockKey(_ ownerHash: String) -> String { "seal.cardlock.\(ownerHash)" }

    static func isCardLockEnabled(ownerHash: String) -> Bool {
        KeychainStore.load(cardLockKey(ownerHash)) != nil
    }

    /// Toggling either way authenticates first, same rationale as
    /// `setEnabled`. Returns the state actually in effect afterwards, so the
    /// caller's toggle snaps back on a failed or cancelled prompt.
    static func setCardLockEnabled(_ enabled: Bool, ownerHash: String) async -> Bool {
        guard await authenticate(reason: enabled
            ? "Confirm to require Face ID when sealing a card"
            : "Confirm to remove the sealed-card Face ID check") else {
            return isCardLockEnabled(ownerHash: ownerHash)
        }
        if enabled {
            KeychainStore.save(Data([1]), for: cardLockKey(ownerHash))
        } else {
            KeychainStore.delete(cardLockKey(ownerHash))
        }
        return enabled
    }

    /// Called before an envelope's secrets are revealed or sealed. True = proceed.
    /// Fail-closed on a failed prompt; demo mode skips, matching the app lock.
    static func confirmSeal(ownerHash: String) async -> Bool {
        guard isCardLockEnabled(ownerHash: ownerHash), !DemoFixtures.isActive else { return true }
        return await authenticate(reason: "Confirm it's you to seal and send")
    }

    private static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            return true     // no passcode on device: nothing meaningful to gate behind
        }
        return (try? await context.evaluatePolicy(
            .deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

/// Full-screen cover while locked. Brass shield, a trust surface, no mascot.
struct AppLockScreen: View {
    let lock: AppLock

    var body: some View {
        ZStack {
            SealTheme.ink.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(SealTheme.brass)
                Text("Seal is locked")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                Button {
                    Task { await lock.unlock() }
                } label: {
                    Text("Unlock")
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .padding(.horizontal, 36)
                        .padding(.vertical, 12)
                        .background(SealTheme.brass, in: Capsule())
                        .foregroundStyle(SealTheme.ink)
                }
                .padding(.top, 8)
            }
        }
        .task { await lock.unlock() }   // prompt immediately on appear
    }
}
