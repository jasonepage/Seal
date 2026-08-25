import SwiftUI

//  IntroduceSheet.swift
//  Seal
//
//  The introducer's side: pick a second person, see exactly what will be
//  shared, sign it.
//
//  The picker only ever lists IN-PERSON friends. That is a rule, not a
//  convenience — `ChatEngine.sendIntroduction` re-checks it, and so does every
//  recipient before accepting (docs/INTRODUCTIONS.md). A linked friend never
//  appears here, and reaching this screen from a linked friend's row is
//  impossible by construction: the row that opens it isn't drawn for them.
//
//  Not brass. An introduction is a claim about people you met, made from a
//  couch, with no key in your hand — silver, like everything else this feature
//  touches (UI.md §1).

struct IntroduceSheet: View {
    /// The friend whose row/drawer this was opened from — one half of the pair.
    let subject: FriendStore.StoredFriend
    let myRoot: RootIdentity
    @Bindable var engine: ChatEngine
    @Bindable var friendStore: FriendStore
    @Environment(\.dismiss) private var dismiss

    @State private var picked: FriendStore.StoredFriend?
    @State private var sending = false
    @State private var failure: String?
    @State private var sent = false

    private var candidates: [FriendStore.StoredFriend] {
        friendStore.friends
            .filter { $0.id != subject.id }
            .filter { $0.id != myRoot.credentialIDHash }
            .filter { $0.friendship.isInPerson }
            .sorted { $0.identity.displayName.localizedCaseInsensitiveCompare($1.identity.displayName) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if sent {
                            sentView
                        } else if let picked {
                            confirmView(picked)
                        } else {
                            pickerView
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .navigationTitle(sent ? "Introduced" : "Introduce")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(sent ? "Done" : "Cancel") { dismiss() }
                        .foregroundStyle(.white.opacity(0.7))
                }
                if picked != nil, !sent {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back") { picked = nil }
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Pick

    private var pickerView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Introduce \(subject.identity.displayName) to…")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)

            Text("Pick someone you've also met in person. Seal will tell both of them that you vouched for the connection, and they can accept or ignore it.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)

            if !subject.friendship.isInPerson {
                notice("You haven't met \(subject.identity.displayName) in person through Seal — they're a linked friend. An introduction has to come from someone who has met BOTH people, so this one can't start here.")
            } else if candidates.isEmpty {
                notice("You need two people you've met in person to make an introduction. Forge one more friendship in Circle and this opens up.")
            } else {
                VStack(spacing: 0) {
                    ForEach(candidates) { friend in
                        Button { picked = friend } label: {
                            HStack(spacing: 12) {
                                IdentityRing(displayName: friend.identity.displayName,
                                             tier: friend.identity.tier, size: 38)
                                Text(friend.identity.displayName)
                                    .font(.system(.body, design: .rounded, weight: .medium))
                                    .foregroundStyle(.white)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.3))
                            }
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .parentTapTarget(60)
                        Divider().overlay(Color.white.opacity(0.08))
                    }
                }
                .padding(.horizontal, 14)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    // MARK: - Confirm

    private func confirmView(_ other: FriendStore.StoredFriend) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                IdentityRing(displayName: subject.identity.displayName,
                             tier: subject.identity.tier, size: 44)
                Image(systemName: "link")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(SealTheme.silver)
                IdentityRing(displayName: other.identity.displayName,
                             tier: other.identity.tier, size: 44)
                Spacer()
            }

            Text("Introduce \(subject.identity.displayName) and \(other.identity.displayName)")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            // Exactly what leaves this phone. Written as a list because a
            // paragraph about what you're sharing is a paragraph people skip.
            VStack(alignment: .leading, spacing: 10) {
                shareRow("person.text.rectangle",
                         "\(subject.identity.displayName)'s name and identity key go to \(other.identity.displayName) — and \(other.identity.displayName)'s go to \(subject.identity.displayName).")
                shareRow("signature",
                         "Both of them see that YOU made the introduction, signed by this phone.")
                shareRow("eye.slash",
                         "Nothing else. Not your other friends, not your chats, not anyone else's keys.")
            }
            .padding(14)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))

            Text("They become LINKED friends, not brass. Seal will show them that they haven't met in person and that you vouched — a linked friendship is exactly as trustworthy as your judgment, and it says so on both their phones.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)

            Text("Either of them can ignore it. You'll only ever see whether it's been accepted — never who said no.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)

            if let failure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                send(to: other)
            } label: {
                HStack(spacing: 8) {
                    if sending { ProgressView().tint(SealTheme.ink) }
                    Text(sending ? "Signing…" : "Introduce them")
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(SealTheme.ink)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(SealTheme.silver)
            .disabled(sending)
            .parentTapTarget()
        }
    }

    private func shareRow(_ glyph: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: glyph)
                .font(.system(size: 13))
                .foregroundStyle(SealTheme.silver)
                .frame(width: 18)
            Text(text)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Sent

    private var sentView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "link.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(SealTheme.silver)
            Text("Introduction sent")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
            Text("Both of them have it now. They become linked once each of them accepts — you'll see it in your chat with them.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.orange.opacity(0.9))
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private func send(to other: FriendStore.StoredFriend) {
        sending = true
        failure = nil
        Task {
            let result = await engine.sendIntroduction(subject, and: other,
                                                       from: myRoot, friendStore: friendStore)
            sending = false
            if let result {
                failure = result
            } else {
                sent = true
            }
        }
    }
}
