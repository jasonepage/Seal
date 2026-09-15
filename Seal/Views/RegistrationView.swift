import SwiftUI

/// Onboarding registration (UI.md §3.1): tier choice, then the first tap, 
/// the brand moment. Brass appears only at trust moments.
struct RegistrationView: View {
    @Bindable var ceremony: CeremonyManager
    let sync: SyncEngine
    @State private var displayName = ""
    @State private var busy = false
    @State private var showSignInOptions = false
    @State private var showRetireOptions = false
    @State private var retiredMessage: String?
    @AppStorage("seal.welcomeSeen") private var welcomeSeen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            SealTheme.ink.ignoresSafeArea()
            VStack(spacing: 28) {
                Spacer()

                // The mark, drawn in code (SealMark.swift). Pewter until the
                // ceremony reaches its trust phase, then brass, the same rule
                // the stock symbol followed. It presses in once on appear
                // and lifts a little when the seal is set.
                SealMark(size: 92, trust: phaseIsTrust, pressOnAppear: true)
                    .scaleEffect(ceremony.phase == .sealed && !reduceMotion ? 1.08 : 1.0)
                    .animation(.spring(duration: 0.4), value: ceremony.phase)

                Text("Seal")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)

                Text(statusLine)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.8))
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

                // The name field and the two buttons are one thing to do,
                // so they sit in one block rather than floating 28 points
                // apart like unrelated sections.
                VStack(spacing: 14) {
                    TextField("", text: $displayName,
                              prompt: Text("Your name").foregroundStyle(.white.opacity(0.55)))
                        .textFieldStyle(.plain)
                        .foregroundStyle(.white)
                        .padding()
                        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(.white.opacity(nameIsEmpty ? 0.32 : 0.16), lineWidth: 1)
                        )

                    // Face ID leads, the security key follows (docs/COLDSTART.md
                    // 3.3). The hardware key is an upgrade, not a gate; putting it
                    // first told most people they were in the wrong app.
                    Group {
                        Button { Task { await start(.passkey) } } label: {
                            Label("Set up with Face ID", systemImage: "faceid")
                        }
                        .buttonStyle(SealPrimaryButtonStyle())

                        Button { Task { await start(.verified) } } label: {
                            Label("I have a security key", systemImage: "key.radiowaves.forward.fill")
                        }
                        .buttonStyle(SealSecondaryButtonStyle())
                    }
                    .disabled(busy || nameIsEmpty)

                    // Both buttons are off until there is a name in the
                    // field. Say why, instead of leaving two dim shapes and
                    // no reason for them.
                    if nameIsEmpty {
                        Text("Type your name above to start.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                .padding(.horizontal, 24)

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

                // The escape hatch (RetireKeyCeremony.swift). An identity
                // that sign-in refuses cannot be deleted from the You screen,
                // and its credential blocks "Set up with Face ID" through the
                // exclusion list. One tap on that key retires it here.
                Button {
                    showRetireOptions = true
                } label: {
                    Text("An old key is in the way? Retire it")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.55))
                }
                .disabled(busy)
                .confirmationDialog("Retire a key. Tap the key or passkey you want to retire. The identity under it is deleted for good, and nothing is signed in to.",
                                    isPresented: $showRetireOptions, titleVisibility: .visible) {
                    Button("Face ID (passkey)", role: .destructive) { Task { await retire(.passkey) } }
                    Button("Security key", role: .destructive) { Task { await retire(.verified) } }
                    Button("Cancel", role: .cancel) {}
                }
                .alert("Retired", isPresented: Binding(get: { retiredMessage != nil },
                                                       set: { if !$0 { retiredMessage = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: { Text(retiredMessage ?? "") }

                Text("Your key is your identity. People are added in person.\nA backup key can bring your identity back.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
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

    private var nameIsEmpty: Bool {
        displayName.trimmingCharacters(in: .whitespaces).isEmpty
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
        case .endorsing: "One more tap, vouching for this phone…"
        case .sealed: "Sealed. Welcome, \(displayName)."
        case .failed: "Sealed envelopes for the people you leave behind."
        }
    }

    private func start(_ tier: IdentityTier) async {
        let name = displayName.trimmingCharacters(in: .whitespaces)
        // Reviewer/demo access (FR-22): the access code as the name drops into a
        // fully-local demo account, no key or Face ID. Only this exact code
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

    /// Tombstone an identity without signing into it (RetireKeyCeremony).
    private func retire(_ tier: IdentityTier) async {
        busy = true
        defer { busy = false }
        ceremony.resetPhase()
        do {
            _ = try await ceremony.retireCredential(directory: sync, tier: tier)
            retiredMessage = "That key no longer holds a Seal identity. You can set up a new one now."
        } catch {
            // The ceremony already put the reason into `phase`, which the
            // status line shows in orange.
        }
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
