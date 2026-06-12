import SwiftUI

/// The forge log (VISION.md): a verifiable diary of every human you've met.
/// Each entry is backed by a signed ceremony attestation — not a claim, a proof.
struct ForgeLogView: View {
    let myRoot: RootIdentity
    @Bindable var friendStore: FriendStore

    private var sorted: [FriendStore.StoredFriend] {
        friendStore.friends.sorted { $0.friendship.forgedAt > $1.friendship.forgedAt }
    }

    private var verifiedCount: Int {
        friendStore.friends.filter { $0.identity.tier == .verified }.count
    }

    private var monthsActive: Int {
        let months = Set(friendStore.friends.map {
            Calendar.current.dateComponents([.year, .month], from: $0.friendship.forgedAt)
        })
        return months.count
    }

    var body: some View {
        ZStack {
            SealTheme.ink.ignoresSafeArea()
            VStack(spacing: 16) {
                // Stats header
                HStack(spacing: 12) {
                    stat("\(friendStore.friends.count)", "forged")
                    stat("\(verifiedCount)", "verified")
                    stat("\(monthsActive)", monthsActive == 1 ? "month" : "months")
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                if sorted.isEmpty {
                    Spacer()
                    Text("Every friendship you forge is recorded here —\nsigned proof that you met.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                    Spacer()
                } else {
                    List {
                        ForEach(sorted) { friend in
                            HStack(spacing: 12) {
                                IdentityRing(displayName: friend.identity.displayName,
                                             tier: friend.identity.tier, size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(friend.identity.displayName)
                                        .font(.system(.body, design: .rounded, weight: .medium))
                                        .foregroundStyle(.white)
                                    Text(FingerprintPhrase.phrase(for: friend.identity.publicKey))
                                        .font(.caption)
                                        .foregroundStyle(SealTheme.brass.opacity(0.8))
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(friend.friendship.forgedAt, format: .dateTime.month(.abbreviated).day())
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.6))
                                    Text(friend.friendship.forgedAt, format: .dateTime.year())
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.35))
                                }
                            }
                            .listRowBackground(Color.white.opacity(0.05))
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .navigationTitle("Forge log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .preferredColorScheme(.dark)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(SealTheme.brass)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }
}
