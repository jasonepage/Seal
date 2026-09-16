// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

//  EstateHomeView.swift
//  Seal
//
//  THE HOME SCREEN. Three things, top to bottom, for an owner:
//    1. Where you stand: safe, or a claim is running and here is the button
//       that stops it.
//    2. Your envelopes and the people who hold your keys.
//    3. Anything you guard for somebody else.
//
//  For a phone that has nothing of its own and guards something for
//  somebody else (a key holder, a recipient), the order flips: what they
//  hold comes first, in their words (GuardedRoleCard.swift), then the
//  question "do you have people you would do this for?", then the owner's
//  sections under a soft heading. Same screen, same code paths underneath,
//  different first sentence.
//
//  Half the people using this are over sixty. Big rows, one idea per row,
//  the plain word for everything. No mascot near a security surface.

struct EstateHomeView: View {
    let myRoot: RootIdentity
    @Bindable var identity: IdentityManager
    @Bindable var ceremony: CeremonyManager
    let sync: SyncEngine
    @Bindable var friendStore: FriendStore
    /// The two sets of envelopes (EstateEngine.Slot). Everything below
    /// reads `estateEngine`, which is whichever set the picker at the top
    /// of the Envelopes and Keys tabs is showing. What this phone holds
    /// for others is always read from the letters engine.
    @Bindable var lettersEngine: EstateEngine
    @Bindable var urgentEngine: EstateEngine
    @Bindable var appLock: AppLock
    let onOpenProfile: () -> Void

    @State private var slot: EstateEngine.Slot = .letters
    private var estateEngine: EstateEngine { slot == .urgent ? urgentEngine : lettersEngine }

    @State private var showPolicy = false
    @State private var editing: Envelope?
    @State private var showRecipientPicker = false
    /// What the recipient picker is being used for this time: the blank
    /// editor, as it always was, or the interview.
    @State private var pickerMode: PickerMode = .blank
    @State private var interviewFor: InterviewSubject?
    /// The envelope the interview drafted, held until its sheet has fully
    /// gone. Dismissing one sheet and presenting another in the same turn
    /// is the classic SwiftUI trap: the second never shows. So the draft
    /// waits here and the interview sheet's onDismiss opens the editor.
    @State private var draftedEnvelope: Envelope?
    /// Set when the picker is choosing a person for an envelope that was
    /// written to a typed name and is waiting to be bound.
    @State private var bindingEnvelope: Envelope?
    @State private var sealing = false
    @State private var sealError: String?
    @State private var sealedOK = false
    @State private var showTimeTravel = false
    @State private var showFamilyPreview = false
    @State private var showSecretReview = false
    @State private var showCoupleSetup = false
    @State private var showPaywall = false
    @Environment(SealPurchase.self) private var purchase
    @State private var explain: ExplainRequest?
    @Environment(\.parentMode) private var parentMode

    /// The recipient picker is one sheet with two jobs. "Write one" opens
    /// the blank editor, exactly as before. "Help me write it" opens the
    /// interview instead. Nothing else about the picker changes.
    private enum PickerMode { case blank, interview }

    /// Who the interview is writing to. `friend` is nil when they have not
    /// been met yet, in which case the draft lands on an unbound envelope.
    private struct InterviewSubject: Identifiable {
        let id = UUID()
        let name: String
        let friend: FriendStore.StoredFriend?
    }

    /// "See how it opens": the sandboxed explainer, started on the right
    /// path with that estate's real numbers. It touches no engine and no
    /// clock. (The DEBUG Time Travel screen is not this: it moves the real
    /// clock.)
    private struct ExplainRequest: Identifiable {
        let id = UUID()
        let role: OnboardingRole
        let numbers: OnboardingNumbers
    }

    private var estate: Estate? { estateEngine.estate }

    /// True when this phone has written nothing and holds no keys of its
    /// own, but has a part in somebody else's estate. That person is a key
    /// holder or a recipient, and the screen should speak to them first.
    private var guardsOnly: Bool {
        let ownEnvelopes = estate?.envelopes.isEmpty ?? true
        let ownCustodians = estate?.custodians.isEmpty ?? true
        return ownEnvelopes && ownCustodians && !lettersEngine.guarded.isEmpty
    }

    /// Three screens, not one. The old home screen stacked the status,
    /// every envelope, every key holder, every estate guarded for somebody
    /// else and a footer into one scroll, and the person who most needed
    /// to find "Seal the envelopes" had to scroll past all of it. Now:
    /// Envelopes (write, preview, seal), Keys (the rule, who holds a key
    /// for you, what you hold for others), People (meet and add). Sheets
    /// hang off the tab view so every tab can open them.
    enum Tab: Hashable { case envelopes, keys, people }
    @State private var tab: Tab = .envelopes

    var body: some View {
        attachSheets(to: tabs)
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            envelopesScreen
                .tabItem { Label("Envelopes", systemImage: "envelope.fill") }
                .tag(Tab.envelopes)
            screen(title: "Keys") { keysTab }
                .tabItem { Label("Keys", systemImage: "key.fill") }
                .tag(Tab.keys)
            FriendsView(myRoot: myRoot, ceremony: ceremony, sync: sync,
                        friendStore: friendStore, estateEngine: estateEngine)
                .tabItem { Label("People", systemImage: "person.2.fill") }
                .tag(Tab.people)
        }
        .tint(SealTheme.brass)
        .toolbarBackground(SealTheme.ink, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }

    /// One tab's shell: the ink background, the scroll, the toolbar.
    private func screen<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 18) {
                        content()
                    }
                    .padding(.vertical, 16)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onOpenProfile) {
                        IdentityRing(displayName: myRoot.displayName, tier: myRoot.tier, size: 32)
                    }
                    .accessibilityLabel("Profile")
                }
                #if DEBUG
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showTimeTravel = true } label: {
                        Image(systemName: "clock.arrow.2.circlepath").foregroundStyle(.orange)
                    }
                    .accessibilityLabel("Time travel (debug)")
                }
                #endif
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Tab 1: Envelopes, as an inbox

    /// An inbox, because a list of envelopes is a list. One compact row
    /// per envelope, newest first; a thin strip at the top saying sealed
    /// or not; a floating Write button; the preview, the saved secrets
    /// and the walkthrough behind one menu; and, only while something is
    /// unsealed, a Seal bar above the tab bar. Ten envelopes or a
    /// thousand, the screen is the same shape.
    private var envelopesScreen: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: []) {
                        NotificationsOffCard(matters: !lettersEngine.guarded.isEmpty || !inSetup)
                            .padding(.bottom, 12)
                        setPicker
                        if guardsOnly {
                            PeopleYouWouldDoThisForCard(
                                onWrite: {
                                    pickerMode = .blank
                                    showRecipientPicker = true
                                },
                                onExplain: { explain = ExplainRequest(role: .sealer, numbers: .defaults) })
                            .padding(.bottom, 12)
                        } else if inSetup {
                            setupCard.padding(.bottom, 12)
                        } else if loudState {
                            statusCard.padding(.bottom, 12)
                        } else {
                            statusStrip
                        }
                        inbox
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle("Envelopes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onOpenProfile) {
                        IdentityRing(displayName: myRoot.displayName, tier: myRoot.tier, size: 32)
                    }
                    .accessibilityLabel("Profile")
                }
                ToolbarItem(placement: .topBarTrailing) { inboxMenu }
                #if DEBUG
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showTimeTravel = true } label: {
                        Image(systemName: "clock.arrow.2.circlepath").foregroundStyle(.orange)
                    }
                    .accessibilityLabel("Time travel (debug)")
                }
                #endif
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { inboxBottom }
        }
        .preferredColorScheme(.dark)
    }

    /// Letters, or bills and medical. The second set has its own key
    /// holders, its own shorter rule and its own keys (RELEASE.md section
    /// 10), so a release of one opens nothing in the other.
    private var setPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Which set", selection: $slot) {
                Text("Letters").tag(EstateEngine.Slot.letters)
                Text("Bills and medical").tag(EstateEngine.Slot.urgent)
            }
            .pickerStyle(.segmented)
            if slot == .urgent {
                Text("A separate set that can open sooner: the bills, the insurance, the medical papers. Its own key holders and its own shorter rule. Opening it opens none of the letters.")
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 10)
    }

    /// A claim, a release or a long silence is not a strip. It stays loud.
    private var loudState: Bool {
        switch estateEngine.ownerState {
        case .active?, .cancelled?, .none: false
        default: true
        }
    }

    /// One line, the truth first. Orange when something is only on this
    /// phone, brass when everything is sealed and closed.
    private var statusStrip: some View {
        let unsealed = estate?.addressedEnvelopes.filter { !$0.sealed }.count ?? 0
        let changed = estate?.hasUnsealedChanges ?? false
        let last = estateEngine.ownerSnapshot?.lastHeartbeatAt
        let when: String = {
            guard let last else { return "" }
            return Date().timeIntervalSince(last) < 60 ? "just now" : last.formatted(.relative(presentation: .named))
        }()
        return HStack(spacing: 10) {
            Image(systemName: changed ? "exclamationmark.circle.fill" : "checkmark.seal.fill")
                .foregroundStyle(changed ? .orange : SealTheme.brass)
            Text(changed
                 ? (unsealed > 0 ? "\(unsealed) not sealed yet. Only on this phone." : "Your rule or key holders changed. Seal again.")
                 : "Sealed and closed. Checked in \(when).")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(changed ? .orange : .white.opacity(0.85))
                .lineLimit(1)
            Spacer()
            if let error = estateEngine.lastError {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange.opacity(0.8))
                    .accessibilityLabel(error)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(changed ? Color.orange.opacity(0.10) : Color.white.opacity(0.04))
    }

    /// The rows. Newest first, like mail. A person's initial on the left,
    /// their name and the title, one line of what is inside, the date on
    /// the right, and an orange dot when it is not sealed yet.
    @ViewBuilder
    private var inbox: some View {
        if let estate, !estate.envelopes.isEmpty {
            let rows = estate.envelopes.sorted { $0.updatedAt > $1.updatedAt }
            ForEach(rows) { envelope in
                Button { editing = envelope } label: { inboxRow(envelope, estate: estate) }
                    .buttonStyle(.plain)
                Divider().overlay(.white.opacity(0.08)).padding(.leading, 76)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "envelope").font(.system(size: 36)).foregroundStyle(.white.opacity(0.25))
                Text("No envelopes yet.").font(.headline).foregroundStyle(.white.opacity(0.8))
                Text("A letter, a few photos, your voice, and the secrets. Tap Write, or Help me write it if you do not know where to start.")
                    .font(.callout).foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32).padding(.top, 60)
        }
    }

    private func inboxRow(_ envelope: Envelope, estate: Estate) -> some View {
        let recipient = envelope.isAddressed
            ? (estate.recipients.first { $0.rootHash == envelope.recipientHash }?.displayName ?? "Someone")
            : (envelope.draftRecipientName ?? "Someone")
        let initial = String(recipient.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
        let summary = envelope.contentsSummary
        let contents = summary.prefix(1).uppercased() + summary.dropFirst()
        let status = envelope.isAddressed ? (envelope.sealed ? nil : "Not sealed") : "Waiting to meet them"
        return HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(envelope.sealed ? SealTheme.brass.opacity(0.18) : .white.opacity(0.08))
                Text(initial.isEmpty ? "?" : initial)
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(envelope.sealed ? SealTheme.brass : .white.opacity(0.85))
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(recipient).font(.headline).foregroundStyle(.white).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(envelope.updatedAt.formatted(.relative(presentation: .named)))
                        .font(.caption).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                }
                Text(envelope.title.isEmpty ? "Untitled" : envelope.title)
                    .font(.subheadline).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                HStack(spacing: 6) {
                    if let status {
                        Circle().fill(.orange).frame(width: 7, height: 7)
                        Text(status).font(.caption.weight(.semibold)).foregroundStyle(.orange)
                        Text("\u{00B7}").font(.caption).foregroundStyle(.white.opacity(0.3))
                    }
                    Text(contents).font(.caption).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    /// The things that used to be rows in the list and are not envelopes.
    private var inboxMenu: some View {
        let due: Bool = {
            guard let estate else { return false }
            return SecretReview.isDue(SecretReview.load(ownerHash: myRoot.credentialIDHash),
                                      fallback: estate.createdAt, now: estateEngine.now)
        }()
        return Menu {
            Button { showFamilyPreview = true } label: {
                Label("What your family sees", systemImage: "eye")
            }
            .disabled(estate?.envelopes.isEmpty ?? true)
            Button { showSecretReview = true } label: {
                Label(due ? "Check your saved secrets (due)" : "Your saved secrets", systemImage: due ? "exclamationmark.lock.fill" : "lock.rotation")
            }
            .disabled(estateEngine.allSecrets.isEmpty)
            Button { explain = ExplainRequest(role: .sealer, numbers: numbersForMyEstate) } label: {
                Label("Watch it happen", systemImage: "play.circle")
            }
        } label: {
            Image(systemName: due ? "ellipsis.circle.fill" : "ellipsis.circle")
                .foregroundStyle(due ? .orange : SealTheme.brass)
        }
        .accessibilityLabel("More")
    }

    /// The floating Write button, and the Seal bar when there is
    /// something to seal. Both sit above the tab bar and never cover a row.
    private var inboxBottom: some View {
        VStack(spacing: 10) {
            HStack {
                Spacer()
                Menu {
                    Button {
                        pickerMode = .blank
                        showRecipientPicker = true
                    } label: { Label("Write an envelope", systemImage: "square.and.pencil") }
                    Button {
                        pickerMode = .interview
                        showRecipientPicker = true
                    } label: { Label("Help me write it", systemImage: "bubble.left.and.text.bubble.right") }
                } label: {
                    Label("Write", systemImage: "square.and.pencil")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(SealTheme.ink)
                        .padding(.horizontal, 20).padding(.vertical, 14)
                        .background(SealTheme.brass, in: Capsule())
                        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                }
                .parentTapTarget(56)
            }
            .padding(.horizontal, 20)
            if let estate, estate.hasUnsealedChanges, !inSetup {
                sealBar(estate)
            }
        }
        .padding(.bottom, 8)
    }

    /// One bar: what is waiting, and the button. One short reason when it
    /// cannot run; the setup card carries the longer ones.
    private func sealBar(_ estate: Estate) -> some View {
        let unsealed = estate.addressedEnvelopes.filter { !$0.sealed }.count
        let ready = estate.isReadyToSeal && !DemoFixtures.isActive
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(unsealed > 0 ? (unsealed == 1 ? "1 envelope not sealed" : "\(unsealed) envelopes not sealed") : "Seal again")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Text(ready ? "Only on this phone until you do." : "Add a key holder on the Keys tab first.")
                    .font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
            Spacer()
            Button { runSeal() } label: {
                HStack(spacing: 6) {
                    if sealing { ProgressView().tint(SealTheme.ink) }
                    Text("Seal").font(.system(.headline, design: .rounded))
                }
                .padding(.horizontal, 18).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent).tint(SealTheme.brass).foregroundStyle(SealTheme.ink)
            .disabled(sealing || !ready)
            .parentTapTarget(48)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.ultraThinMaterial.opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
    }

    // MARK: - Tab 2: Keys

    @ViewBuilder
    private var keysTab: some View {
        setPicker
        if !inSetup, !estateEngine.custodiansWithNewPhones.isEmpty { newPhoneCard }
        custodiansSection
        if slot == .letters { coupleRow }
        guardedSection
        footer
    }

    /// Two people, two phones, one evening (CoupleSetupView).
    private var coupleRow: some View {
        Button { showCoupleSetup = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "person.2").font(.title3).foregroundStyle(.white.opacity(0.7)).frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Set up with my partner").font(.headline).foregroundStyle(.white)
                    Text("Two phones, one evening. Each of you holds a key for the other.")
                        .font(.caption).foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.white.opacity(0.3))
            }
            .padding(16)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .parentTapTarget()
        .padding(.horizontal, 20)
    }

    // MARK: - Sheets

    /// Every sheet, alert and cover the home screen can present, in one
    /// place, attached to the tab view so any tab can open any of them.
    private func attachSheets<V: View>(to content: V) -> some View {
        content
            .sheet(isPresented: $showPaywall) {
                SealPaywallView(purchase: purchase,
                                onUnlocked: {
                                    showPaywall = false
                                },
                                onClose: { showPaywall = false })
                    .environment(\.parentMode, parentMode)
                    .parentTypeScale()
            }
            .onChange(of: showPaywall) { was, now in
                // The sheet closed after a purchase: go straight on to the
                // seal the person was in the middle of. Presented from the
                // dismissal, not from inside the sheet, for the usual reason.
                if was, !now, purchase.isUnlocked { runSeal() }
            }
            .sheet(isPresented: $showCoupleSetup) {
                CoupleSetupView(myRoot: myRoot, friendStore: friendStore, estateEngine: estateEngine,
                                ceremony: ceremony, sync: sync,
                                onOpenPeople: { showCoupleSetup = false; tab = .people },
                                onWriteEnvelope: { envelope in showCoupleSetup = false; editing = envelope },
                                onSeal: { showCoupleSetup = false; runSeal() },
                                onClose: { showCoupleSetup = false })
                    .environment(\.parentMode, parentMode)
                    .parentTypeScale()
            }
            .sheet(isPresented: $showSecretReview) {
                SecretReviewView(estateEngine: estateEngine, ownerHash: myRoot.credentialIDHash,
                                 onEdit: { envelope in
                                     showSecretReview = false
                                     editing = envelope
                                 },
                                 onClose: { showSecretReview = false })
                    .environment(\.parentMode, parentMode)
                    .parentTypeScale()
            }
            .sheet(isPresented: $showFamilyPreview) {
                FamilyPreviewPicker(ownerName: myRoot.displayName, estateEngine: estateEngine,
                                    onClose: { showFamilyPreview = false })
                    .environment(\.parentMode, parentMode)
                    .parentTypeScale()
            }
            .sheet(isPresented: $showPolicy) {
                PolicyView(estateEngine: estateEngine, onClose: { showPolicy = false })
                    .environment(\.parentMode, parentMode)
                    .parentTypeScale()
            }
            .sheet(item: $editing) { envelope in
                EnvelopeEditorView(envelope: envelope, estateEngine: estateEngine, friendStore: friendStore,
                                   appLock: appLock, onClose: { editing = nil },
                                   onChoosePerson: {
                                       editing = nil
                                       bindingEnvelope = envelope
                                   },
                                   ownerName: myRoot.displayName)
                    .environment(\.parentMode, parentMode)
                    .parentTypeScale()
            }
            .sheet(isPresented: $showRecipientPicker) {
                RecipientPickerSheet(friendStore: friendStore, estateEngine: estateEngine) { pick in
                    showRecipientPicker = false
                    switch pick {
                    case .cancelled:
                        return
                    case .met(let friend):
                        estateEngine.addRecipient(friend.identity)
                        switch pickerMode {
                        case .blank:
                            editing = estateEngine.newEnvelope(for: friend.identity.credentialIDHash,
                                                               title: "For \(friend.identity.displayName)")
                        case .interview:
                            interviewFor = InterviewSubject(name: friend.identity.displayName, friend: friend)
                        }
                    case .notYet(let name):
                        // No recipient is added to the estate here. A typed
                        // name is not an identity and must never look like
                        // one; it becomes a recipient at bindEnvelope.
                        switch pickerMode {
                        case .blank:
                            editing = estateEngine.newEnvelope(forName: name)
                        case .interview:
                            interviewFor = InterviewSubject(name: name, friend: nil)
                        }
                    }
                }
                .environment(\.parentMode, parentMode)
                .parentTypeScale()
            }
            // Choosing the person for an envelope that was written to a name.
            .sheet(item: $bindingEnvelope) { envelope in
                RecipientPickerSheet(friendStore: friendStore, estateEngine: estateEngine,
                                     bindingExisting: true) { pick in
                    bindingEnvelope = nil
                    if case .met(let friend) = pick {
                        estateEngine.bindEnvelope(envelope.id, to: friend.identity)
                    }
                }
                .environment(\.parentMode, parentMode)
                .parentTypeScale()
            }
            .sheet(item: $interviewFor, onDismiss: {
                if let drafted = draftedEnvelope {
                    draftedEnvelope = nil
                    editing = drafted
                }
            }) { subject in
                EnvelopeInterviewView(
                    recipientName: subject.name,
                    onCancel: { interviewFor = nil },
                    onDraft: { draft in
                        draftedEnvelope = envelopeFromDraft(draft, for: subject)
                        interviewFor = nil
                    })
                    .environment(\.parentMode, parentMode)
                    .parentTypeScale()
            }
            #if DEBUG
            .sheet(isPresented: $showTimeTravel) {
                TimeTravelView(estateEngine: estateEngine, onClose: { showTimeTravel = false })
            }
            #endif
            .fullScreenCover(item: $explain) { request in
                SealOnboardingView(numbers: request.numbers, initialRole: request.role,
                                   onDone: { explain = nil })
                    .environment(\.parentMode, parentMode)
                    .parentTypeScale()
            }
            .alert("Could not seal", isPresented: Binding(get: { sealError != nil }, set: { if !$0 { sealError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(sealError ?? "") }
            .alert("Sealed", isPresented: $sealedOK) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Your envelopes are sealed and your key holders have been told they hold a key. Open Seal now and then; that is all it takes to keep them closed.")
            }
            .onReceive(NotificationCenter.default.publisher(for: Clocks.changed)) { _ in
                Task { await estateEngine.refreshOwner() }
            }
    }

    // MARK: - Status

    /// What is waiting to be sealed, in plain words, or nil when everything
    /// the owner has written is published and wrapped. Drafts are named first
    /// because an unsealed envelope is the one thing here that silently does
    /// nothing at all.
    private var unsealedLine: String? {
        guard let estate, estate.hasUnsealedChanges else { return nil }
        // addressedEnvelopes: one written to a typed name cannot be sealed
        // yet, so counting it here would tell somebody to tap a button that
        // does nothing for it.
        let drafts = estate.addressedEnvelopes.filter { !$0.sealed }.count
        if drafts > 0 {
            let subject = drafts == 1 ? "1 envelope is" : "\(drafts) envelopes are"
            return "\(subject) only on this phone. Until you seal them they cannot open for anyone, ever. Tap Seal the envelopes below."
        }
        return "Your rule or your key holders changed since you last sealed. Seal again to give your key holders fresh shares. Your envelopes themselves are not touched."
    }

    // MARK: - The first run

    /// The four things that have to happen, in the order they happen.
    private enum SetupStep: Int, CaseIterable, Identifiable {
        case envelope, keyHolders, rule, seal
        var id: Int { rawValue }
    }

    /// True until the first successful seal. While this holds, the home
    /// screen is ONE card.
    private var inSetup: Bool { !(estate?.epochPublished ?? false) }

    private func isDone(_ step: SetupStep) -> Bool {
        guard let estate else { return false }
        switch step {
        case .envelope: return !estate.envelopes.isEmpty
        case .keyHolders: return !estate.custodians.isEmpty
        case .rule: return estate.isReadyToSeal
        case .seal: return estate.epochPublished
        }
    }

    private var firstUndone: SetupStep? {
        SetupStep.allCases.first { !isDone($0) }
    }

    private func stepTitle(_ step: SetupStep) -> String {
        switch step {
        case .envelope: "Write your first envelope"
        case .keyHolders: "Choose who can open them"
        case .rule: "Set your rule"
        case .seal: "Seal it"
        }
    }

    /// Only the step somebody is actually on gets a second line. Four
    /// explanations at once is the wall this card exists to replace.
    private func stepDetail(_ step: SetupStep) -> String {
        switch step {
        case .envelope:
            return "A letter, a few photos, and the secrets. You do not need anybody else to start. Type a name and write tonight."
        case .keyHolders:
            return "People you meet in person and trust to act together after you are gone. Open People, add them, then make them key holders."
        case .rule:
            if let estate, !estate.custodians.isEmpty {
                let p = estate.policy
                return "Right now: " + (estate.custodians.count == 1
                    ? "your one key holder"
                    : "any \(p.threshold) of \(estate.custodians.count) key holders") + ", after \(p.silenceDays) days of silence and \(p.warningDays) days of warnings. Tap to change it."
            }
            return "How long the silence has to be, how many warnings you get, and how many of them it takes."
        case .seal:
            return "Everything is encrypted on this phone and published. Nobody can open an envelope early."
        }
    }

    private func perform(_ step: SetupStep) {
        switch step {
        case .envelope:
            pickerMode = .blank
            showRecipientPicker = true
        case .keyHolders:
            tab = .people
        case .rule:
            showPolicy = true
        case .seal:
            // Nothing to seal until there are key holders and a valid rule,
            // and the row above says so. Send them there rather than firing
            // a seal that throws.
            if estate?.isReadyToSeal == true { runSeal() } else { tab = .people }
        }
    }

    /// ONE card, instead of a paragraph over four empty containers.
    ///
    /// What a fresh install used to render: a status card explaining the
    /// product, an empty envelopes section, an empty key holders section, an
    /// empty guarded section, and a footer. Five containers, four of them
    /// with nothing in them, and no answer anywhere to the only question a
    /// new person has, which is what to do next.
    private var setupCard: some View {
        let current = firstUndone
        let done = SetupStep.allCases.filter { isDone($0) }.count
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                // Pewter. Nothing is sealed yet, so there is no trust moment
                // to spend brass on.
                SealMark(size: 44, trust: false, pressOnAppear: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sealed envelopes")
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(done) of 4 done")
                        .font(.caption).foregroundStyle(.white.opacity(0.5))
                }
            }

            Text("Sealed envelopes for the people you leave behind. Nobody, including us, can open one early. It takes an evening.")
                .font(.callout).foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                ForEach(SetupStep.allCases) { step in
                    Button { perform(step) } label: {
                        setupRow(step, isCurrent: step == current)
                    }
                    .buttonStyle(.plain)
                    .parentTapTarget()
                }
            }

            Button {
                explain = ExplainRequest(role: .sealer, numbers: numbersForMyEstate)
            } label: {
                Label("Watch it happen", systemImage: "play.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SealSecondaryButtonStyle())
            .parentTapTarget()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 20)
    }

    private func setupRow(_ step: SetupStep, isCurrent: Bool) -> some View {
        let done = isDone(step)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                // Brass on the last step only when it is the one to tap: that
                // tap is the trust moment of the whole product.
                .foregroundStyle(done ? SealTheme.brass
                                 : (isCurrent && step == .seal ? SealTheme.brass : .white.opacity(0.35)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(stepTitle(step))
                    .font(.headline)
                    .foregroundStyle(done ? .white.opacity(0.5) : .white)
                    .strikethrough(done, color: .white.opacity(0.35))
                    .fixedSize(horizontal: false, vertical: true)
                if isCurrent {
                    Text(stepDetail(step))
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if !done {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.white.opacity(0.3))
            }
        }
        .padding(14)
        .background((isCurrent ? Color.white.opacity(0.07) : Color.clear),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }

    /// This owner's real rule, for the explainer. Falls back to the defaults
    /// before there is anything real to show.
    private var numbersForMyEstate: OnboardingNumbers {
        guard let estate, !estate.custodians.isEmpty else { return .defaults }
        return OnboardingNumbers(policy: estate.policy, custodianCount: estate.custodians.count)
    }

    private var statusCard: some View {
        let state = estateEngine.ownerState
        let snapshot = estateEngine.ownerSnapshot
        return VStack(alignment: .leading, spacing: 10) {
            switch state {
            case .none:
                HStack(alignment: .center, spacing: 14) {
                    // Pewter: nothing is sealed yet, so no trust moment.
                    SealMark(size: 44, trust: false, pressOnAppear: true)
                    Text("Sealed envelopes").font(.system(.title2, design: .rounded, weight: .semibold))
                }
                Text("Write a few envelopes. Hand keys to people you trust. Set the rule for how they open after you are gone. Nobody, including us, can open one early.")
            case .active?, .cancelled?:
                // This banner reads the RELEASE state, which only says whether
                // a claim is running. It used to announce "Your envelopes are
                // closed" on top of a list showing two envelopes marked "not
                // sealed yet", which is the worst lie the app could tell: those
                // two exist on this phone and nowhere else, and would open for
                // nobody. Say the true thing first.
                if let unsealedLine {
                    Label("Not sealed yet.", systemImage: "exclamationmark.circle.fill")
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text(unsealedLine)
                } else {
                    // The mark in brass, because sealed and closed is the
                    // trust moment of the whole product, with one pulse ring
                    // on arrival. Opening the app IS the heartbeat, so the
                    // pulse is the honest picture of what just happened. It
                    // runs once and stops.
                    HStack(alignment: .center, spacing: 14) {
                        SealMark(size: 44, trust: true, pressOnAppear: false, pulseOnAppear: true)
                        Text("Your envelopes are closed.")
                            .font(.system(.title3, design: .rounded, weight: .semibold))
                            .foregroundStyle(SealTheme.brass)
                    }
                }
                if let last = snapshot?.lastHeartbeatAt {
                    // The real numbers from the rule, not "weeks". And "just
                    // now" under a minute, because "2 seconds ago" reads as a
                    // stopwatch on a screen that is supposed to feel calm.
                    let policy = estate?.policy ?? ReleasePolicy(threshold: 1)
                    let when = Date().timeIntervalSince(last) < 60
                        ? "just now"
                        : last.formatted(.relative(presentation: .named))
                    // One sentence. The whole rule, with these numbers, is
                    // behind "Watch it happen" and on the Keys tab.
                    Text("You checked in \(when). Opening Seal is the check-in. After \(policy.silenceDays) quiet days a key holder can start the process, and opening Seal at any point stops it.")
                }
                // The explainer was reachable only from a key holder's or a
                // recipient's card, so the one person who set the whole thing
                // up could not watch their own rule run. Their numbers, their
                // path.
                Button {
                    explain = ExplainRequest(role: .sealer, numbers: numbersForMyEstate)
                } label: {
                    Label("Watch it happen", systemImage: "play.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SealSecondaryButtonStyle())
                .parentTapTarget()
                .padding(.top, 4)
                if state == .cancelled {
                    Text("A claim was stopped when you checked in. Your key holders can see that.")
                        .foregroundStyle(.orange.opacity(0.9))
                }
            case .overdue?:
                Label("You have been quiet a long time.", systemImage: "clock.badge.exclamationmark")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("Opening the app just now counted as a check-in. Nothing has opened.")
            case .warning?, .grace?, .claimOpen?, .authorized?, .objected?:
                Label("A key holder has started a claim.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("If that is not what you want, tap the button. It stops everything. You do not need your key for this.")
                Button {
                    Task {
                        do { try await estateEngine.cancelClaim() } catch { sealError = SyncEngine.friendly(error) }
                    }
                } label: {
                    Text("I am here. Stop it.")
                        .font(.system(.headline, design: .rounded))
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent).tint(.orange)
                .parentTapTarget(60)
            case .released?:
                Label("The envelopes have been released.", systemImage: "envelope.open.fill")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("Your key holders combined their keys. If you are reading this, please contact them: the seal is broken and cannot be put back. Start a new set of envelopes when you are ready.")
            }
            if let error = estateEngine.lastError {
                Text(error).font(.caption).foregroundStyle(.orange.opacity(0.8))
            }
        }
        .font(.callout)
        .foregroundStyle(.white.opacity(0.85))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 20)
    }

    // MARK: - A key holder on a new phone

    /// The silent failure this card exists for: a key holder replaces their
    /// phone, signs in, is endorsed, and everything reports fine. But their
    /// piece was wrapped to keys that never leave the old phone, so a
    /// two-of-three estate quietly became one-of-three. The engine noticed
    /// on refresh (custodiansWithNewPhones); this names the person and makes
    /// the fix one tap. Orange, not brass: nothing here is a trust moment,
    /// it is a repair.
    private var newPhoneCard: some View {
        let people = estateEngine.custodiansWithNewPhones
        let names = people.map(\.displayName)
        let who: String
        switch names.count {
        case 1: who = names[0]
        case 2: who = "\(names[0]) and \(names[1])"
        default: who = names.dropLast().joined(separator: ", ") + ", and " + (names.last ?? "")
        }
        return VStack(alignment: .leading, spacing: 10) {
            Label(names.count == 1 ? "\(who) has a new phone." : "\(who) have new phones.",
                  systemImage: "iphone.gen3.badge.exclamationmark")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(.orange)
            Text(names.count == 1
                 ? "Their piece of the key is on a phone they no longer have, so right now it cannot be used. Sealing again gives them a fresh piece on the phone they have now. Your envelopes themselves are not touched."
                 : "Their pieces of the key are on phones they no longer have, so right now those pieces cannot be used. Sealing again gives each of them a fresh piece on the phone they have now. Your envelopes themselves are not touched.")
            Button {
                runSeal()
            } label: {
                HStack {
                    if sealing { ProgressView().tint(SealTheme.ink) }
                    Text("Seal again")
                        .font(.system(.headline, design: .rounded))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent).tint(.orange)
            .disabled(sealing || DemoFixtures.isActive)
            .parentTapTarget(60)
        }
        .font(.callout)
        .foregroundStyle(.white.opacity(0.85))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 20)
    }

    // MARK: - Envelopes

    /// Turn an interview draft into a real envelope, using exactly the two
    /// engine calls the editor uses: `newEnvelope(for:title:)` to create it
    /// and `updateEnvelope(_:)` to save the letter and the secrets. Nothing
    /// new was added to the engine for this. The envelope lands unsealed,
    /// like every other draft, and the editor opens on it next.
    private func envelopeFromDraft(_ draft: InterviewDraft, for subject: InterviewSubject) -> Envelope {
        let name = subject.name
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "For \(name)" : draft.title
        var envelope: Envelope
        if let friend = subject.friend {
            envelope = estateEngine.newEnvelope(for: friend.identity.credentialIDHash, title: title)
        } else {
            // Not met yet. Same draft, waiting for a person.
            envelope = estateEngine.newEnvelope(forName: name)
            envelope.title = title
        }
        envelope.letter = draft.letter
        // Secrets go in exactly as typed, through the same validator the
        // secret editor uses. One that cannot be built is dropped rather
        // than altered, and the owner sees the letter and can add it by hand.
        envelope.secrets = draft.secrets.compactMap {
            try? SealedCard.validated(cardType: $0.kind, title: $0.label, value: $0.value, keepEdges: $0.keepEdges)
        }
        estateEngine.updateEnvelope(envelope)
        return envelope
    }


    /// One seal path, shared by the Seal button and the setup card's last
    /// step, so the two can never drift into doing different things.
    ///
    /// The paywall sits here and nowhere else, and it sits in front of
    /// EVERY seal, not only the first. The first version gated on "has this
    /// estate ever sealed", which meant an estate that got through once
    /// sealed for free forever. Pay once and every seal after is free;
    /// never pay and nothing seals. Apple holds the receipt, so a reinstall
    /// or a new phone restores it. Demo mode never asks, because the demo
    /// cannot seal at all.
    private func runSeal() {
        guard !sealing, !DemoFixtures.isActive else { return }
        guard purchase.isUnlocked else {
            // The launch check may still be in flight on a fast tap. Finish
            // it before deciding, so a paid person never sees the sheet.
            if purchase.isChecking {
                Task {
                    await purchase.refresh()
                    if purchase.isUnlocked { runSeal() } else { showPaywall = true }
                }
            } else {
                showPaywall = true
            }
            return
        }
        sealing = true
        Task {
            defer { sealing = false }
            do {
                try await estateEngine.sealAndPublish()
                sealedOK = true
            } catch {
                sealError = SyncEngine.friendly(error)
            }
        }
    }


    // MARK: - Custodians

    private var custodiansSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Who holds a key", trailing: {
                Button { showPolicy = true } label: { Label("The rule", systemImage: "slider.horizontal.3") }
                    .buttonStyle(.bordered).tint(SealTheme.brass)
                    .parentTapTarget()
            })
            if let estate, !estate.custodians.isEmpty {
                Text(estate.policy.summary(custodianCount: estate.custodians.count))
                    .font(.callout).foregroundStyle(SealTheme.brass.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
                ForEach(estate.custodians) { custodian in
                    // The row used to be a dead HStack, so the one thing a
                    // person comes to this section to do, record the handover,
                    // had no way in from here. It opens that person's page now.
                    // If no met-in-person record backs the hash (it should, a
                    // custodian is made from one), the row stays static rather
                    // than offering a tap that leads nowhere.
                    if let friend = storedFriend(for: custodian) {
                        NavigationLink {
                            PersonView(person: friend, myRoot: myRoot, friendStore: friendStore,
                                       estateEngine: estateEngine, ceremony: ceremony, sync: sync)
                        } label: {
                            custodianRow(custodian, tappable: true)
                        }
                        .buttonStyle(.plain)
                        .parentTapTarget()
                    } else {
                        custodianRow(custodian, tappable: false)
                    }
                }
            } else {
                Text("A key holder is someone you met in person and handed a security key to. Open People, tap a person, and make them a key holder.")
                    .font(.callout).foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
            }
        }
    }

    private func storedFriend(for custodian: Custodian) -> FriendStore.StoredFriend? {
        friendStore.friends.first { $0.identity.credentialIDHash == custodian.rootHash }
    }

    private func custodianRow(_ custodian: Custodian, tappable: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: custodian.handoverReceiptID == nil ? "key" : "key.fill")
                .foregroundStyle(SealTheme.brass).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(custodian.displayName).font(.headline).foregroundStyle(.white)
                // "Tap to record it" only where there is something to tap.
                Text(custodian.handoverReceiptID == nil
                     ? (tappable ? "Key handover not recorded yet. Tap to record it."
                                 : "Key handover not recorded yet.")
                     : "Key handover signed by both of you.")
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                // Do they still have it? From the record: their yearly tap
                // (CustodyConfirmation). Orange with the next step when it
                // is overdue, quiet otherwise.
                if let standing = estateEngine.custodyStanding(for: custodian) {
                    Label(standing.line, systemImage: standing.overdue ? "exclamationmark.triangle.fill" : "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(standing.overdue ? .orange : .white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if tappable {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.white.opacity(0.3))
            }
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 20)
    }

    // MARK: - Guarded

    /// One card per estate this phone has a part in, in the words of that
    /// part. The old row said "Keys you hold for others" over a recipient
    /// and "All quiet." to somebody who had asked nothing. GuardedRoleCard
    /// says the one thing each of those people needs, with no envelope
    /// count (the phone does not know one until release).
    private var guardedSection: some View {
        Group {
            if !lettersEngine.guarded.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    if !guardsOnly {
                        sectionHeader("What you hold for others", trailing: { EmptyView() })
                    }
                    ForEach(lettersEngine.guarded) { g in
                        GuardedRoleCard(
                            guarded: g,
                            state: lettersEngine.state(of: g.estateID),
                            snapshot: lettersEngine.guardedSnapshots[g.estateID],
                            onExplain: { role, numbers in
                                explain = ExplainRequest(role: role, numbers: numbers)
                            }
                        ) {
                            NavigationLink {
                                GuardedEstateView(guarded: g, myRoot: myRoot, ceremony: ceremony,
                                                  estateEngine: lettersEngine, appLock: appLock)
                            } label: {
                                GuardedDetailsLabel()
                            }
                        }
                    }
                }
            }
        }
    }

    /// The soft heading over the owner's own sections when this phone is
    /// mainly a key holder's or a recipient's.
    private var ownHeading: some View {
        Text("Your own envelopes")
            .font(.system(.title2, design: .rounded, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 10)
    }

    static func stateLine(_ state: ReleaseState?, guarded: GuardedEstate) -> String {
        switch state {
        case .none: "Waiting for the owner to seal."
        case .active?: guarded.isCustodian ? "All quiet. You hold one of the keys. Nothing to do." : "All quiet. Nothing to do."
        case .overdue?: "The owner has been silent past their limit."
        case .warning?: "A claim is open. The owner is being warned."
        case .grace?: "Warnings are over. A quiet period is running."
        case .claimOpen?: "Keys can be tapped now."
        case .authorized?: "Enough keys tapped. Waiting to be combined."
        case .released?: guarded.isRecipient ? "Released. Your envelopes are waiting." : "Released."
        case .cancelled?: "The owner checked in and stopped it."
        case .objected?: "A key holder objected."
        }
    }

    private func stateLine(_ state: ReleaseState?, guarded: GuardedEstate) -> String {
        Self.stateLine(state, guarded: guarded)
    }

    // MARK: - Furniture

    private func sectionHeader<T: View>(_ title: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack {
            Text(title).font(.system(.title3, design: .rounded, weight: .semibold)).foregroundStyle(.white)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 24)
    }

    private var footer: some View {
        Text("Nobody can open an envelope early. Not Apple, not us. It takes your key holders' physical keys, after a long silence from you, after weeks of warnings you can stop with one tap.")
            .font(.caption2).foregroundStyle(.white.opacity(0.4))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 32).padding(.top, 8)
    }
}

/// Pick who an envelope is for. Anyone met in person.
/// Who an envelope is for, as far as this sheet can tell.
enum RecipientPick {
    /// Someone met in person and already in Seal.
    case met(FriendStore.StoredFriend)
    /// A name typed by the owner. The envelope stays a draft until they meet.
    case notYet(String)
    case cancelled
}

/// This sheet used to be a dead end. On a fresh install it said "Nobody to
/// write to yet. Open People and add them first", which is the app asking a
/// new customer to go physically find somebody, install Seal on their phone
/// too, and run a ceremony, before writing one word. That is the hardest
/// thing this product ever asks, asked first, in exchange for nothing yet.
///
/// Now a name is enough to start. The envelope waits as a draft and binds to
/// a real identity the day they meet, which is the same rule as before
/// (PRODUCT.md section 8) arriving in the order a person can actually do it.
struct RecipientPickerSheet: View {
    @Bindable var friendStore: FriendStore
    @Bindable var estateEngine: EstateEngine
    /// True when picking a person for an envelope that already exists. A
    /// typed name is no help there, so that half is hidden.
    var bindingExisting = false
    let onPick: (RecipientPick) -> Void

    @State private var typedName = ""

    private var trimmedName: String {
        typedName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if !friendStore.friends.isEmpty {
                            metSection
                        }
                        if !bindingExisting {
                            notYetSection
                        } else if friendStore.friends.isEmpty {
                            Text("You have not added anybody in person yet. Open People, meet them, and then come back to this envelope.")
                                .font(.callout).foregroundStyle(.white.opacity(0.6))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle("Who is it for?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onPick(.cancelled) }.foregroundStyle(SealTheme.brass)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var metSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("People you have met")
                .font(.headline).foregroundStyle(.white.opacity(0.85))
            ForEach(friendStore.friends) { friend in
                Button { onPick(.met(friend)) } label: {
                    HStack(spacing: 12) {
                        IdentityRing(displayName: friend.identity.displayName, tier: friend.identity.tier, size: 36)
                        Text(friend.identity.displayName)
                            .font(.headline).foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.white.opacity(0.3))
                    }
                    .padding(16)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .parentTapTarget()
            }
        }
    }

    private var notYetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(friendStore.friends.isEmpty ? "Who do you want to write to?" : "Somebody not in Seal yet")
                .font(.headline).foregroundStyle(.white.opacity(0.85))
            Text("Type their name and write to them tonight. The envelope waits here as a draft. When you meet them in person and add them, it becomes theirs and can be sealed.")
                .font(.callout).foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            TextField("Their name", text: $typedName)
                .textFieldStyle(.plain)
                .font(.body)
                .foregroundStyle(.white)
                .padding(14)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                .submitLabel(.done)
                .onSubmit { if !trimmedName.isEmpty { onPick(.notYet(trimmedName)) } }
            Button {
                onPick(.notYet(trimmedName))
            } label: {
                Text(trimmedName.isEmpty ? "Write an envelope" : "Write to \(trimmedName)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SealPrimaryButtonStyle())
            .disabled(trimmedName.isEmpty)
            .parentTapTarget(60)
        }
    }
}
