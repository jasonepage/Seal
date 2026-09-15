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

/// Three-panel intro shown once before the first registration. Reason first,
/// rule second, expectation third (docs/COLDSTART.md 3.2). It used to lead
/// with the key, the in-person rule and "nothing is recoverable": two
/// warnings and a threat before a single reason. The recovery honesty now
/// lives on the registration footer and in BackupKeyPrompt, which is a
/// better place for it because the person is holding their key at that
/// moment. Gated by @AppStorage in the caller.
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
        Panel(symbol: "lock.shield.fill",
              title: "For the things you never told anybody",
              body: "The passwords. Where the safe deposit key is. The combination. The seed phrase. A letter to each of them. Sealed now, opened only after you are gone, by people you chose.",
              brass: true),
        Panel(symbol: "hand.tap.fill",
              title: "Nobody can open one early",
              body: "Not Apple, not us. It takes your custodians' physical keys, after a long silence from you, after weeks of warnings you can stop with one tap.",
              brass: false),
        Panel(symbol: "person.2.fill",
              title: "Keys change hands in person",
              body: "You hand a security key to each custodian, standing next to them, once. Their tap on your phone is the receipt. After that they do nothing for years.",
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
            Text("Adding someone takes two people and one phone")
                .font(.headline)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            howToRow("1", "viewfinder", "Stand together. Open Seal on both phones.")
            howToRow("2", "qrcode.viewfinder", "They show their seal. You scan it on this phone.")
            howToRow("3", "key.radiowaves.forward.fill", "They prove their key right here, with a tap or with Face ID on their own phone.")
            // Step 4 used to say "swap and do it once more on their phone".
            // ForgeHandshake.swift removed that: the phone that ran the
            // ceremony publishes a device-signed handshake and the other side
            // completes with zero user actions. The copy was still charging
            // friction the code had already paid off (docs/COLDSTART.md 2.2).
            howToRow("4", "checkmark.seal.fill", "That's it. You're both connected. Their phone catches up on its own.")
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
