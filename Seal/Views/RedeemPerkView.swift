import SwiftUI

/// Claim-code redemption sheet (forge packs ship a printed code in the box).
/// Brass appears only at the verified-success moment — the founder signature
/// checking out IS a trust moment.
struct RedeemPerkView: View {
    let myRoot: RootIdentity
    @Bindable var redeemer: PerkRedeemer
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var redeemed: PerkAttestation?

    var body: some View {
        ZStack {
            SealTheme.ink.ignoresSafeArea()
            if let redeemed {
                success(redeemed)
            } else {
                form
            }
        }
        .preferredColorScheme(.dark)
    }

    private var form: some View {
        VStack(spacing: 20) {
            Image(systemName: "ticket")
                .font(.system(size: 44))
                .foregroundStyle(SealTheme.silver)
                .padding(.top, 36)
            Text("Redeem a claim code")
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
            Text("Found a code in your Seal pack? Enter it here. Your phone verifies it was signed by Seal, so nothing is taken on faith.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            TextField("SEAL-XXXXX-XXXXX-XXXXX", text: $code)
                .textFieldStyle(.plain)
                .font(.body.monospaced())
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .padding()
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white)
                .padding(.horizontal, 24)

            if let errorText {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button {
                Task { await redeem() }
            } label: {
                Group {
                    if busy { ProgressView() } else { Text("Verify and claim") }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white.opacity(0.2))
            .disabled(busy || PerkAuthority.normalize(code: code).isEmpty)
            .padding(.horizontal, 24)

            Button("Not now") { dismiss() }
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
        }
    }

    private func success(_ attestation: PerkAttestation) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(SealTheme.brass)
            Text(attestation.grant.kind.displayLabel(number: attestation.grant.number))
                .font(.system(.title, design: .rounded, weight: .bold))
                .foregroundStyle(SealTheme.brass)
            Text("Verified and sealed to your identity. Friends' phones can check this signature themselves — it can't be faked or revoked by a server.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Spacer()
            Button { dismiss() } label: {
                Text("Done")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(SealTheme.brass)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private func redeem() async {
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            let attestation = try await redeemer.redeem(code: code, myRoot: myRoot)
            SealTheme.sealHaptic()
            withAnimation(.spring(duration: 0.4)) { redeemed = attestation }
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "Something went wrong — try again."
        }
    }
}
