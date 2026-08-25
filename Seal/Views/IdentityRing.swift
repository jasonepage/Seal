import SwiftUI

/// The identity ring (UI.md §4): a person's avatar IS their trust status.
/// Brass ring = Verified (hardware key), silver = passkey tier.
struct IdentityRing: View {
    let displayName: String
    let tier: IdentityTier
    var size: CGFloat = 44
    /// This friendship came from an INTRODUCTION, not a ceremony
    /// (docs/INTRODUCTIONS.md). It overrides the tier colour completely:
    /// brass means a key was tapped in front of you, and a linked friend's
    /// wasn't — whatever kind of key they hold.
    ///
    /// Silver, DASHED (docs/TRUST.md §5.1 already calls vouched edges dashed),
    /// plus a `link` glyph so the difference survives greyscale, colour
    /// blindness and a 26pt colony bar (the ColonyBar reverses its zIndex so
    /// the glyph isn't painted over by the next ring).
    ///
    /// **It defaults to false, so it is opt-in — any NEW call site that can
    /// render a FRIEND must pass it**, or that friend silently gets a brass
    /// ring they did not earn. The call sites that don't pass it are the ones
    /// that can only ever draw the local user (Profile, the Parent Mode
    /// toolbar) or an already-filtered in-person list (the forge log, the
    /// introduce picker).
    var linked: Bool = false

    private var ringColor: Color { tier == .verified ? SealTheme.brass : SealTheme.silver }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.06))
            Text(String(displayName.prefix(1)).uppercased())
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
            if linked {
                Circle()
                    .strokeBorder(SealTheme.silver,
                                  style: StrokeStyle(lineWidth: size * 0.06,
                                                     dash: [size * 0.16, size * 0.11]))
            } else {
                Circle()
                    .strokeBorder(ringColor, lineWidth: size * 0.06)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if linked {
                Image(systemName: "link")
                    .font(.system(size: size * 0.28, weight: .bold))
                    .foregroundStyle(SealTheme.silver)
                    .padding(size * 0.07)
                    .background(Circle().fill(SealTheme.ink))
            }
        }
    }
}
