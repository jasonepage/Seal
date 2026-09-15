import SwiftUI

//  EstateHomeView.swift
//  Seal
//
//  THE HOME SCREEN. Three things, top to bottom:
//    1. Where you stand: safe, or a claim is running and here is the button
//       that stops it.
//    2. Your envelopes and the people who hold your keys.
//    3. Anything you guard for somebody else.
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
    @State private var newEnvelopeFor: FriendStore.StoredFriend?
    @State private var showRecipientPicker = false
    @State private var sealing = false
    @State private var sealError: String?
    @State private var sealedOK = false
    @State private var showTimeTravel = false
    @Environment(\.parentMode) private var parentMode

    private var estate: Estate? { estateEngine.estate }

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 18) {
                        statusCard
                        envelopesSection
                        custodiansSection
                        guardedSection
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
                                   appLock: appLock, onClose: { editing = nil })
                    .environment(\.parentMode, parentMode)
                    .parentTypeScale()
            }
            .sheet(isPresented: $showRecipientPicker) {
                RecipientPickerSheet(friendStore: friendStore, estateEngine: estateEngine) { friend in
                    showRecipientPicker = false
                    guard let friend else { return }
                    estateEngine.addRecipient(friend.identity)
                    editing = estateEngine.newEnvelope(for: friend.identity.credentialIDHash, title: "For \(friend.identity.displayName)")
                }
                .environment(\.parentMode, parentMode)
                .parentTypeScale()
            }
            #if DEBUG
            .sheet(isPresented: $showTimeTravel) {
                TimeTravelView(estateEngine: estateEngine, onClose: { showTimeTravel = false })
            }
            #endif
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
            return "\(subject) only on this phone. Until you seal them they will not open for anyone, ever. Tap Seal the envelopes below."
        }
        return "Your rule or your key holders changed since you last sealed. Seal again to give your key holders fresh shares. Your envelopes themselves are not touched."
    }

    private var statusCard: some View {
        let state = estateEngine.ownerState
        let snapshot = estateEngine.ownerSnapshot
        return VStack(alignment: .leading, spacing: 10) {
            switch state {
            case .none:
                Text("Sealed envelopes").font(.system(.title2, design: .rounded, weight: .semibold))
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
                    Label("Your envelopes are closed.", systemImage: "checkmark.seal.fill")
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .foregroundStyle(SealTheme.brass)
                }
                if let last = snapshot?.lastHeartbeatAt {
                    Text("You last checked in \(last.formatted(.relative(presentation: .named))). Opening Seal is the check-in. If you go quiet for \(estate?.policy.silenceDays ?? 90) days, your custodians can start the process, and you will be warned for weeks before anything opens.")
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
                Button { showRecipientPicker = true } label: {
                    Label("Write one", systemImage: "plus")
                }
                .buttonStyle(.bordered).tint(SealTheme.brass)
                .parentTapTarget()
            })
            if let estate, !estate.envelopes.isEmpty {
                ForEach(estate.envelopes.sorted { ($0.recipientHash, $0.revealOrder) < ($1.recipientHash, $1.revealOrder) }) { envelope in
                    Button { editing = envelope } label: { envelopeRow(envelope, estate: estate) }
                        .buttonStyle(.plain)
                        .parentTapTarget()
                }
                sealButton(estate)
            } else {
                Text("An envelope holds a letter, a few photos, a voice message and the secrets: passwords, where the documents are, the combination, the words you never said out loud.")
                    .font(.callout).foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
            }
        }
    }

    private func envelopeRow(_ envelope: Envelope, estate: Estate) -> some View {
        let recipient = estate.recipients.first { $0.rootHash == envelope.recipientHash }?.displayName ?? "Someone"
        return HStack(spacing: 14) {
            Image(systemName: envelope.sealed ? "envelope.fill" : "envelope.badge")
                .font(.title3)
                .foregroundStyle(envelope.sealed ? SealTheme.brass : .white.opacity(0.5))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(envelope.title).font(.headline).foregroundStyle(.white)
                Text("To \(recipient) · \(envelope.secrets.count) secret\(envelope.secrets.count == 1 ? "" : "s") · \(envelope.sealed ? "sealed" : "not sealed yet")")
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
            if !estate.isReadyToSeal {
                Text("Add at least one custodian and set the rule before sealing.")
                    .font(.caption).foregroundStyle(.orange.opacity(0.85))
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
                    HStack(spacing: 14) {
                        Image(systemName: custodian.handoverReceiptID == nil ? "key" : "key.fill")
                            .foregroundStyle(SealTheme.brass).frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(custodian.displayName).font(.headline).foregroundStyle(.white)
                            Text(custodian.handoverReceiptID == nil ? "Key not yet handed over on record" : "Key handover signed by both of you")
                                .font(.caption).foregroundStyle(.white.opacity(0.5))
                        }
                        Spacer()
                    }
                    .padding(16)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 20)
                }
            } else {
                Text("A custodian is someone you met in person and handed a security key to. Open People, long press a person, and make them a custodian.")
                    .font(.callout).foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
            }
        }
    }

    // MARK: - Guarded

    private var guardedSection: some View {
        Group {
            if !estateEngine.guarded.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("Keys you hold for others", trailing: { EmptyView() })
                    ForEach(estateEngine.guarded) { g in
                        NavigationLink {
                            GuardedEstateView(guarded: g, myRoot: myRoot, ceremony: ceremony,
                                              estateEngine: estateEngine, appLock: appLock)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: g.isCustodian ? "key.fill" : "envelope.fill")
                                    .foregroundStyle(stateTint(estateEngine.state(of: g.estateID))).frame(width: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(g.ownerName.isEmpty ? "Someone's envelopes" : "\(g.ownerName)'s envelopes")
                                        .font(.headline).foregroundStyle(.white)
                                    Text(stateLine(estateEngine.state(of: g.estateID), guarded: g))
                                        .font(.caption).foregroundStyle(.white.opacity(0.5))
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
                }
            }
        }
    }

    static func stateLine(_ state: ReleaseState?, guarded: GuardedEstate) -> String {
        switch state {
        case .none: "Waiting for the owner to seal."
        case .active?: guarded.isCustodian ? "All quiet. You hold a key." : "All quiet."
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

    private func stateTint(_ state: ReleaseState?) -> Color {
        switch state {
        case .warning?, .grace?, .claimOpen?, .authorized?, .overdue?, .objected?: .orange
        case .released?: SealTheme.brass
        default: SealTheme.silver
        }
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
struct RecipientPickerSheet: View {
    @Bindable var friendStore: FriendStore
    @Bindable var estateEngine: EstateEngine
    let onPick: (FriendStore.StoredFriend?) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                if friendStore.friends.isEmpty {
                    VStack(spacing: 12) {
                        Text("Nobody to write to yet.").font(.headline).foregroundStyle(.white)
                        Text("An envelope goes to someone you have met in person with Seal. Open People and add them first.")
                            .font(.callout).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center)
                    }
                    .padding(32)
                } else {
                    List(friendStore.friends) { friend in
                        Button { onPick(friend) } label: {
                            HStack {
                                IdentityRing(displayName: friend.identity.displayName, tier: friend.identity.tier, size: 36)
                                Text(friend.identity.displayName).foregroundStyle(.white)
                                Spacer()
                            }
                        }
                        .listRowBackground(Color.white.opacity(0.05))
                        .parentTapTarget()
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Who is it for?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onPick(nil) }.foregroundStyle(SealTheme.brass)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
