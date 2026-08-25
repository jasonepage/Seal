import SwiftUI
import CloudKit

/// Profile + key management surface (UI.md §3.5, trimmed to what exists).
struct ProfileView: View {
    let myRoot: RootIdentity
    @Bindable var identity: IdentityManager
    let sync: SyncEngine
    @Bindable var ceremony: CeremonyManager
    @Bindable var appLock: AppLock
    @Bindable var perkRedeemer: PerkRedeemer
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
    @State private var showRedeem = false
    @State private var devices: [DeviceEndorsement] = []
    @State private var revokedKeys: Set<Data> = []
    @State private var revoking: DeviceEndorsement?
    @State private var renaming = false
    @State private var draftName = ""
    /// Mirrors the keychain flag; loaded in .task so the toggle renders true state.
    @State private var cardLockOn = false

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

                    // Founder edition line — an edition of the tier, not a
                    // third tier. Brass because it's a verified trust artifact.
                    ForEach(verifiedPerks, id: \.grant.codeHashHex) { perk in
                        Label(perk.grant.kind.displayLabel(number: perk.grant.number),
                              systemImage: "seal.fill")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(SealTheme.brass)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        infoRow("Seal", String(myRoot.credentialIDHash.prefix(24)) + "…")
                        infoRow("Directory", directoryStatus)
                        infoRow("This device", identity.deviceEndorsement != nil ? "Endorsed" : "Not endorsed")
                    }
                    .padding(16)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
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

                    // Simplified mode (Theme/ParentMode.swift). NEVER labelled
                    // by who it is for — the person reading this is holding the
                    // phone. Silver, not brass: this changes how Seal looks, it
                    // makes no claim about trust (UI.md §1.1).
                    if let parentMode {
                        settingRow(icon: "textformat.size", tint: SealTheme.silver,
                                   title: "Simplified mode",
                                   subtitle: "Bigger text, and just your chats. Everything still works — you can send and open anything you could before.",
                                   isOn: .init(
                                       get: { parentMode.isOn },
                                       set: { parentMode.setEnabled($0) }),
                                   switchTint: SealTheme.silver)
                        if parentMode.isOn {
                            Text("Adding someone new needs the full app: turn this off, add them, then turn it back on.")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.4))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                        }
                    }

                    if devices.count > 1 || devices.contains(where: { revokedKeys.contains($0.devicePublicKey) }) {
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

                    // Backup keys (FR-3). Unlike the Devices card above this
                    // one is ALWAYS shown, including when the list is empty:
                    // having no backup key is the state that costs you the
                    // identity, so it is precisely the state that must not be
                    // invisible. It loads its own list rather than sharing
                    // loadDevices() — a directory read the profile already
                    // does once more is cheaper than two features sharing
                    // mutable state across a merge.
                    BackupKeysSection(myRoot: myRoot, ceremony: ceremony, sync: sync)

                    if PerkAuthority.isConfigured, verifiedPerks.isEmpty {
                        Button { showRedeem = true } label: {
                            HStack {
                                Image(systemName: "ticket")
                                    .foregroundStyle(SealTheme.silver)
                                Text("Redeem a claim code")
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
                        .padding(.horizontal, 24)
                    }

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

                    Text("Deleting removes your identity from the directory permanently — friends can no longer verify you, and your forge log is gone for good. There is no recovery.")
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
                }
            }
            .navigationTitle("You")
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
            .task { await loadDevices() }
            .sheet(isPresented: $showRedeem) {
                RedeemPerkView(myRoot: myRoot, redeemer: perkRedeemer)
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Locally stored perks, re-verified before display — same discipline as
    /// every other signature in the app. Uses the directory device list when
    /// loaded (a claim signed on another of our devices still verifies),
    /// falling back to this device's endorsement.
    private var verifiedPerks: [PerkAttestation] {
        var endorsements = devices
        if endorsements.isEmpty, let own = identity.deviceEndorsement {
            endorsements = [own]
        }
        return PerkAuthority.verifiedPerks(perkRedeemer.perks, root: myRoot,
                                           endorsements: endorsements)
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
