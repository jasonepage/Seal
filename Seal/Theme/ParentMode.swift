import SwiftUI

/// Parent Mode — a per-DEVICE presentation mode (docs/UI.md §Parent Mode).
///
/// The family anti-scam story: an adult child sets Seal up on an aging
/// parent's phone and hands it over simplified. What that means here is
/// deliberately narrow — **presentation only**.
///
/// Nothing underneath moves. Same identity, same friends, same wire format,
/// same signatures, same directory. A Parent Mode phone and a normal phone
/// are the same client to each other, and a chat between the two behaves
/// identically in both directions. Turning this on or off is a local view
/// change, never a migration and never anything a peer can observe.
///
/// Stored per identity in the keychain exactly like the Face ID lock
/// (`seal.parentmode.<hash>`, presence = on — see AppLock.swift), so it is
/// wiped by sign-out and by delete along with every other local flag: a new
/// identity on this phone starts normal.
///
/// **Naming rule.** It is "Simplified mode" in every string a user can read.
/// Never "elderly mode", never "parent mode" — the person holding the phone
/// is reading these strings, and the whole point is that the phone doesn't
/// treat them as a category.
@Observable
final class ParentMode {
    private(set) var isOn: Bool
    let ownerHash: String

    private var storageKey: String { "seal.parentmode.\(ownerHash)" }

    init(ownerHash: String) {
        self.ownerHash = ownerHash
        // `-SealParentDemo` forces the mode on for screenshots WITHOUT writing
        // the keychain, so a demo launch can never leave the setting behind on
        // a real identity (DemoFixtures parks the real identity, but the flag
        // is namespaced by hash and would outlive the demo otherwise).
        if DemoFixtures.parentDemoRequested {
            isOn = true
        } else {
            isOn = KeychainStore.load("seal.parentmode.\(ownerHash)") != nil
        }
    }

    static func wipe(ownerHash: String) {
        KeychainStore.delete("seal.parentmode.\(ownerHash)")
    }

    /// No authentication gate, unlike AppLock: this changes how the app looks,
    /// not what it protects, and a parent who has ended up in the wrong mode
    /// must be able to get out of it without a ceremony.
    func setEnabled(_ enabled: Bool) {
        if enabled {
            KeychainStore.save(Data([1]), for: storageKey)
        } else {
            KeychainStore.delete(storageKey)
        }
        isOn = enabled
    }
}

// MARK: - Environment

private struct ParentModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while this device is presenting Seal in Parent Mode. Injected once
    /// by `HomeView`; every surface below reads it rather than being handed a
    /// flag through five initialisers.
    var parentMode: Bool {
        get { self[ParentModeKey.self] }
        set { self[ParentModeKey.self] = newValue }
    }
}

// MARK: - Type scale

extension DynamicTypeSize {
    /// The next size up, or self at the ceiling.
    ///
    /// Parent Mode treats the user's own Dynamic Type setting as a FLOOR, not
    /// a ceiling: someone who has already set accessibility XL asked for that
    /// size and gets one step beyond it, not a reset to some fixed "large".
    /// At `.accessibility5` there is nowhere further to go, so this is a no-op
    /// rather than a clamp back down.
    var oneStepLarger: DynamicTypeSize {
        let all = DynamicTypeSize.allCases
        guard let index = all.firstIndex(of: self), index + 1 < all.count else { return self }
        return all[index + 1]
    }
}

/// Bumps everything below it one Dynamic Type class while Parent Mode is on.
///
/// APPLY THIS EXACTLY ONCE PER PRESENTATION TREE. It reads the current size
/// from the environment and writes a larger one back, so a second application
/// further down would bump twice and blow past what the user actually asked
/// for. `ChatsView` applies it at the top of the split view, which covers the
/// chat list, the open chat, and every sheet those present; `HomeView`
/// applies it to the profile sheet, which is a separate branch of the tree.
struct ParentTypeScale: ViewModifier {
    @Environment(\.parentMode) private var parentMode
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ViewBuilder
    func body(content: Content) -> some View {
        if parentMode {
            content.dynamicTypeSize(dynamicTypeSize.oneStepLarger)
        } else {
            content
        }
    }
}

/// Minimum tap target in Parent Mode. 52pt, above the 44pt HIG floor, because
/// the hands this is designed for are less accurate and the cost of a mis-tap
/// on a screen carrying payment instructions is not symmetric.
struct ParentTapTarget: ViewModifier {
    @Environment(\.parentMode) private var parentMode
    var minimum: CGFloat = 52

    @ViewBuilder
    func body(content: Content) -> some View {
        if parentMode {
            content
                .frame(minHeight: minimum)
                .contentShape(Rectangle())
        } else {
            content
        }
    }
}

extension View {
    func parentTypeScale() -> some View { modifier(ParentTypeScale()) }
    func parentTapTarget(_ minimum: CGFloat = 52) -> some View {
        modifier(ParentTapTarget(minimum: minimum))
    }
}
