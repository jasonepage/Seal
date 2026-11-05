// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import PhotosUI
import CloudKit
import os

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
    /// The bills and medical set, so deleting speaks for both envelope sets.
    /// Every rule's engine (RuleBook.swift), so a delete covers all of them.
    var allEngines: [EstateEngine] = []
    private var engines: [EstateEngine] { allEngines.isEmpty ? [estateEngine] : allEngines }
    /// Something sealed exists, so deleting has to ask what happens to it.
    private var hasSealedEnvelopes: Bool { engines.contains { $0.estate?.epochPublished == true } }
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
    /// What went wrong revoking, said out loud. It used to be swallowed.
    @State private var revokeError: String?
    @State private var revoking: DeviceEndorsement?
    /// Revoked in this session and verified before publishing. Shown as
    /// revoked even while the directory query has not caught up.
    @State private var revokedHere: Set<Data> = []
    @State private var renaming = false
    @State private var draftName = ""
    @State private var showHowTo = false
    @State private var photoItem: PhotosPickerItem?
    @State private var timestampsOn = false
    @State private var restored = false
    @State private var showPaywall = false
    @Environment(SealPurchase.self) private var purchase

    /// Live name, reflects an in-session rename immediately (myRoot is a
    /// passed-in copy that only refreshes when the parent re-renders).
    private var currentName: String { identity.rootIdentity?.displayName ?? myRoot.displayName }

    @State private var showEditOptions = false
    @State private var showPhotoPicker = false
    @State private var showAdvanced = false

    /// One corner radius for every surface on this screen.
    private static let radius: CGFloat = 16

    private var hasBackup: Bool { !(identity.rootIdentity?.backupCredentials ?? []).isEmpty }

    // LAYOUT (1.3 redesign). Written for someone who was handed a phone and
    // a key and wants to leave letters to their children. Top to bottom:
    // who you are, the one thing that may need doing (a backup key), the
    // everyday switches, help, the purchase, a closed Advanced drawer for
    // records and technical detail, and the account actions last. Recovery
    // is never inside Advanced. Consequences live in confirmation dialogs,
    // not in paragraphs under buttons. No mascot: this is a security surface.

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 26) {
                        header
                        recoveryCard
                        securityGroup
                        helpGroup
                        purchaseGroup
                        advancedGroup
                        accountGroup
                    }
                    .padding(.bottom, 36)
                    // iPad: a centered column. No-op on iPhone.
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                    // GOTCHAS, Layout: keep the scroll content to the screen's
                    // width so nothing can make the page drag sideways.
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
            .confirmationDialog("Your name and photo", isPresented: $showEditOptions, titleVisibility: .visible) {
                Button("Change name") {
                    draftName = currentName
                    renaming = true
                }
                Button(ProfilePhoto.shared.image == nil ? "Choose a photo" : "Choose a new photo") {
                    showPhotoPicker = true
                }
                if ProfilePhoto.shared.image != nil {
                    Button("Remove photo", role: .destructive) { ProfilePhoto.shared.remove() }
                }
                Button("Cancel", role: .cancel) {}
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        ProfilePhoto.shared.set(data)
                    }
                    photoItem = nil
                }
            }
            .alert("Change your name", isPresented: $renaming) {
                TextField("Your name", text: $draftName)
                Button("Save") { Task { await saveName() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This only changes the name people see. Your key stays the same. Others see the new name the next time their app updates.")
            }
            // The consequence goes here, not under the button. Signing out
            // really does erase this iPhone's envelopes and people, so the
            // dialog says so plainly.
            .confirmationDialog("Sign out on this iPhone?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    // ContentView wipes the engines; Parent Mode is view-layer
                    // presentation state, so it is cleared here, otherwise the
                    // next identity on this phone would inherit it.
                    ParentMode.wipe(ownerHash: myRoot.credentialIDHash)
                    RecoveryNotice.wipe(ownerHash: myRoot.credentialIDHash)
                    onSignOut()
                }
            } message: {
                Text("This erases your envelopes and people from this iPhone, and they do not come back. Envelopes you already sealed stay sealed for your people. When you sign in again, Seal keeps checking in on them, but you cannot change them. Your account stays. Sign in again with your key or \(Biometry.name).")
            }
            // Account deletion (App Review 5.1.1(v)). The decision and every
            // warning are unchanged; only the screen leading here got simpler.
            .confirmationDialog(
                hasSealedEnvelopes
                ? "Delete your Seal account forever? This cannot be undone. First, choose what happens to your sealed envelopes.\n\nKeep them: they stay sealed for your family. You can never check in again, so they open under your rule, after the silence, the warnings and your key holders' taps.\n\nCancel them: they are removed and can never be opened by anyone.\n\nYour key holders will see which you chose. Your key signs it, one more tap."
                : "Delete your Seal account forever? It is removed from the directory, people you met can no longer check it is you, and everything on this phone is erased. This cannot be undone. Your key signs it, one more tap.",
                isPresented: $confirmDelete, titleVisibility: .visible
            ) {
                if hasSealedEnvelopes {
                    Button("Delete, and keep my envelopes for my family", role: .destructive) {
                        Task { await deleteIdentity(keepEnvelopes: true) }
                    }
                    Button("Delete, and cancel my envelopes forever", role: .destructive) {
                        Task { await deleteIdentity(keepEnvelopes: false) }
                    }
                } else {
                    Button("Delete my account forever", role: .destructive) {
                        Task { await deleteIdentity(keepEnvelopes: true) }
                    }
                }
            }
            .confirmationDialog(
                "Remove this device? It can never open or sign anything again. Tap your key once more to confirm.",
                isPresented: .init(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
                titleVisibility: .visible
            ) {
                Button("Remove device", role: .destructive) {
                    if let device = revoking {
                        Task {
                            do {
                                try await ceremony.revokeDevice(
                                    devicePublicKey: device.devicePublicKey,
                                    myRoot: myRoot, directory: sync)
                                // The tap verified and the record is saved.
                                // A fresh query can miss it for a few
                                // seconds (index lag), so remember it here.
                                revokedHere.insert(device.devicePublicKey)
                            } catch CeremonyManager.CeremonyError.cancelled {
                                // They backed out on purpose. Nothing to say.
                            } catch {
                                revokeError = (error as? LocalizedError)?.errorDescription ?? SyncEngine.friendly(error)
                            }
                            await loadDevices()
                        }
                    }
                    revoking = nil
                }
            }
            .alert("Could not remove the device", isPresented: Binding(get: { revokeError != nil }, set: { if !$0 { revokeError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(revokeError ?? "") }
            .alert("Restore purchase", isPresented: $restored) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(purchase.isUnlocked
                     ? "Found it. Seal is paid for on this Apple ID."
                     : (purchase.loadError ?? "No Seal purchase was found on this Apple ID. If you paid with a different Apple ID, sign in to the App Store with that one and try again."))
            }
            .task {
                timestampsOn = TimestampStore.isEnabled(ownerHash: myRoot.credentialIDHash)
                await loadDevices()
            }
            .fullScreenCover(isPresented: $showHowTo) {
                SealOnboardingView(onDone: { showHowTo = false })   // the full set
            }
            .sheet(isPresented: $showPaywall) {
                SealPaywallView(purchase: purchase,
                                onUnlocked: { showPaywall = false },
                                onClose: { showPaywall = false })
                    .environment(\.parentMode, parentMode?.isOn == true)
                    .parentTypeScale()
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - 1. Header

    /// The photo, the name and one way to change either. No credential tier
    /// and no fingerprint words here; those are under Advanced.
    private var header: some View {
        VStack(spacing: 8) {
            Button { showEditOptions = true } label: {
                IdentityRing(displayName: currentName, tier: myRoot.tier, size: 88,
                             photo: ProfilePhoto.shared.image)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Your photo")
            .accessibilityHint("Change your name or photo")

            Text(currentName)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text("Your Seal account")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.55))
            Button("Edit name and photo") { showEditOptions = true }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SealTheme.brass)
                .frame(minHeight: 44)
        }
        .padding(.top, 20)
        .padding(.horizontal, 20)
    }

    // MARK: - 2. The one thing that may need doing

    /// No backup key is the state that can cost someone their account, so it
    /// sits right under the name. It asks instead of threatening; the full
    /// story is on the backup key page.
    @ViewBuilder
    private var recoveryCard: some View {
        if hasBackup {
            NavigationLink { backupKeysPage } label: {
                row("Account recovery is ready", icon: "checkmark.shield.fill", tint: SealTheme.brass,
                    subtitle: "Manage backup keys")
            }
            .buttonStyle(.plain)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
            .padding(.horizontal, 20)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.shield")
                        .font(.title3)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Protect your account")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("Add another key in case this one is lost.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                NavigationLink { backupKeysPage } label: {
                    Text("Add a backup key")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(SealTheme.brass)
                .foregroundStyle(SealTheme.ink)
            }
            .padding(16)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .strokeBorder(.orange.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 20)
        }
    }

    /// Adding, listing and removing backup keys: the existing section, on a
    /// page of its own.
    private var backupKeysPage: some View {
        ZStack {
            SealTheme.ink.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("A backup key gets you back into Seal if your main key or this iPhone is lost. Keep it somewhere different from your main key.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)
                    BackupKeysSection(myRoot: myRoot, ceremony: ceremony, sync: sync)
                }
                .padding(.vertical, 20)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.horizontal)
            }
        }
        .navigationTitle("Backup keys")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 3. Security

    private var securityGroup: some View {
        group("Security") {
            if appLock.isAvailable {
                Toggle(isOn: .init(
                    get: { appLock.isEnabled },
                    set: { value in Task { await appLock.setEnabled(value) } })) {
                    rowText("Lock with \(Biometry.name)", icon: Biometry.symbol, tint: SealTheme.brass,
                            subtitle: "Secrets always ask, even when this is off.")
                }
                .tint(SealTheme.brass)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(minHeight: 56)
                separator
            }
            NavigationLink { backupKeysPage } label: {
                row("Backup key", icon: "key.horizontal.fill", tint: SealTheme.brass,
                    value: hasBackup ? "Ready" : "Not added",
                    valueTint: hasBackup ? .white.opacity(0.5) : .orange)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 4. Help

    private var helpGroup: some View {
        group("Help") {
            Button { showHowTo = true } label: {
                row("How Seal works", icon: "questionmark.circle")
            }
            .buttonStyle(.plain)
            separator
            // The site's support page: questions about keys, key holders, a
            // lost phone, and the support email.
            Link(destination: URL(string: "https://sealmessenger.com/support")!) {
                row("Get help with keys and setup", icon: "lifepreserver")
            }
            .buttonStyle(.plain)
            separator
            // Moved here from People in 1.3. It only shares the website.
            ShareLink(item: FriendsView.inviteURL,
                      subject: Text("Seal"),
                      message: Text(FriendsView.inviteMessage)) {
                row("Share Seal", icon: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 5. Purchase

    /// Shown in the demo account too: App Review uses the demo, the demo
    /// cannot seal, and without this row the reviewer could not reach the
    /// purchase (rejection 2.1(b), 2026-10-02). Restore stays reachable for
    /// App Review 3.1.1.
    private var purchaseGroup: some View {
        group("Purchase") {
            if purchase.isUnlocked {
                row("Seal is paid for", icon: "checkmark.seal.fill", tint: SealTheme.brass, chevron: false)
            } else {
                Button { showPaywall = true } label: {
                    row("Buy Seal", icon: "seal", tint: SealTheme.brass,
                        subtitle: "One purchase for the person creating envelopes.",
                        value: purchase.displayPrice)
                }
                .buttonStyle(.plain)
                separator
                Button {
                    Task { await purchase.restore(); restored = true }
                } label: {
                    row("Restore purchase", icon: "arrow.clockwise", chevron: false)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 6. Advanced

    /// Closed by default. Records, devices, timestamps, the fingerprint words
    /// and directory status. Never recovery.
    private var advancedGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { showAdvanced.toggle() }
            } label: {
                HStack {
                    Text("Advanced")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .contentShape(Rectangle())
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityHint(showAdvanced ? "Hides advanced settings" : "Shows advanced settings")

            if showAdvanced {
                Text("You usually will not need these settings.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                VStack(spacing: 0) { advancedRows }
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
            }
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private var advancedRows: some View {
        NavigationLink {
            RecordView(myRoot: myRoot, friendStore: friendStore, estateEngine: estateEngine)
        } label: {
            row("Record", icon: "list.bullet.rectangle.portrait",
                subtitle: "Everything signed between you and each person.")
        }
        .buttonStyle(.plain)
        separator
        NavigationLink {
            ForgeLogView(myRoot: myRoot, friendStore: friendStore)
        } label: {
            row("History", icon: "book.closed", subtitle: "Everyone you added in person, with dates.")
        }
        .buttonStyle(.plain)
        separator
        // Off until asked for, because turning it on sends a short code to an
        // outside timestamp service.
        Toggle(isOn: .init(
            get: { timestampsOn },
            set: { value in
                TimestampStore.setEnabled(value, ownerHash: myRoot.credentialIDHash)
                timestampsOn = value
            })) {
            rowText("Independent timestamps", icon: "clock.badge.checkmark", tint: SealTheme.silver,
                    subtitle: "An outside service also signs the time. Only a short code is sent.")
        }
        .tint(SealTheme.silver)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 56)
        separator
        VStack(alignment: .leading, spacing: 6) {
            rowText("Your words", icon: "text.quote", tint: SealTheme.silver,
                    subtitle: "People you meet can check these match.")
            Text(FingerprintPhrase.phrase(for: myRoot.publicKey))
                .font(.callout)
                .foregroundStyle(SealTheme.brass)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 40)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        if !devices.isEmpty {
            separator
            VStack(alignment: .leading, spacing: 10) {
                Text("Devices")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))
                ForEach(devices, id: \.devicePublicKey) { device in
                    deviceRow(device)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        separator
        VStack(alignment: .leading, spacing: 10) {
            infoRow("Account", String(myRoot.credentialIDHash.prefix(16)) + "\u{2026}", monospaced: true)
            infoRow("Sign-in", myRoot.tier == .verified ? "Hardware key" : "Passkey")
            infoRow("Directory", directoryStatus)
            infoRow("This iPhone", identity.deviceEndorsement != nil ? "Approved by your key" : "Not approved yet")
        }
        .padding(16)
    }

    // MARK: - 7. Account

    /// Last on the screen and quiet until tapped. The consequences are in the
    /// two confirmation dialogs.
    private var accountGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            group("Account") {
                Button { confirmReset = true } label: {
                    row("Sign out on this iPhone", icon: "rectangle.portrait.and.arrow.right", chevron: false)
                }
                .buttonStyle(.plain)
                separator
                Button { confirmDelete = true } label: {
                    row(deleting ? "Deleting\u{2026}" : "Delete account", icon: "trash",
                        tint: .red.opacity(0.85), titleTint: .red.opacity(0.9), chevron: false)
                }
                .buttonStyle(.plain)
                .disabled(deleting)
            }
            if let deleteError {
                Text(deleteError)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 36)
            }
        }
    }

    // MARK: - Building blocks

    /// A titled group: one surface, rows inside it, thin separators between.
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 16)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content() }
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        }
        .padding(.horizontal, 20)
    }

    private var separator: some View {
        Divider()
            .overlay(Color.white.opacity(0.08))
            .padding(.leading, 56)
    }

    /// The icon, the title and at most one short line under it.
    private func rowText(_ title: String, icon: String, tint: Color,
                         titleTint: Color = .white, subtitle: String? = nil) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(titleTint)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .multilineTextAlignment(.leading)
    }

    /// A tappable row: text on the left, an optional value and a chevron on
    /// the right. At least 56 points tall.
    private func row(_ title: String, icon: String, tint: Color = SealTheme.silver,
                     titleTint: Color = .white, subtitle: String? = nil,
                     value: String? = nil, valueTint: Color = .white.opacity(0.5),
                     chevron: Bool = true) -> some View {
        HStack(spacing: 10) {
            rowText(title, icon: icon, tint: tint, titleTint: titleTint, subtitle: subtitle)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(.body)
                    .foregroundStyle(valueTint)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }

    private func deviceRow(_ device: DeviceEndorsement) -> some View {
        let isThisDevice = device.devicePublicKey == identity.deviceEndorsement?.devicePublicKey
        let isRevoked = revokedKeys.contains(device.devicePublicKey)
        return HStack {
            Image(systemName: isRevoked ? "iphone.slash" : "iphone")
                .foregroundStyle(isRevoked ? .orange.opacity(0.7) : SealTheme.silver)
            VStack(alignment: .leading, spacing: 1) {
                Text(isThisDevice ? "This iPhone" : "Device \(device.devicePublicKey.hexString.prefix(8))")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(isRevoked ? 0.4 : 0.9))
                    .strikethrough(isRevoked)
                Text(device.createdAt, format: .dateTime.month(.abbreviated).day().year())
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
            }
            Spacer()
            if isRevoked {
                Text("Removed")
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
    ///
    /// The order matters (DepartureRules.swift, TombstoneProof.swift):
    ///   1. the tap, which signs the delete marker;
    ///   2. the signed "I deleted my account" entry in each envelope set,
    ///      and on cancel the removal of every sealed blob;
    ///   3. the marker;
    ///   4. the local wipe.
    /// A failure in 1 to 3 stops before the wipe, so the person can retry.
    /// If 2 lands and 3 fails, the entry is voided by the next check-in.
    private func deleteIdentity(keepEnvelopes: Bool) async {
        deleting = true
        deleteError = nil
        defer { deleting = false }
        if !DemoFixtures.isActive {
            do {
                let proof = try await ceremony.signDeletion(myRoot: myRoot, directory: sync)
                var notRemoved = 0
                for engine in engines {
                    notRemoved += try await engine.announceDeparture(keepEnvelopes: keepEnvelopes)
                }
                if notRemoved > 0 {
                    // Every copy of Seal still refuses to open them: the
                    // signed cancel is in the record. Logged, not blocking.
                    WebAuthnDiag.log.error("delete: \(notRemoved, privacy: .public) sealed blob(s) could not be removed")
                }
                try await sync.deleteIdentity(credentialIDHash: myRoot.credentialIDHash, proof: proof)
            } catch CeremonyManager.CeremonyError.cancelled {
                return
            } catch {
                // Only blame the connection when it actually is one, otherwise
                // show the real CloudKit reason instead of hiding it.
                let isNetwork = (error as? CKError).map {
                    $0.code == .networkUnavailable || $0.code == .networkFailure || $0.code == .notAuthenticated
                } ?? false
                deleteError = isNetwork
                    ? "Couldn't reach iCloud to remove your directory entry, check your connection and try again."
                    : "Delete failed: " + ((error as? LocalizedError)?.errorDescription ?? SyncEngine.friendly(error))
                return
            }
        }
        ParentMode.wipe(ownerHash: myRoot.credentialIDHash)
        RecoveryNotice.wipe(ownerHash: myRoot.credentialIDHash)
        onDelete()
    }

    private func loadDevices() async {
        guard let (endorsements, revocations) = try? await sync.fetchDeviceList(
            credentialIDHash: myRoot.credentialIDHash) else {
            revokedKeys.formUnion(revokedHere)
            return
        }
        devices = endorsements
        revokedKeys = IdentityManager.revokedDevicePublicKeys(root: myRoot, revocations: revocations)
            .union(revokedHere)
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
    private func infoRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack {
            Text(label).foregroundStyle(.white.opacity(0.5))
            Spacer()
            Text(value)
                .foregroundStyle(.white.opacity(0.9))
                .font(monospaced ? .callout.monospaced() : .callout)
                .lineLimit(1)
        }
        .font(.callout)
    }
}
