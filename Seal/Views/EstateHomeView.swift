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
    @Bindable var estateEngine: EstateEngine
    @Bindable var appLock: AppLock
    let onOpenProfile: () -> Void

    @State private var showPeople = false
    @State private var showPolicy = false
    @State private var editing: Envelope?
    @State private var showRecipientPicker = false
    /// What the recipient picker is being used for this time: the blank
    /// editor, as it always was, or the interview.
    @State private var pickerMode: PickerMode = .blank
    @State private var interviewFor: InterviewSubject?
    /// Set when the picker is choosing a person for an envelope that was
    /// written to a typed name and is waiting to be bound.
    @State private var bindingEnvelope: Envelope?
    @State private var sealing = false
    @State private var sealError: String?
    @State private var sealedOK = false
    @State private var showTimeTravel = false
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
        return ownEnvelopes && ownCustodians && !estateEngine.guarded.isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 18) {
                        if guardsOnly {
                            guardedSection
                            PeopleYouWouldDoThisForCard(
                                onWrite: {
                                    pickerMode = .blank
                                    showRecipientPicker = true
                                },
                                onExplain: { explain = ExplainRequest(role: .sealer, numbers: .defaults) })
                            ownHeading
                            envelopesSection
                            custodiansSection
                        } else {
                            statusCard
                            envelopesSection
                            custodiansSection
                            guardedSection
                        }
                        footer
                    }
                    .padding(.vertical, 16)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                    .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle("Seal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onOpenProfile) {
                        IdentityRing(displayName: myRoot.displayName, tier: myRoot.tier, size: 32)
                    }
                    .accessibilityLabel("Profile")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showPeople = true } label: {
                        Image(systemName: "person.2.fill").foregroundStyle(SealTheme.brass)
                    }
                    .accessibilityLabel("People")
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
            .sheet(isPresented: $showPeople) {
                FriendsView(myRoot: myRoot, ceremony: ceremony, sync: sync,
                            friendStore: friendStore, estateEngine: estateEngine,
                            onClose: { showPeople = false })
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
                                   })
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
            .sheet(item: $interviewFor) { subject in
                EnvelopeInterviewView(
                    recipientName: subject.name,
                    onCancel: { interviewFor = nil },
                    onDraft: { draft in
                        interviewFor = nil
                        editing = envelopeFromDraft(draft, for: subject)
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
                Text("Your envelopes are sealed and your custodians have been told they hold a key. Open Seal now and then; that is all it takes to keep them closed.")
            }
        }
        .preferredColorScheme(.dark)
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
        let drafts = estate.envelopes.filter { !$0.sealed }.count
        if drafts > 0 {
            let subject = drafts == 1 ? "1 envelope is" : "\(drafts) envelopes are"
            return "\(subject) only on this phone. Until you seal them they cannot open for anyone, ever. Tap Seal the envelopes below."
        }
        return "Your rule or your key holders changed since you last sealed. Seal again to give your key holders fresh shares. Your envelopes themselves are not touched."
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
                    Text("You last checked in \(last.formatted(.relative(presentation: .named))). Opening Seal is the check-in. If you go quiet for \(estate?.policy.silenceDays ?? 90) days, your custodians can start the process, and you get warned for weeks before anything opens.")
                }
                if state == .cancelled {
                    Text("A claim was stopped when you checked in. Your custodians can see that.")
                        .foregroundStyle(.orange.opacity(0.9))
                }
            case .overdue?:
                Label("You have been quiet a long time.", systemImage: "clock.badge.exclamationmark")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("Opening the app just now counted as a check-in. Nothing has opened.")
            case .warning?, .grace?, .claimOpen?, .authorized?, .objected?:
                Label("A custodian has started a claim.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("If that is not what you want, tap the button. It stops everything. You do not need your key for this.")
                Button {
                    Task {
                        do { try await estateEngine.cancelClaim() } catch { sealError = error.localizedDescription }
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
                Text("Your custodians combined their keys. If you are reading this, please contact them: the seal is broken and cannot be put back. Start a new set of envelopes when you are ready.")
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

    // MARK: - Envelopes

    private var envelopesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Your envelopes", trailing: {
                Button {
                    pickerMode = .blank
                    showRecipientPicker = true
                } label: {
                    Label("Write one", systemImage: "plus")
                }
                .buttonStyle(.bordered).tint(SealTheme.brass)
                .parentTapTarget()
            })
            helperRow
            if let estate, !estate.envelopes.isEmpty {
                ForEach(estate.envelopes.sorted { ($0.recipientHash, $0.revealOrder) < ($1.recipientHash, $1.revealOrder) }) { envelope in
                    Button { editing = envelope } label: { envelopeRow(envelope, estate: estate) }
                        .buttonStyle(.plain)
                        .parentTapTarget()
                }
                sealButton(estate)
            } else {
                Text("An envelope holds a letter, a few photos, a voice message and the secrets: passwords, where the documents are, the combination, the words you never said out loud. If you do not know where to start, tap Help me write it and answer a few questions.")
                    .font(.callout).foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
            }
        }
    }

    /// The second way in. A blank page stops most people, and an empty
    /// vault is how this product actually fails (docs/PRODUCT.md section
    /// 11). No brass: this is a door, not a trust moment.
    private var helperRow: some View {
        Button {
            pickerMode = .interview
            showRecipientPicker = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "text.bubble")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Help me write it")
                        .font(.headline).foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("A few questions, then a draft you edit. Nothing you type leaves your phone.")
                        .font(.caption).foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.white.opacity(0.3))
            }
            .padding(16)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 20)
        }
        .buttonStyle(.plain)
        .parentTapTarget()
    }

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
            try? SealedCard.validated(cardType: $0.kind, title: $0.label, value: $0.value)
        }
        estateEngine.updateEnvelope(envelope)
        return envelope
    }

    private func envelopeRow(_ envelope: Envelope, estate: Estate) -> some View {
        let recipient = envelope.isAddressed
            ? (estate.recipients.first { $0.rootHash == envelope.recipientHash }?.displayName ?? "Someone")
            : (envelope.draftRecipientName ?? "Someone")
        // "0 secrets" read like something had gone missing. A letter with no
        // secrets is a whole envelope, so say what it is.
        let contents = envelope.secrets.isEmpty
            ? "letter only"
            : "\(envelope.secrets.count) secret\(envelope.secrets.count == 1 ? "" : "s")"
        // An envelope written to a typed name says what it is waiting for,
        // rather than "not sealed yet", which would read as the owner's
        // fault when the missing piece is a person.
        let status = envelope.isAddressed
            ? (envelope.sealed ? "sealed" : "not sealed yet")
            : "waiting to meet them"
        return HStack(spacing: 14) {
            Image(systemName: envelope.sealed ? "envelope.fill" : "envelope.badge")
                .font(.title3)
                .foregroundStyle(envelope.sealed ? SealTheme.brass : .white.opacity(0.5))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(envelope.title).font(.headline).foregroundStyle(.white)
                Text("To \(recipient) · \(contents) · \(status)")
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.white.opacity(0.3))
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 20)
    }

    private func sealButton(_ estate: Estate) -> some View {
        VStack(spacing: 8) {
            Button {
                sealing = true
                Task {
                    defer { sealing = false }
                    do {
                        try await estateEngine.sealAndPublish()
                        sealedOK = true
                    } catch {
                        sealError = error.localizedDescription
                    }
                }
            } label: {
                HStack {
                    if sealing { ProgressView().tint(SealTheme.ink) }
                    Text(estate.hasUnsealedChanges ? "Seal the envelopes" : "Sealed")
                        .font(.system(.headline, design: .rounded))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent).tint(SealTheme.brass)
            .disabled(sealing || !estate.hasUnsealedChanges || !estate.isReadyToSeal || DemoFixtures.isActive)
            .parentTapTarget(60)
            .padding(.horizontal, 20)
            // The demo branch comes FIRST. The button is disabled in demo
            // mode whatever the estate says, so any other caption would be
            // explaining a rule that is not the one stopping the tap.
            if DemoFixtures.isActive {
                Text("Sealing is turned off in the demo.")
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center).padding(.horizontal, 28)
            } else if !estate.isReadyToSeal {
                Text("Add at least one key holder and set the rule before sealing.")
                    .font(.caption).foregroundStyle(.orange.opacity(0.85))
            } else if !estate.unaddressedEnvelopes.isEmpty && estate.addressedEnvelopes.isEmpty {
                Text("Every envelope is waiting for a person. Meet them in person, add them under People, then open the envelope and choose them.")
                    .font(.caption).foregroundStyle(.orange.opacity(0.85))
                    .multilineTextAlignment(.center).padding(.horizontal, 28)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !estate.unaddressedEnvelopes.isEmpty {
                let n = estate.unaddressedEnvelopes.count
                Text("\(n) envelope\(n == 1 ? " is" : "s are") waiting for a person and \(n == 1 ? "is" : "are") not sealed. Everything else seals now.")
                    .font(.caption).foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center).padding(.horizontal, 28)
                    .fixedSize(horizontal: false, vertical: true)
            } else if estate.needsNewEpoch && estate.epochPublished {
                Text("Your custodians or your rule changed. Sealing again issues fresh key shares. Your envelopes themselves are not touched.")
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center).padding(.horizontal, 28)
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
                Text("A custodian is someone you met in person and handed a security key to. Open People, long press a person, and make them a custodian.")
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
            if !estateEngine.guarded.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    if !guardsOnly {
                        sectionHeader("What you hold for others", trailing: { EmptyView() })
                    }
                    ForEach(estateEngine.guarded) { g in
                        GuardedRoleCard(
                            guarded: g,
                            state: estateEngine.state(of: g.estateID),
                            snapshot: estateEngine.guardedSnapshots[g.estateID],
                            onExplain: { role, numbers in
                                explain = ExplainRequest(role: role, numbers: numbers)
                            }
                        ) {
                            NavigationLink {
                                GuardedEstateView(guarded: g, myRoot: myRoot, ceremony: ceremony,
                                                  estateEngine: estateEngine, appLock: appLock)
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
        case .objected?: "A custodian objected."
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
        Text("Nobody can open an envelope early. Not Apple, not us. It takes your custodians' physical keys, after a long silence from you, after weeks of warnings you can stop with one tap.")
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
