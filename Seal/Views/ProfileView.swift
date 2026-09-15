import SwiftUI
import CloudKit

/// Profile + key management surface (UI.md §3.5, trimmed to what exists).
struct ProfileView: View {
    let myRoot: RootIdentity
    @Bindable var identity: IdentityManager
    let sync: SyncEngine
    @Bindable var ceremony: CeremonyManager
    @Bindable var appLock: AppLock
    /// The record and the ceremony history, reached from the "Your record"
    /// section. Nothing else in Profile touches them.
    @Bindable var friendStore: FriendStore
    let estateEngine: EstateEngine
    /// nil only in previews. Optional rather than @Bindable because the toggle
    /// uses a manual binding anyway, and @Observable tracks the reads in body.
    var parentMode: ParentMode? = nil
    let onSignOut: () -> Void
    let onDelete: () -> Void
    /// Set when this is presented as a sheet (the Parent Mode route, where
    /// Profile is not a tab and there is nothing else to dismiss it).
    var onClose: (() -> Void)? = nil

    @State private var confirmReset = false
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var deleteError: String?
    @State private var devices: [DeviceEndorsement] = []
    @State private var revokedKeys: Set<Data> = []
    @State private var revoking: DeviceEndorsement?
    @State private var renaming = false
    @State private var draftName = ""
    /// Mirrors the keychain flag; loaded in .task so the toggle renders true state.
    @State private var cardLockOn = false
    @State private var showHowTo = false
    @State private var timestampsOn = false

    /// Live name, reflects an in-session rename immediately (myRoot is a
    /// passed-in copy that only refreshes when the parent re-renders).
    private var currentName: String { identity.rootIdentity?.displayName ?? myRoot.displayName }

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                ScrollView {
                VStack(spacing: 20) {
                    IdentityRing(displayName: currentName, tier: myRoot.tier, size: 96)
                        .padding(.top, 32)
                    Button {
                        draftName = currentName
                        renaming = true
                    } label: {
                        HStack(spacing: 6) {
                            Text(currentName)
                                .font(.system(.title, design: .rounded, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                            Image(systemName: "pencil")
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    .buttonStyle(.plain)
                    .alert("Change your name", isPresented: $renaming) {
                        TextField("Your name", text: $draftName)
                        Button("Save") { Task { await saveName() } }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This is only a label, your key stays your identity. Friends see the new name next time they sync.")
                    }
                    Label(myRoot.tier == .verified ? "Verified, hardware key" : "Passkey",
                          systemImage: myRoot.tier == .verified ? "key.radiowaves.forward.fill" : "faceid")
                        .font(.subheadline)
                        .foregroundStyle(myRoot.tier == .verified ? SealTheme.brass : SealTheme.silver)

                    Text(FingerprintPhrase.phrase(for: myRoot.publicKey))
                        .font(.title3)
                        .foregroundStyle(SealTheme.brass)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)

                    // ONE SCREEN. There used to be an "Advanced" drawer
                    // below this one holding the backup keys, the devices,
                    // the record and the timestamp switch. Two things gave it
                    // away as wrong. The no-backup-key warning had to reach
                    // into it from out here, because burying the one state
                    // that costs you your identity was plainly wrong. And
                    // RecordView had to tell people where to find a switch. A
                    // product that gives directions to its own settings has
                    // one screen too many. None of it needed hiding. It
                    // needed headings, which is what it has now.
                    //
                    // The word "Advanced" also told the oldest person holding
                    // this phone that their own backup key was not for them.
                    //
                    // The sections are computed properties rather than more
                    // rows in this VStack because a body with two dozen
                    // children and this many modifiers is how this project
                    // lost a build to a type-check timeout once already.
                    backupWarning
                    onThisPhoneSection
                    yourRecordSection
                    helpSection
                    yourKeysSection
                    accountSection
                }
                // iPad/large widths: keep profile content a centered, readable
                // column instead of full-bleed rows. No-op on iPhone.
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
                // Pins the scroll content to exactly the scroll view's width.
                // Without it, any child that demands more room than the screen
                // (a long name, a long fingerprint phrase, a row whose text
                // refuses to wrap, all of it likelier with Bigger text on)
                // silently widens the content and the entire screen becomes
                // draggable side to side. A vertical scroll view should not
                // pan horizontally, ever.
                .containerRelativeFrame(.horizontal)
                }
            }
            .navigationTitle("You")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onClose)
                            .foregroundStyle(SealTheme.brass)
                    }
                }
            }
            .confirmationDialog(
                "This deletes this device's copy of your envelopes and your people. They do not come back. Your identity survives; sign in again with your key or Face ID.",
                isPresented: $confirmReset, titleVisibility: .visible
            ) {
                Button("Sign out and delete local data", role: .destructive) {
                    // ContentView wipes the engines; Parent Mode is view-layer
                    // presentation state, so it is cleared here, otherwise the
                    // next identity on this phone would inherit it.
                    ParentMode.wipe(ownerHash: myRoot.credentialIDHash)
                    RecoveryNotice.wipe(ownerHash: myRoot.credentialIDHash)
                    onSignOut()
                }
            }
            .confirmationDialog(
                "Permanently delete your identity? It's removed from the directory, friends can no longer verify you, and ALL data is destroyed. This cannot be undone, not by you, not by us.",
                isPresented: $confirmDelete, titleVisibility: .visible
            ) {
                Button("Delete identity forever", role: .destructive) {
                    Task { await deleteIdentity() }
                }
            }
            .confirmationDialog(
                "Revoke this device? It can never sign or decrypt again. Your key signs the revocation, one more tap.",
                isPresented: .init(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
                titleVisibility: .visible
            ) {
                Button("Revoke device", role: .destructive) {
                    if let device = revoking {
                        Task {
                            try? await ceremony.revokeDevice(
                                devicePublicKey: device.devicePublicKey,
                                myRoot: myRoot, directory: sync)
                            await loadDevices()
                        }
                    }
                    revoking = nil
                }
            }
            .task {
                timestampsOn = TimestampStore.isEnabled(ownerHash: myRoot.credentialIDHash)
                await loadDevices()
            }
            .fullScreenCover(isPresented: $showHowTo) {
                WelcomeCarousel { showHowTo = false }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Sections

    /// Having no backup key is the state that costs you the identity, so it
    /// is the state that must not be quiet. It used to link into the Advanced
    /// screen. It no longer links anywhere, because the section it was
    /// sending people to is a little further down this same screen.
    @ViewBuilder
    private var backupWarning: some View {
        if (identity.rootIdentity?.backupCredentials ?? []).isEmpty {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No backup key yet")
                        .foregroundStyle(.white)
                    Text("Lose your key and this identity is gone. Nobody can reset it. Add one under Your keys, below.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .font(.callout)
            .multilineTextAlignment(.leading)
            .padding(16)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.orange.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 24)
        }
    }

    @ViewBuilder
    private var onThisPhoneSection: some View {
        sectionHeading("On this phone")

        if appLock.isAvailable {
            SettingRow(icon: "faceid", tint: SealTheme.brass,
                       title: "Require Face ID",
                       summary: "Lock Seal when you leave it",
                       isOn: .init(
                           get: { appLock.isEnabled },
                           set: { value in Task { await appLock.setEnabled(value) } }),
                       switchTint: SealTheme.brass)

            // Commit-moment lock: one biometric check right at "Seal and
            // send". Deliberately NOT a gate on ordinary use, friction
            // belongs on the irreversible artifact.
            SettingRow(icon: "checkmark.seal", tint: SealTheme.brass,
                       title: "Face ID to seal a card",
                       summary: "Check it's you before sending",
                       isOn: .init(
                           get: { cardLockOn },
                           set: { value in Task {
                               cardLockOn = await AppLock.setCardLockEnabled(value, ownerHash: myRoot.credentialIDHash)
                           } }),
                       switchTint: SealTheme.brass)
                .task { cardLockOn = AppLock.isCardLockEnabled(ownerHash: myRoot.credentialIDHash) }
        }

        // Was "Simplified mode", which used to swap the whole shell. There is
        // only one shell now, so this switch does exactly one thing and is
        // named for it. NEVER labelled by who it is for: the person reading it
        // is holding the phone. Silver, not brass: it changes how Seal looks
        // and makes no claim about trust (UI.md 1.1).
        if let parentMode {
            SettingRow(icon: "textformat.size", tint: SealTheme.silver,
                       title: "Bigger text",
                       summary: "Larger type and buttons",
                       detail: "Everything in Seal gets bigger, on this phone only. Nothing is hidden and nothing stops working. If you have already made text larger in your iPhone settings, this goes one step beyond that rather than starting over.",
                       isOn: .init(
                           get: { parentMode.isOn },
                           set: { parentMode.setEnabled($0) }),
                       switchTint: SealTheme.silver)
        }
    }

    @ViewBuilder
    private var yourKeysSection: some View {
        sectionHeading("Your keys")

        BackupKeysSection(myRoot: myRoot, ceremony: ceremony, sync: sync)

        // Shown whenever there is any device at all. "You have exactly one
        // phone" is an answer, not noise.
        if !devices.isEmpty { devicesCard }

        // Last thing on the screen, shut. Nobody reads a truncated hex hash,
        // and the fingerprint phrase at the top of this screen is the same
        // number in words a person can say out loud to their daughter. This is
        // evidence for the one day somebody needs to check it, so it sits at
        // the bottom beside the other reference material rather than in the
        // middle of the keys somebody came here to manage.
        DisclosureCard(title: "Technical details") {
            VStack(alignment: .leading, spacing: 10) {
                infoRow("Seal", String(myRoot.credentialIDHash.prefix(24)) + "\u{2026}")
                Text("The same seal as the words under your name.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
                infoRow("Directory", directoryStatus)
                infoRow("This device", identity.deviceEndorsement != nil ? "Endorsed" : "Not endorsed")
            }
        }
    }

    @ViewBuilder
    private var yourRecordSection: some View {
        sectionHeading("Your record")

        // The Record (docs/RECORD.md). First, because it is a superset of
        // History and the direction of travel: once it can export, History
        // retires into it.
        NavigationLink {
            RecordView(myRoot: myRoot, friendStore: friendStore,
                       estateEngine: estateEngine)
        } label: {
            pageRow("Record", "list.bullet.rectangle.portrait",
                    "Everything that has happened between you and each person, signed.")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
        .parentTapTarget()

        NavigationLink {
            ForgeLogView(myRoot: myRoot, friendStore: friendStore)
        } label: {
            pageRow("History", "book.closed.fill",
                    "Every person you've added in person, with the date it happened.")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
        .parentTapTarget()

        // There was a "Handovers" page here, and a 573-line screen behind it
        // for photographing any object and signing a receipt for it with
        // anybody, friend or not. That was the messenger's ambition, not this
        // product's. The one handover that matters to a will is the security
        // key reaching a custodian, and that is recorded from the person's
        // own page and shows up in the Record as a line like any other.

        // Off by default and asked for explicitly, because turning it on
        // means something leaves this phone. Silver: it changes what Seal can
        // prove about time, which is a capability, not a trust claim about a
        // person (UI.md 1.1).
        SettingRow(icon: "clock.badge.checkmark", tint: SealTheme.silver,
                   title: "Independent timestamps",
                   summary: "Prove when, not just who",
                   detail: "The times in your record come from this phone's own clock, so Seal can prove who signed something and that it has not changed, but not when it happened. Turn this on and an outside service signs each time as well. Only a short code is sent, never an envelope and never a name. It does tell that service that something was written down, which is why it is off until you ask for it.",
                   isOn: .init(
                       get: { timestampsOn },
                       set: { value in
                           TimestampStore.setEnabled(value, ownerHash: myRoot.credentialIDHash)
                           timestampsOn = value
                       }),
                   switchTint: SealTheme.silver)
    }

    @ViewBuilder
    private var helpSection: some View {
        sectionHeading("Help")

        // The tutorial, on demand. WelcomeCarousel only ever ran once, behind
        // an @AppStorage flag on first launch, which meant the explanation of
        // what Seal even is was unreachable the moment somebody tapped
        // through it.
        Button { showHowTo = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(SealTheme.silver)
                Text("How Seal works")
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.3))
            }
            .font(.callout)
            .padding(16)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
        .parentTapTarget()
    }

    @ViewBuilder
    private var accountSection: some View {
        Button(role: .destructive) { confirmReset = true } label: {
            Text("Sign out")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.orange)
        .padding(.horizontal, 24)
        .padding(.top, 16)

        Text("Signing out deletes this device's copy of your envelopes and your people. Your identity stays in the directory. Sign back in with your key or Face ID.")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.5))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)

        // Account deletion (App Review 5.1.1(v)): directory record removed
        // first, then the full local wipe.
        Button(role: .destructive) { confirmDelete = true } label: {
            Group {
                if deleting { ProgressView() } else { Text("Delete identity") }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .disabled(deleting)
        .padding(.horizontal, 24)

        if let deleteError {
            Text(deleteError)
                .font(.caption2)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }

        Text("Deleting removes your identity from the directory permanently. Friends can no longer verify you, and your history is gone for good. There is no recovery.")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.5))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
    }

    /// Shown whenever there is any device at all, unlike the old Profile card
    /// which hid itself below two devices. Under a heading that says "Your
    /// keys", "you have exactly one phone" is an answer, not noise.
    private var devicesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Devices")
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            ForEach(devices, id: \.devicePublicKey) { device in
                deviceRow(device)
            }
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 24)
    }

    /// A plain heading over a group of rows. This is what replaced the
    /// Advanced drawer: none of that material needed hiding, it needed
    /// labels saying what was under them.
    private func sectionHeading(_ text: String) -> some View {
        Text(text)
            .font(.system(.subheadline, design: .rounded, weight: .semibold))
            .foregroundStyle(.white.opacity(0.6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 10)
    }

    /// A row that opens a page. Was `advancedRow`, back when these three
    /// lived behind a drawer called Advanced.
    private func pageRow(_ title: String, _ icon: String, _ subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(SealTheme.brass)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.3))
        }
        .font(.callout)
        .multilineTextAlignment(.leading)
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private func deviceRow(_ device: DeviceEndorsement) -> some View {
        let isThisDevice = device.devicePublicKey == identity.deviceEndorsement?.devicePublicKey
        let isRevoked = revokedKeys.contains(device.devicePublicKey)
        return HStack {
            Image(systemName: isRevoked ? "iphone.slash" : "iphone")
                .foregroundStyle(isRevoked ? .orange.opacity(0.7) : SealTheme.silver)
            VStack(alignment: .leading, spacing: 1) {
                Text(isThisDevice ? "This device" : "Device \(device.devicePublicKey.hexString.prefix(8))")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(isRevoked ? 0.4 : 0.9))
                    .strikethrough(isRevoked)
                Text(device.createdAt, format: .dateTime.month(.abbreviated).day().year())
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
            }
            Spacer()
            if isRevoked {
                Text("Revoked")
                    .font(.caption2)
                    .foregroundStyle(.orange.opacity(0.7))
            } else if !isThisDevice {
                Button { revoking = device } label: {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.orange.opacity(0.8))
                }
            }
        }
    }

    /// Rename: update locally, then republish so friends see the new name.
    private func saveName() async {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != currentName else { return }
        identity.updateDisplayName(trimmed)
        // Best-effort republish; the local change persists regardless, and
        // publishIdentity reports any directory error in the status row.
        if let root = identity.rootIdentity, let endorsement = identity.deviceEndorsement {
            await sync.publishIdentity(root, endorsement: endorsement)
        }
    }

    /// Directory record first, local wipe second, if the network call fails
    /// we keep local state so the user can retry (an orphaned directory
    /// record with no keys behind it would defeat the point of deletion).
    private func deleteIdentity() async {
        deleting = true
        deleteError = nil
        defer { deleting = false }
        if !DemoFixtures.isActive {
            do {
                try await sync.deleteIdentity(credentialIDHash: myRoot.credentialIDHash)
            } catch {
                // Only blame the connection when it actually is one, otherwise
                // show the real CloudKit reason instead of hiding it.
                let isNetwork = (error as? CKError).map {
                    $0.code == .networkUnavailable || $0.code == .networkFailure || $0.code == .notAuthenticated
                } ?? false
                deleteError = isNetwork
                    ? "Couldn't reach iCloud to remove your directory entry, check your connection and try again."
                    : "Delete failed: \(error.localizedDescription)"
                return
            }
        }
        ParentMode.wipe(ownerHash: myRoot.credentialIDHash)
        RecoveryNotice.wipe(ownerHash: myRoot.credentialIDHash)
        onDelete()
    }

    private func loadDevices() async {
        guard let (endorsements, revocations) = try? await sync.fetchDeviceList(
            credentialIDHash: myRoot.credentialIDHash) else { return }
        devices = endorsements
        revokedKeys = IdentityManager.revokedDevicePublicKeys(root: myRoot, revocations: revocations)
    }

    private var directoryStatus: String {
        switch sync.status {
        case .published: "Published"
        case .publishing: "Publishing…"
        // Was a bare ", ". The phase 10 em dash sweep replaced a lone em
        // dash with a comma and a space, and it shipped as a row reading
        // "Directory    ,". Never leave punctuation standing in for a word.
        case .idle: "Not checked yet"
        case .error: "Error, see home"
        }
    }

    /// A settings row that stays operable at accessibility sizes.
    ///
    /// The original shape, icon, label, Spacer, switch, squeezes the switch
    /// toward the edge once the label wraps to three or four lines, and the
    /// one control Parent Mode absolutely must leave reachable is the toggle
    /// that turns Parent Mode off. Above accessibility sizes the switch moves
    /// below the label instead, where it has the full width.
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
