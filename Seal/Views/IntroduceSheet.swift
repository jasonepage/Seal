import SwiftUI

//  IntroduceSheet.swift
//  Seal
//
//  The introducer's side: pick two people you've met in person, see exactly
//  what will be shared, sign it.
//
//  TWO WAYS IN, ONE SHEET. From Circle's "Introduce two friends" button
//  nothing is pre-chosen, so this asks for both — which is what the operation
//  actually is: one statement naming two people, symmetric, with no first and
//  second. From a friend's long-press menu or the verification drawer, that
//  person arrives as `subject` and the sheet skips straight to picking who
//  they meet.
//
//  Every list here is IN-PERSON friends only. That is a rule, not a
//  convenience — `ChatEngine.sendIntroduction` re-checks it, and so does every
//  recipient before accepting (docs/INTRODUCTIONS.md §3.1). A linked friend
//  never appears.
//
//  Not brass. An introduction is a claim about people you met, made from a
//  couch, with no key in your hand — silver, like everything else this feature
//  touches (UI.md §1).

struct IntroduceSheet: View {
    /// Pre-chosen half of the pair, when the sheet was opened from a specific
    /// friend. nil when opened from Circle, where the first person is picked
    /// here instead.
    var subject: FriendStore.StoredFriend? = nil
    let myRoot: RootIdentity
    @Bindable var engine: ChatEngine
    @Bindable var friendStore: FriendStore
    @Environment(\.dismiss) private var dismiss

    /// First person, when this sheet asked for them. `subject` wins if set.
    @State private var first: FriendStore.StoredFriend?
    @State private var picked: FriendStore.StoredFriend?
    @State private var sending = false
    @State private var failure: String?
    @State private var sent = false

    private var firstPerson: FriendStore.StoredFriend? { subject ?? first }

    /// Everyone this device may introduce, minus whoever is already chosen.
    private func candidates(excluding hash: String? = nil) -> [FriendStore.StoredFriend] {
        friendStore.friends
            .filter { $0.id != hash }
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
                        } else if let a = firstPerson, let b = picked {
                            confirmView(a, b)
                        } else if let a = firstPerson {
                            secondPicker(a)
                        } else {
                            firstPicker
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
                if canGoBack {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back") { goBack() }
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Only offer Back where there is a step to go back TO. With a `subject`
    /// the first person was chosen before this sheet opened, so backing out of
    /// it means cancelling, which Cancel already does.
    private var canGoBack: Bool {
        guard !sent else { return false }
        return picked != nil || (subject == nil && first != nil)
    }

    private func goBack() {
        if picked != nil { picked = nil } else { first = nil }
        failure = nil
    }

    // MARK: - Step 1: who?

    private var firstPicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Introduce two friends")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)

            Text("Pick the first person. Both of them have to be someone you've met in person through Seal — that's what makes your introduction worth anything to them.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)

            let people = candidates()
            if people.count < 2 {
                notice("You need two people you've met in person to make an introduction. Forge one more friendship in Circle and this opens up.")
            } else {
                friendList(people) { first = $0 }
            }
        }
    }

    // MARK: - Step 2: to whom?

    private func secondPicker(_ a: FriendStore.StoredFriend) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Introduce \(a.identity.displayName) to…")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)

            Text("Pick someone you've also met in person. Seal will tell both of them that you vouched for the connection, and they can accept or ignore it.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)

            if !a.friendship.isInPerson {
                notice("You haven't met \(a.identity.displayName) in person through Seal — they're a linked friend. An introduction has to come from someone who has met BOTH people, so this one can't start here.")
            } else {
                let people = candidates(excluding: a.id)
                if people.isEmpty {
                    notice("You need two people you've met in person to make an introduction. Forge one more friendship in Circle and this opens up.")
                } else {
                    friendList(people) { picked = $0 }
                }
            }
        }
    }

    private func friendList(_ people: [FriendStore.StoredFriend],
                            onPick: @escaping (FriendStore.StoredFriend) -> Void) -> some View {
        VStack(spacing: 0) {
            ForEach(people) { friend in
                Button { onPick(friend) } label: {
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

    // MARK: - Confirm

    private func confirmView(_ a: FriendStore.StoredFriend,
                             _ b: FriendStore.StoredFriend) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                IdentityRing(displayName: a.identity.displayName,
                             tier: a.identity.tier, size: 44)
                Image(systemName: "link")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(SealTheme.silver)
                IdentityRing(displayName: b.identity.displayName,
                             tier: b.identity.tier, size: 44)
                Spacer()
            }

            Text("Introduce \(a.identity.displayName) and \(b.identity.displayName)")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            // Exactly what leaves this phone. Written as a list because a
            // paragraph about what you're sharing is a paragraph people skip.
            VStack(alignment: .leading, spacing: 10) {
                shareRow("person.text.rectangle",
                         "\(a.identity.displayName)'s name and identity key go to \(b.identity.displayName) — and \(b.identity.displayName)'s go to \(a.identity.displayName).")
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
                send(a, b)
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
            Text("Both of them have it now. They become linked once each of them accepts — you'll see it in your chat with them. Keep Seal open for a moment afterwards: this phone is the one that passes each answer to the other person.")
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

    private func send(_ a: FriendStore.StoredFriend, _ b: FriendStore.StoredFriend) {
        sending = true
        failure = nil
        Task {
            let result = await engine.sendIntroduction(a, and: b,
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
