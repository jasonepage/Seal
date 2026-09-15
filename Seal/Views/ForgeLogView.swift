import SwiftUI

/// The forge log (VISION.md): a verifiable diary of every human you've met.
/// Each entry is backed by a signed ceremony attestation, not a claim, a proof.
struct ForgeLogView: View {
    let myRoot: RootIdentity
    @Bindable var friendStore: FriendStore

    /// IN-PERSON friendships only. This screen is "signed proof that you
    /// met", and the share card literally says "Every friendship forged in
    /// person", a LINKED friendship (docs/INTRODUCTIONS.md) was never forged,
    /// has no ceremony date worth printing, and must never be counted here.
    /// Listing them with a forge date would make the one screen whose whole
    /// claim is physical presence quietly untrue.
    private var forged: [FriendStore.StoredFriend] {
        friendStore.friends.filter { $0.friendship.isInPerson }
    }

    private var sorted: [FriendStore.StoredFriend] {
        forged.sorted { $0.friendship.forgedAt > $1.friendship.forgedAt }
    }

    /// Introduced friends, which the log deliberately does not list. Counted
    /// so the omission is stated rather than silently swallowing people the
    /// user can see everywhere else in the app.
    private var linkedCount: Int {
        friendStore.friends.count - forged.count
    }

    private var verifiedCount: Int {
        forged.filter { $0.identity.tier == .verified }.count
    }

    private var monthsActive: Int {
        let months = Set(forged.map {
            Calendar.current.dateComponents([.year, .month], from: $0.friendship.forgedAt)
        })
        return months.count
    }

    /// One person. Pulled out of `body` because the perk line that used to
    /// live here went with the messenger and the compiler gave up on the
    /// whole expression rather than naming the missing property.
    private func row(_ friend: FriendStore.StoredFriend) -> some View {
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

    var body: some View {
        ZStack {
            SealTheme.ink.ignoresSafeArea()
            VStack(spacing: 16) {
                // Stats header
                HStack(spacing: 12) {
                    stat("\(forged.count)", "in person")
                    stat("\(verifiedCount)", "verified")
                    stat("\(monthsActive)", monthsActive == 1 ? "month" : "months")
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                if sorted.isEmpty {
                    Spacer()
                    SealMascot(size: 52,
                               line: "Your history is empty.",
                               sub: "Everyone you add in person is recorded here,\nsigned proof that you met.")
                    Spacer()
                } else {
                    List {
                        ForEach(sorted) { friend in
                            row(friend)
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .preferredColorScheme(.dark)
        .toolbar {
            if let shareCard {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(
                        item: shareCard,
                        preview: SharePreview("My Seal history", image: shareCard)
                    ) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(SealTheme.brass)
                    }
                }
            }
        }
        .onAppear { renderShareCard() }
        // `forged.count`, not `friends.count`: FriendStore.add is
        // remove-then-append, so a LINKED friend who later forges in person
        // leaves the total unchanged while the forged count rises, and the
        // share card would keep printing the old, too-low number.
        .onChange(of: forged.count) { renderShareCard() }
    }

    // MARK: - Share card (growth surface: the forge log as a postable object)

    @State private var shareCard: Image?

    @MainActor
    private func renderShareCard() {
        guard !forged.isEmpty else { shareCard = nil; return }
        let renderer = ImageRenderer(content: ForgeShareCard(
            name: myRoot.displayName,
            forged: forged.count,
            verified: verifiedCount,
            months: monthsActive))
        renderer.scale = 3
        if let ui = renderer.uiImage {
            shareCard = Image(uiImage: ui)
        }
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

/// The shareable forge log: real-world social life as a verifiable brag.
/// Rendered offscreen via ImageRenderer, keep it fixed-size and self-contained.
struct ForgeShareCard: View {
    let name: String
    let forged: Int
    let verified: Int
    let months: Int

    var body: some View {
        VStack(spacing: 0) {
            SealFigure(detailed: true, animated: false, tint: SealTheme.brass)
                .frame(width: 110, height: 70)
                .padding(.top, 36)

            Text("\(forged)")
                .font(.system(size: 88, weight: .bold, design: .rounded))
                .foregroundStyle(SealTheme.brass)
                .padding(.top, 12)
            Text(forged == 1 ? "person met" : "people met")
                .font(.system(.title3, design: .rounded, weight: .medium))
                .foregroundStyle(.white)

            HStack(spacing: 14) {
                if verified > 0 {
                    Label("\(verified) verified", systemImage: "key.radiowaves.forward.fill")
                }
                Label(months == 1 ? "1 month" : "\(months) months", systemImage: "calendar")
            }
            .font(.system(.footnote, design: .rounded, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
            .padding(.top, 14)

            Spacer()

            VStack(spacing: 3) {
                Text("\(name)'s Seal history")
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                Text("Everyone added in person · sealmessenger.com")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.bottom, 28)
        }
        .frame(width: 340, height: 400)
        .background(SealTheme.ink)
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .strokeBorder(SealTheme.brass.opacity(0.5), lineWidth: 2)
                .padding(10)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }
}
