// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
    @FocusState private var nameFocused: Bool
    @AppStorage("seal.welcomeSeen") private var welcomeSeen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            SealTheme.ink.ignoresSafeArea()
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 24) {
                        VStack(spacing: 14) {
                            SealMark(size: 78, trust: phaseIsTrust, pressOnAppear: true)
                                .scaleEffect(ceremony.phase == .sealed && !reduceMotion ? 1.08 : 1.0)
                                .animation(.spring(duration: 0.4), value: ceremony.phase)

                            VStack(spacing: 6) {
                                Text("PASS DOWN A SECRET LETTER")
                                    .font(.caption2.weight(.bold))
                                    .tracking(1.3)
                                    .foregroundStyle(SealTheme.brass)
                                Text("Welcome to Seal")
                                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                                    .foregroundStyle(.white)
                                Text(statusLine)
                                    .font(.body)
                                    .foregroundStyle(.white.opacity(0.72))
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if case .failed(let reason) = ceremony.phase {
                            Text(reason)
                                .font(.footnote)
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            Text("What should people call you?")
                                .font(.headline)
                                .foregroundStyle(.white)
                            TextField("", text: $displayName,
                                      prompt: Text("Your name").foregroundStyle(.white.opacity(0.45)))
                                .textFieldStyle(.plain)
                                .textContentType(.name)
                                .submitLabel(.continue)
                                .focused($nameFocused)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .frame(minHeight: 56)
                                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(nameFocused ? SealTheme.brass.opacity(0.8) : .white.opacity(0.14), lineWidth: 1)
                                )
                                .onSubmit {
                                    guard !busy, !nameIsEmpty else { return }
                                    Task { await start(.passkey) }
                                }

                            Button { Task { await start(.passkey) } } label: {
                                HStack(spacing: 10) {
                                    if busy { ProgressView().tint(SealTheme.ink) }
                                    Label("Continue with \(Biometry.name)", systemImage: Biometry.symbol)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(SealPrimaryButtonStyle())
                            .disabled(busy || nameIsEmpty)

                            HStack {
                                Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
                                Text("or")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.4))
                                Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
                            }

                            Button { Task { await start(.verified) } } label: {
                                Label("Use a security key instead", systemImage: "key.radiowaves.forward.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(SealSecondaryButtonStyle())
                            .disabled(busy || nameIsEmpty)
                        }
                        .padding(20)
                        .background(
                            LinearGradient(colors: [.white.opacity(0.08), SealTheme.brass.opacity(0.05)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(.white.opacity(0.08), lineWidth: 1)
                        }

                        VStack(spacing: 14) {
                            Button("Already use Seal? Sign in") { showSignInOptions = true }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(SealTheme.brass)
                                .disabled(busy)
                            Button("Trouble with an old key?") { showRetireOptions = true }
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.5))
                                .disabled(busy)
                        }
                        .confirmationDialog("Sign in with", isPresented: $showSignInOptions, titleVisibility: .visible) {
                            Button("\(Biometry.title) (passkey)") { Task { await signIn(.passkey) } }
                            Button("Security key") { Task { await signIn(.verified) } }
                            Button("Cancel", role: .cancel) {}
                        }
                        .confirmationDialog("Retire a key. Tap the key or passkey you want to retire. The account under it is deleted for good, and you are not signed in.",
                                            isPresented: $showRetireOptions, titleVisibility: .visible) {
                            Button("\(Biometry.title) (passkey)", role: .destructive) { Task { await retire(.passkey) } }
                            Button("Security key", role: .destructive) { Task { await retire(.verified) } }
                            Button("Cancel", role: .cancel) {}
                        }
                        .alert("Retired", isPresented: Binding(get: { retiredMessage != nil },
                                                               set: { if !$0 { retiredMessage = nil } })) {
                            Button("OK", role: .cancel) {}
                        } message: { Text(retiredMessage ?? "") }

                        Label("Your letters stay private. Seal cannot read them.", systemImage: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.48))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 28)
                    .frame(maxWidth: 460)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geo.size.height)
                    .containerRelativeFrame(.horizontal)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
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
        case .idle: "Private letters, opened on your terms."
        case .searching: "Hold your key flat against the top of your phone…"
        case .reading: "Reading your key…"
        case .endorsing: "One more tap, vouching for this phone…"
        case .sealed: "Sealed. Welcome, \(displayName)."
        case .failed: "Private letters, opened on your terms."
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
            retiredMessage = "That key no longer has a Seal account. You can set up a new one now."
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
