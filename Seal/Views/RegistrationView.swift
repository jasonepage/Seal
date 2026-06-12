import SwiftUI

/// Onboarding registration (UI.md §3.1): tier choice, then the first tap —
/// the brand moment. Brass appears only at trust moments.
struct RegistrationView: View {
    @Bindable var ceremony: CeremonyManager
    let sync: SyncEngine
    @State private var displayName = ""
    @State private var busy = false

    var body: some View {
        ZStack {
            SealTheme.ink.ignoresSafeArea()
            VStack(spacing: 28) {
                Spacer()

                Image(systemName: "seal.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(phaseIsTrust ? SealTheme.brass : SealTheme.silver)
                    .scaleEffect(ceremony.phase == .sealed ? 1.15 : 1.0)
                    .animation(.spring(duration: 0.4), value: ceremony.phase)

                Text("Seal")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)

                Text(statusLine)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer()

                if case .failed(let reason) = ceremony.phase {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                TextField("Your name", text: $displayName)
                    .textFieldStyle(.plain)
                    .padding()
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)

                VStack(spacing: 12) {
                    Button { Task { await start(.verified) } } label: {
                        Label("I have a security key", systemImage: "key.radiowaves.forward.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SealTheme.brass)

                    Button { Task { await start(.passkey) } } label: {
                        Label("Start with Face ID", systemImage: "faceid")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
                .padding(.horizontal, 24)
                .disabled(busy || displayName.trimmingCharacters(in: .whitespaces).isEmpty)

                Button {
                    Task { await signIn() }
                } label: {
                    Text("Already have a seal? Sign in")
                        .font(.footnote)
                        .foregroundStyle(SealTheme.brass.opacity(0.9))
                }
                .disabled(busy)
                .padding(.top, 4)

                Text("Your key is your identity. Friends are made in person.\nNothing is recoverable — by design.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 16)
            }
        }
    }

    private var phaseIsTrust: Bool {
        switch ceremony.phase {
        case .endorsing, .sealed: true
        default: false
        }
    }

    private var statusLine: String {
        switch ceremony.phase {
        case .idle: "Group chat for people you've actually met."
        case .searching: "Hold your key flat against the top of your phone…"
        case .reading: "Reading your key…"
        case .endorsing: "One more tap — vouching for this phone…"
        case .sealed: "Sealed. Welcome, \(displayName)."
        case .failed: "Group chat for people you've actually met."
        }
    }

    private func start(_ tier: IdentityTier) async {
        busy = true
        defer { busy = false }
        ceremony.resetPhase()
        _ = try? await ceremony.register(
            tier: tier,
            displayName: displayName.trimmingCharacters(in: .whitespaces)
        )
    }

    private func signIn() async {
        busy = true
        defer { busy = false }
        ceremony.resetPhase()
        _ = try? await ceremony.signIn(directory: sync)
        // Honest note: identity returns; chats/friends are device-local and
        // may not (they survive reinstalls via keychain, not resets).
    }
}
