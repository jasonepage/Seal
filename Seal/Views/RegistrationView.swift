import SwiftUI

/// Onboarding registration (UI.md §3.1): tier choice, then the first tap —
/// the brand moment. Brass appears only at trust moments.
struct RegistrationView: View {
    @Bindable var ceremony: CeremonyManager
    let sync: SyncEngine
    @State private var displayName = ""
    @State private var busy = false
    @State private var showSignInOptions = false
    @AppStorage("seal.welcomeSeen") private var welcomeSeen = false

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

                // Face ID leads, the security key follows (docs/COLDSTART.md
                // 3.3). The hardware key is an upgrade, not a gate; putting it
                // first told most people they were in the wrong app.
                VStack(spacing: 12) {
                    Button { Task { await start(.passkey) } } label: {
                        Label("Set up with Face ID", systemImage: "faceid")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SealTheme.brass)

                    Button { Task { await start(.verified) } } label: {
                        Label("I have a security key", systemImage: "key.radiowaves.forward.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
                .padding(.horizontal, 24)
                .disabled(busy || displayName.trimmingCharacters(in: .whitespaces).isEmpty)

                Button {
                    showSignInOptions = true
                } label: {
                    Text("Already have a seal? Sign in")
                        .font(.footnote)
                        .foregroundStyle(SealTheme.brass.opacity(0.9))
                }
                .disabled(busy)
                .padding(.top, 4)
                .confirmationDialog("Sign in with", isPresented: $showSignInOptions, titleVisibility: .visible) {
                    Button("Face ID (passkey)") { Task { await signIn(.passkey) } }
                    Button("Security key") { Task { await signIn(.verified) } }
                    Button("Cancel", role: .cancel) {}
                }

                Text("Your key is your identity. People are added in person.\nA backup key can bring your identity back.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 16)
            }
            // iPad/large widths: keep the form a centered, readable column
            // instead of stretching fields and buttons edge to edge. No-op on
            // iPhone, where the screen is already narrower than this cap.
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
        // First launch only: set the mental model before the ceremony (UI.md
        // §3.1). Dismisses by flipping the stored flag, so it never shows again.
        .fullScreenCover(isPresented: Binding(
            get: { !welcomeSeen },
            set: { presented in if !presented { welcomeSeen = true } }
        )) {
            WelcomeCarousel { welcomeSeen = true }
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
        case .idle: "Sealed envelopes for the people you leave behind."
        case .searching: "Hold your key flat against the top of your phone…"
        case .reading: "Reading your key…"
        case .endorsing: "One more tap — vouching for this phone…"
        case .sealed: "Sealed. Welcome, \(displayName)."
        case .failed: "Sealed envelopes for the people you leave behind."
        }
    }

    private func start(_ tier: IdentityTier) async {
        let name = displayName.trimmingCharacters(in: .whitespaces)
        // Reviewer/demo access (FR-22): the access code as the name drops into a
        // fully-local demo account — no key or Face ID. Only this exact code
        // triggers it; everyone else registers normally.
        if name.caseInsensitiveCompare(DemoFixtures.accessCode) == .orderedSame {
            ceremony.activateDemo()
            return
        }
        busy = true
        defer { busy = false }
        ceremony.resetPhase()
        _ = try? await ceremony.register(
            tier: tier,
            displayName: name,
            directory: sync   // enables 1-key-1-identity excludedCredentials
        )
    }

    private func signIn(_ tier: IdentityTier) async {
        // Accept the demo access code here too, so a reviewer reaches demo
        // whether they tap a register button or "Sign in".
        if displayName.trimmingCharacters(in: .whitespaces)
            .caseInsensitiveCompare(DemoFixtures.accessCode) == .orderedSame {
            ceremony.activateDemo()
            return
        }
        busy = true
        defer { busy = false }
        ceremony.resetPhase()
        _ = try? await ceremony.signIn(directory: sync, tier: tier)
        // Honest note: identity returns; chats/friends are device-local and
        // may not (they survive reinstalls via keychain, not resets).
    }
}
