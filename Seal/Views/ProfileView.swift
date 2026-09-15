import SwiftUI
import CloudKit

/// Profile + key management surface (UI.md §3.5, trimmed to what exists).
struct ProfileView: View {
    let myRoot: RootIdentity
    @Bindable var identity: IdentityManager
    let sync: SyncEngine
    @Bindable var ceremony: CeremonyManager
    @Bindable var appLock: AppLock
    /// Only the Advanced screen needs these two, for the record and the
    /// ceremony history. Nothing else in Profile touches them.
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

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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

    /// Live name — reflects an in-session rename immediately (myRoot is a
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
                        Text("This is only a label — your key stays your identity. Friends see the new name next time they sync.")
                    }
                    Label(myRoot.tier == .verified ? "Verified — hardware key" : "Passkey",
                          systemImage: myRoot.tier == .verified ? "key.radiowaves.forward.fill" : "faceid")
                        .font(.subheadline)
                        .foregroundStyle(myRoot.tier == .verified ? SealTheme.brass : SealTheme.silver)

                    Text(FingerprintPhrase.phrase(for: myRoot.publicKey))
                        .font(.title3)
                        .foregroundStyle(SealTheme.brass)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)

                    if appLock.isAvailable {
                        settingRow(icon: "faceid", tint: SealTheme.brass,
                                   title: "Require Face ID",
                                   subtitle: "Lock Seal when you leave the app",
                                   isOn: .init(
                                       get: { appLock.isEnabled },
                                       set: { value in Task { await appLock.setEnabled(value) } }),
                                   switchTint: SealTheme.brass)
                    }

                    // Commit-moment lock: one biometric check right at "Seal
                    // and send". Deliberately NOT a gate on ordinary messages —
                    // friction belongs on the irreversible artifact, not chat.
                    if appLock.isAvailable {
                        settingRow(icon: "checkmark.seal", tint: SealTheme.brass,
                                   title: "Face ID to seal a card",
                                   subtitle: "Confirm it's you right before a sealed card is sent",
                                   isOn: .init(
                                       get: { cardLockOn },
                                       set: { value in Task {
                                           cardLockOn = await AppLock.setCardLockEnabled(value, ownerHash: myRoot.credentialIDHash)
                                       } }),
                                   switchTint: SealTheme.brass)
                            .task { cardLockOn = AppLock.isCardLockEnabled(ownerHash: myRoot.credentialIDHash) }
                    }

                    // Was "Simplified mode", which used to swap the whole
                    // shell. There is only one shell now, so this switch does
                    // exactly one thing and is named for it. NEVER labelled by
                    // who it is for: the person reading it is holding the
                    // phone. Silver, not brass: it changes how Seal looks and
                    // makes no claim about trust (UI.md §1.1).
                    if let parentMode {
                        settingRow(icon: "textformat.size", tint: SealTheme.silver,
                                   title: "Bigger text",
                                   subtitle: "Larger type and bigger buttons everywhere in Seal. Nothing is hidden and nothing stops working.",
                                   isOn: .init(
                                       get: { parentMode.isOn },
                                       set: { parentMode.setEnabled($0) }),
                                   switchTint: SealTheme.silver)
                    }

                    // The backup-keys PANEL moved to Advanced, but the
                    // warning did not. Its old comment made the case and it
                    // still holds: having no backup key is the state that
                    // costs you the identity, so it is precisely the state
                    // that must not be invisible. Burying it one tap down
                    // would have been the whole point missed.
                    if (identity.rootIdentity?.backupCredentials ?? []).isEmpty {
                        NavigationLink { advancedScreen } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "exclamationmark.shield")
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("No backup key yet")
                                        .foregroundStyle(.white)
                                    Text("Lose your key and this identity is gone. Nobody can reset it.")
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
                        .buttonStyle(.plain)
                        .padding(.horizontal, 24)
                        .parentTapTarget()
                    }

                    // The tutorial, on demand. WelcomeCarousel only ever
                    // ran once, behind an @AppStorage flag on first launch,
                    // which meant the explanation of what Seal even is was
                    // unreachable the moment somebody tapped through it.
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

                    // Everything that PROVES the claims, one tap down.
                    NavigationLink { advancedScreen } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "gearshape.2")
                                .foregroundStyle(SealTheme.silver)
                            Text("Advanced")
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


                    Button(role: .destructive) { confirmReset = true } label: {
                        Text("Sign out")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)

                    Text("Signing out deletes this device's keys, chats, and friends. Your identity stays in the directory — sign back in with your key or Face ID.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)

                    // Account deletion (App Review 5.1.1(v)): directory record
                    // removed first, then the full local wipe.
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
                        .foregroundStyle(.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .padding(.bottom, 24)
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
                "This deletes this device's keys, chats, and friends — they don't come back. Your identity survives; sign in again with your key or Face ID.",
                isPresented: $confirmReset, titleVisibility: .visible
            ) {
                Button("Sign out and delete local data", role: .destructive) {
                    // ContentView wipes the engines; Parent Mode is view-layer
                    // presentation state, so it is cleared here — otherwise the
                    // next identity on this phone would inherit it.
                    ParentMode.wipe(ownerHash: myRoot.credentialIDHash)
                    RecoveryNotice.wipe(ownerHash: myRoot.credentialIDHash)
                    onSignOut()
                }
            }
            .confirmationDialog(
                "Permanently delete your identity? It's removed from the directory, friends can no longer verify you, and ALL data is destroyed. This cannot be undone — not by you, not by us.",
                isPresented: $confirmDelete, titleVisibility: .visible
            ) {
                Button("Delete identity forever", role: .destructive) {
                    Task { await deleteIdentity() }
                }
            }
            .confirmationDialog(
                "Revoke this device? It can never sign or decrypt again. Your key signs the revocation — one more tap.",
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

    // MARK: - Advanced

    /// Everything that PROVES the claims, one tap below Profile
    /// (docs/COLDSTART.md). These used to be scattered: the identity card, the
    /// device list and the backup keys sat in the middle of Profile, and the
    /// history and the handovers hung off the Circle tab's toolbar as two
    /// unlabelled glyphs. Circle is gone and Profile is what someone opens to
    /// change their name, so the evidence gets its own room.
    ///
    /// A computed property rather than its own file, on purpose: it reads this
    /// view's device state and calls its private row builders, and moving that
    /// state into a second type would buy nothing and cost a sync bug.
    private var advancedScreen: some View {
        ZStack {
            SealTheme.ink.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    // Off by default and asked for explicitly, because turning
                    // it on means a hash leaves this phone. Silver: it changes
                    // what Seal can prove about time, which is a capability,
                    // not a trust claim about a person (UI.md §1.1).
                    settingRow(icon: "clock.badge.checkmark", tint: SealTheme.silver,
                               title: "Independent timestamps",
                               subtitle: "Ask a timestamp authority to sign each record line, so its time is not just this phone's word. Only a hash is sent, never your messages, but it does tell that authority something was recorded.",
                               isOn: .init(
                                   get: { timestampsOn },
                                   set: { value in
                                       TimestampStore.setEnabled(value, ownerHash: myRoot.credentialIDHash)
                                       timestampsOn = value
                                   }),
                               switchTint: SealTheme.silver)

                    VStack(alignment: .leading, spacing: 10) {
                        infoRow("Seal", String(myRoot.credentialIDHash.prefix(24)) + "…")
                        infoRow("Directory", directoryStatus)
                        infoRow("This device", identity.deviceEndorsement != nil ? "Endorsed" : "Not endorsed")
                    }
                    .padding(16)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 24)

                    if !devices.isEmpty { devicesCard }

                    BackupKeysSection(myRoot: myRoot, ceremony: ceremony, sync: sync)

                    // The Record (docs/RECORD.md). First, because it is a
                    // superset of History and the direction of travel: once it
                    // can export, History retires into it.
                    NavigationLink {
                        RecordView(myRoot: myRoot, friendStore: friendStore,
                                   estateEngine: estateEngine)
                    } label: {
                        advancedRow("Record", "list.bullet.rectangle.portrait",
                                    "Everything that has happened between you and each person, signed.")
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 24)
                    .parentTapTarget()

                    NavigationLink {
                        ForgeLogView(myRoot: myRoot, friendStore: friendStore)
                    } label: {
                        advancedRow("History", "book.closed.fill",
                                    "Every person you've added in person, with the date it happened.")
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 24)
                    .parentTapTarget()

                    NavigationLink {
                        ReceiptsView(myRoot: myRoot, identity: identity,
                                     ceremony: ceremony, sync: sync)
                    } label: {
                        advancedRow("Handovers", "shippingbox.fill",
                                    "Signed receipts for things handed over in person.")
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 24)
                    .parentTapTarget()
                }
                .padding(.vertical, 24)
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.horizontal)
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    /// Shown whenever there is any device at all, unlike the old Profile card
    /// which hid itself below two devices. On a screen called Advanced, "you
    /// have exactly one phone" is an answer, not noise.
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

    private func advancedRow(_ title: String, _ icon: String, _ subtitle: String) -> some View {
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

    /// Directory record first, local wipe second — if the network call fails
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
                // Only blame the connection when it actually is one — otherwise
                // show the real CloudKit reason instead of hiding it.
                let isNetwork = (error as? CKError).map {
                    $0.code == .networkUnavailable || $0.code == .networkFailure || $0.code == .notAuthenticated
                } ?? false
                deleteError = isNetwork
                    ? "Couldn't reach iCloud to remove your directory entry — check your connection and try again."
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
        case .idle: "—"
        case .error: "Error — see home"
        }
    }

    /// A settings row that stays operable at accessibility sizes.
    ///
    /// The original shape — icon, label, Spacer, switch — squeezes the switch
    /// toward the edge once the label wraps to three or four lines, and the
    /// one control Parent Mode absolutely must leave reachable is the toggle
    /// that turns Parent Mode off. Above accessibility sizes the switch moves
    /// below the label instead, where it has the full width.
    @ViewBuilder
    private func settingRow(icon: String, tint: Color, title: String, subtitle: String,
                            isOn: Binding<Bool>, switchTint: Color) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 14) {
                    settingLabel(icon: icon, tint: tint, title: title, subtitle: subtitle)
                    Toggle(title, isOn: isOn)
                        .labelsHidden()
                        .tint(switchTint)
                }
            } else {
                HStack(spacing: 12) {
                    settingLabel(icon: icon, tint: tint, title: title, subtitle: subtitle)
                    Toggle(title, isOn: isOn)
                        .labelsHidden()
                        .tint(switchTint)
                }
            }
        }
        .frame(minHeight: 52)
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 24)
    }

    private func settingLabel(icon: String, tint: Color,
                              title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.9))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
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
