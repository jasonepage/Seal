import SwiftUI

// Onboarding + friend-ceremony coaching (UI.md §3.1–3.2).
//
// Three goals, one file:
//   1. WelcomeCarousel  — set the mental model BEFORE the first ceremony.
//   2. ForgeHowToCard   — explain the one rule before the first scan.
//   3. Step rail / role banners / passkey-hybrid card — coach each step live.
//
// Brass follows the codebase convention (primary CTAs + trust beats), per
// RegistrationView's existing tinting.

// MARK: - First-run welcome (UI.md §3.1)

/// Three-panel intro shown once before the first registration. Sets the mental
/// model — key = identity, friends are in-person, nothing is recoverable —
/// before the user ever meets a ceremony. Gated by @AppStorage in the caller.
struct WelcomeCarousel: View {
    var onDone: () -> Void
    @State private var page = 0

    private struct Panel: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let body: String
        let brass: Bool
    }

    private let panels: [Panel] = [
        Panel(symbol: "key.radiowaves.forward.fill",
              title: "Your key is your identity",
              body: "No usernames, no phone numbers, no passwords to reset. The key in your pocket — or Face ID — is your whole account.",
              brass: true),
        Panel(symbol: "hand.tap.fill",
              title: "Friends are made in person",
              body: "To add someone you stand together and tap. Anyone can fake an account; no one can fake standing in the room with you.",
              brass: false),
        Panel(symbol: "lock.fill",
              title: "Nothing is recoverable",
              body: "By design. Lose every key and this identity is gone — not even we can bring it back. That's the cost of having no one in the middle.",
              brass: false)
    ]

    var body: some View {
        ZStack {
            SealTheme.ink.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Skip") { onDone() }
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.5))
                        .padding()
                }

                TabView(selection: $page) {
                    ForEach(Array(panels.enumerated()), id: \.element.id) { idx, panel in
                        panelView(panel).tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))

                Button {
                    if page < panels.count - 1 {
                        withAnimation { page += 1 }
                    } else {
                        onDone()
                    }
                } label: {
                    Text(page < panels.count - 1 ? "Next" : "Get started")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(SealTheme.brass)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
        .preferredColorScheme(.dark)
    }

    private func panelView(_ panel: Panel) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: panel.symbol)
                .font(.system(size: 72))
                .foregroundStyle(panel.brass ? SealTheme.brass : SealTheme.silver)
            Text(panel.title)
                .font(.system(.title, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(panel.body)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Spacer()
            Spacer()
        }
    }
}

// MARK: - Forge coach components (shared by FriendsView)

/// Progress rail for the friend ceremony: Scan → Verify → Seal.
struct ForgeStepRail: View {
    let active: Int   // 1, 2, or 3
    private let steps = ["Scan", "Verify", "Seal"]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { idx, label in
                let n = idx + 1
                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(n <= active ? SealTheme.brass : Color.white.opacity(0.12))
                            .frame(width: 22, height: 22)
                        if n < active {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(SealTheme.ink)
                        } else {
                            Text("\(n)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(n == active ? SealTheme.ink : .white.opacity(0.5))
                        }
                    }
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(n <= active ? .white : .white.opacity(0.4))
                }
                if n < steps.count {
                    Rectangle()
                        .fill(n < active ? SealTheme.brass : Color.white.opacity(0.12))
                        .frame(height: 1.5)
                        .frame(maxWidth: 24)
                }
            }
        }
        .padding(.vertical, 10)
    }
}

/// A short, plain-language banner naming WHO does WHAT on WHICH phone.
struct RoleBanner: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(SealTheme.brass)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 24)
    }
}

/// Explains Apple's nearby-device (hybrid) flow so a passkey friend isn't
/// surprised by the system QR sheet mid-ceremony.
struct PasskeyHybridCard: View {
    let friendName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\(friendName) uses Face ID, not a security key", systemImage: "faceid")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text("When you tap below, Apple shows a prompt on THIS phone. \(friendName) chooses “iPhone, iPad, or Android device,” scans the Apple QR with THEIR phone, and approves with Face ID. That second scan is expected.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 24)
    }
}

/// The one-rule explainer shown before the first scan.
struct ForgeHowToCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Forging takes one phone and two people")
                .font(.headline)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            howToRow("1", "viewfinder", "Stand together. Your friend opens Seal and shows their seal.")
            howToRow("2", "qrcode.viewfinder", "On this phone, scan their seal.")
            howToRow("3", "key.radiowaves.forward.fill", "They prove their key right here — a tap, or Face ID on their own phone.")
            howToRow("4", "arrow.triangle.2.circlepath", "Then swap and do it once more on their phone, so you can both message.")
        }
        .padding(20)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 24)
    }

    private func howToRow(_ n: String, _ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(n)
                .font(.system(.caption, weight: .bold))
                .foregroundStyle(SealTheme.ink)
                .frame(width: 20, height: 20)
                .background(SealTheme.brass, in: Circle())
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(SealTheme.brass)
                .frame(width: 20)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
