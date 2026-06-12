import SwiftUI

/// The identity ring (UI.md §4): a person's avatar IS their trust status.
/// Brass ring = Verified (hardware key), silver = passkey tier.
struct IdentityRing: View {
    let displayName: String
    let tier: IdentityTier
    var size: CGFloat = 44

    private var ringColor: Color { tier == .verified ? SealTheme.brass : SealTheme.silver }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.06))
            Text(String(displayName.prefix(1)).uppercased())
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
            Circle()
                .strokeBorder(ringColor, lineWidth: size * 0.06)
        }
        .frame(width: size, height: size)
    }
}
