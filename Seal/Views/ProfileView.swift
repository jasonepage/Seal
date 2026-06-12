import SwiftUI

/// Profile + key management surface (UI.md §3.5, trimmed to what exists).
struct ProfileView: View {
    let myRoot: RootIdentity
    @Bindable var identity: IdentityManager
    let sync: SyncEngine
    @Bindable var ceremony: CeremonyManager
    let onReset: () -> Void

    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                VStack(spacing: 20) {
                    IdentityRing(displayName: myRoot.displayName, tier: myRoot.tier, size: 96)
                        .padding(.top, 32)
                    Text(myRoot.displayName)
                        .font(.system(.title, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                    Label(myRoot.tier == .verified ? "Verified — hardware key" : "Passkey",
                          systemImage: myRoot.tier == .verified ? "key.radiowaves.forward.fill" : "faceid")
                        .font(.subheadline)
                        .foregroundStyle(myRoot.tier == .verified ? SealTheme.brass : SealTheme.silver)

                    Text(FingerprintPhrase.phrase(for: myRoot.publicKey))
                        .font(.title3)
                        .foregroundStyle(SealTheme.brass)

                    VStack(alignment: .leading, spacing: 10) {
                        infoRow("Seal", String(myRoot.credentialIDHash.prefix(24)) + "…")
                        infoRow("Directory", directoryStatus)
                        infoRow("This device", identity.deviceEndorsement != nil ? "Endorsed" : "Not endorsed")
                    }
                    .padding(16)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 24)

                    Spacer()

                    Button(role: .destructive) { confirmReset = true } label: {
                        Text("Reset identity")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }
            }
            .navigationTitle("You")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .confirmationDialog(
                "This deletes your identity, keys, friends, and chats from this device. Nothing can recover it.",
                isPresented: $confirmReset, titleVisibility: .visible
            ) {
                Button("Delete everything", role: .destructive) {
                    onReset()
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var directoryStatus: String {
        switch sync.status {
        case .published: "Published"
        case .publishing: "Publishing…"
        case .idle: "—"
        case .error: "Error — see home"
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.white.opacity(0.5))
            Spacer()
            Text(value)
                .foregroundStyle(.white.opacity(0.9))
                .font(.callout.monospaced())
                .lineLimit(1)
        }
        .font(.callout)
    }
}
