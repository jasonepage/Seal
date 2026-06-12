//
//  ContentView.swift
//  Seal
//

import SwiftUI

struct ContentView: View {
    @State private var identity = IdentityManager()
    @State private var ceremony: CeremonyManager?

    var body: some View {
        Group {
            if let root = identity.rootIdentity {
                homePlaceholder(root)
            } else if let ceremony {
                RegistrationView(ceremony: ceremony)
            }
        }
        .onAppear {
            if ceremony == nil { ceremony = CeremonyManager(identity: identity) }
        }
    }

    /// Temporary home screen until ChatUI lands — proves registration persisted.
    private func homePlaceholder(_ root: RootIdentity) -> some View {
        ZStack {
            SealTheme.ink.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(root.tier == .verified ? SealTheme.brass : SealTheme.silver)
                Text(root.displayName)
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                Text(root.tier == .verified ? "Verified — hardware key" : "Passkey")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                Text(root.credentialIDHash.prefix(16))
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.35))

                Button("Reset identity (dev)") {
                    identity.reset()
                    ceremony?.resetPhase()
                }
                .font(.footnote)
                .foregroundStyle(.orange.opacity(0.7))
                .padding(.top, 32)
            }
        }
    }
}

#Preview {
    ContentView()
}
