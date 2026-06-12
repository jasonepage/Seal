import SwiftUI
import LocalAuthentication

/// Face ID app lock (SRS TODO → done): gates the app's content behind
/// device-owner authentication on launch and on return from background.
/// Per-identity setting, stored in the keychain like every other local
/// state (`seal.applock.<hash>`); wiped on sign-out.
///
/// Uses `.deviceOwnerAuthentication` (biometry with passcode fallback) so a
/// Face ID lockout can't brick the app. Fail-open when no passcode is set —
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
        // Demo mode never locks — fixtures must screenshot cleanly.
        isLocked = enabled && !DemoFixtures.isActive
    }

    static func wipe(ownerHash: String) {
        KeychainStore.delete("seal.applock.\(ownerHash)")
    }

    var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// Toggling either way requires authenticating first — otherwise anyone
    /// holding an unlocked phone could quietly disable the lock.
    func setEnabled(_ enabled: Bool) async {
        guard await authenticate(reason: enabled
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
        if await authenticate(reason: "Unlock Seal") {
            isLocked = false
        }
    }

    private func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            return true     // no passcode on device: nothing meaningful to gate behind
        }
        return (try? await context.evaluatePolicy(
            .deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

/// Full-screen cover while locked. Brass shield — a trust surface, no mascot.
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
