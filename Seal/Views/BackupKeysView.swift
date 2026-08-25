import SwiftUI

/// Backup keys UI (FR-3, docs/UI.md §3.1 and §3.5) — the keys panel section,
/// the add ceremony sheet, and the post-registration prompt.
///
/// This is a SECURITY surface: no mascot, SF Pro, and brass only where a key
/// actually signs something (UI.md §1.1). The copy's job is to be honest about
/// three things people get wrong about the words "backup key":
///
///   1. it restores the IDENTITY and the friendships, not the messages;
///   2. it has to be a DIFFERENT key or phone, or it dies with the original;
///   3. it does not help against a STOLEN main key, only a lost one.
///
/// None of those are softened anywhere in this file.

// MARK: - Shared copy

enum BackupKeyCopy {
    /// docs/UI.md §3.1, verbatim. Do not soften.
    static let stakes = "Lose every key, lose this identity. Nobody can reset it — not us, not Apple."

    static let notMessages = "A backup key brings back who you are: your identity and your friends. It does not bring back messages — the keys that could read them are destroyed as they're used, so old conversations stay unreadable on a new phone."

    static let stolenNotLost = "If your main key is stolen rather than lost, delete the identity and start fresh. A backup key can carry your identity forward, but it can't lock the thief out."

    static let mustBeDifferent = "Use a second security key, or a passkey on someone else's phone — a helper you'd trust with your identity. The key you already sign in with can't back itself up."

    static let needsMainKey = "Adding or removing a backup key needs your main key — the one you started with. A phone you recovered using a backup key can't do it."

    /// Parent Mode aims the prompt at the person setting the phone up, not at
    /// the person holding it (UI.md §Parent Mode). Never names a category.
    static func promptTitle(parentMode: Bool) -> String {
        parentMode ? "Add the family helper's key as backup." : "Add a backup key."
    }
}

// MARK: - Keys panel section

/// "Backup keys" card in the profile keys panel. Mirrors the Devices card
/// beside it so the two read as one panel.
struct BackupKeysSection: View {
    let myRoot: RootIdentity
    @Bindable var ceremony: CeremonyManager
    let sync: SyncEngine

    @Environment(\.parentMode) private var parentMode
    @State private var backups: [BackupCredential] = []
    @State private var showAdd = false
    @State private var revoking: BackupCredential?
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Backup keys")
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))

            if backups.isEmpty {
                Text(BackupKeyCopy.stakes)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                ForEach(backups) { backup in
                    backupRow(backup)
                }
            }

            Button { showAdd = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "key.radiowaves.forward")
                    // In Simplified mode the phone is usually being set up
                    // BY the helper, so name the thing they're being asked for
                    // (UI.md §Parent Mode). Still never names a category of
                    // person for the phone's owner to read.
                    Text(addLabel)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.3))
                }
                .font(.callout)
                .foregroundStyle(SealTheme.brass)
            }
            .buttonStyle(.plain)
            .parentTapTarget()
            // The demo account has no real credential behind it (its
            // rawCredentialID is nil), so the ceremony could only fail. The
            // section still renders — a reviewer should see that backup keys
            // exist — but the tap is off rather than dead-ending in a system
            // sheet with nothing behind it.
            .disabled(DemoFixtures.isActive)
            .opacity(DemoFixtures.isActive ? 0.5 : 1)

            Text(BackupKeyCopy.notMessages)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)

            Text(BackupKeyCopy.needsMainKey)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)

            if !backups.isEmpty {
                Text(BackupKeyCopy.stolenNotLost)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let loadError {
                Text(loadError)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 24)
        .task { await load() }
        .sheet(isPresented: $showAdd) {
            AddBackupKeySheet(myRoot: myRoot, ceremony: ceremony, sync: sync) {
                Task { await load() }
            }
        }
        .confirmationDialog(
            "Revoke this backup key? It can never sign in again — and any phone that was set up using it stops working too, permanently. Your main key signs the revocation, so this needs one more tap of it.",
            isPresented: .init(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
            titleVisibility: .visible
        ) {
            Button("Revoke backup key", role: .destructive) {
                if let backup = revoking {
                    Task {
                        try? await ceremony.revokeBackupCredential(backup, myRoot: myRoot, directory: sync)
                        await load()
                    }
                }
                revoking = nil
            }
        }
    }

    private var addLabel: String {
        if !backups.isEmpty { return "Add another backup key" }
        return parentMode ? "Add the family helper's key" : "Add a backup key"
    }

    private func backupRow(_ backup: BackupCredential) -> some View {
        HStack(spacing: 12) {
            Image(systemName: backup.tier == .verified ? "key.radiowaves.forward.fill" : "faceid")
                // Tier decides the colour here exactly as it decides ring
                // colour everywhere else (UI.md §1.1) — brass for a hardware
                // key, silver for a passkey. It is not a claim that one is a
                // better backup, only which kind it is.
                .foregroundStyle(backup.tier == .verified ? SealTheme.brass : SealTheme.silver)
            VStack(alignment: .leading, spacing: 1) {
                Text(backup.label.isEmpty ? "Backup key" : backup.label)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                Text(backup.createdAt, format: .dateTime.month(.abbreviated).day().year())
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
            }
            Spacer()
            Button { revoking = backup } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.orange.opacity(0.8))
            }
            .buttonStyle(.plain)
            .parentTapTarget()
        }
        .parentTapTarget()
    }

    private func load() async {
        // Demo mode is fully local: no directory, and nothing to show.
        guard !DemoFixtures.isActive else { return }
        do {
            backups = try await sync.fetchBackupCredentials(credentialIDHash: myRoot.credentialIDHash)
            loadError = nil
        } catch {
            // Don't claim there are no backup keys when we simply couldn't
            // look — that is the one wrong answer on this screen.
            loadError = "Couldn't check your backup keys just now."
        }
    }
}

// MARK: - Add ceremony

/// Two taps on two authenticators: the new key creates a credential, then the
/// main key signs it. The sheet says so before it starts, because a ceremony
/// that surprises you mid-tap is a ceremony people abandon.
struct AddBackupKeySheet: View {
    let myRoot: RootIdentity
    @Bindable var ceremony: CeremonyManager
    let sync: SyncEngine
    var onAdded: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var added = false

    var body: some View {
        ZStack {
            SealTheme.ink.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "key.radiowaves.forward")
                        .font(.system(size: 40))
                        .foregroundStyle(SealTheme.brass)
                        .padding(.top, 32)

                    Text(added ? "Backup key added" : "Add a backup key")
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    if added {
                        Text("You can sign in with this key if you lose the other one. Your identity and friends come back; your messages don't.")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                        Button("Done") { dismiss() }
                            .buttonStyle(.borderedProminent)
                            .tint(SealTheme.brass)
                            .padding(.top, 8)
                    } else {
                        Text(BackupKeyCopy.mustBeDifferent)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Three taps, in this order")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.8))
                            Text("1. The new key or phone — to create the key.\n2. The same key again — so it can confirm it's really yours.\n3. Your own key — to vouch for it.")
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.6))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 24)

                        TextField("Name it (\"Mom's key\", \"key in the safe\")", text: $label)
                            .textFieldStyle(.plain)
                            .autocorrectionDisabled()
                            .padding()
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .parentTapTarget()

                        if let errorText {
                            Text(errorText)
                                .font(.footnote)
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 28)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        VStack(spacing: 10) {
                            Button { Task { await add(tier: .verified) } } label: {
                                actionLabel("I have a security key", system: "key.radiowaves.forward.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(SealTheme.brass)

                            Button { Task { await add(tier: .passkey) } } label: {
                                actionLabel("Use a passkey", system: "faceid")
                            }
                            .buttonStyle(.bordered)
                            .tint(SealTheme.silver)
                        }
                        .disabled(busy)
                        .padding(.horizontal, 24)

                        Text("A passkey saved in iCloud comes back on a new phone. A security key survives even if the Apple account doesn't. Either is a real backup; neither can be the one you already use.")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.4))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                            .fixedSize(horizontal: false, vertical: true)

                        Button("Not now") { dismiss() }
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.bottom, 24)
                            .parentTapTarget()
                    }
                }
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
            }
            if busy { ProgressView().tint(SealTheme.brass) }
        }
        .preferredColorScheme(.dark)
    }

    private func actionLabel(_ title: String, system: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: system)
            Text(title)
        }
        .frame(maxWidth: .infinity, minHeight: 52)
    }

    private func add(tier: IdentityTier) async {
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            _ = try await ceremony.addBackupKey(tier: tier, label: label,
                                                myRoot: myRoot, directory: sync)
            added = true
            onAdded()
        } catch CeremonyManager.CeremonyError.cancelled {
            // User backed out of the system sheet — not an error worth shouting.
            errorText = nil
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription
                ?? "Couldn't add that backup key. Try again."
        }
        ceremony.resetPhase()
    }
}

// MARK: - Post-registration prompt (UI.md §3.1)

/// Blocking card shown once, right after a fresh registration. Blocking
/// because this is the only moment the person is guaranteed to be holding
/// their key and thinking about it — and because the consequence of skipping
/// it is unrecoverable. "I accept the risk" is a real, first-class way out:
/// the point is informed consent, not coercion.
struct BackupKeyPrompt: View {
    let myRoot: RootIdentity
    @Bindable var ceremony: CeremonyManager
    let sync: SyncEngine
    var onFinish: () -> Void

    @State private var showAdd = false
    /// Read straight from the keychain rather than the environment: this card
    /// is presented by ContentView, ABOVE the tree where HomeView injects
    /// \.parentMode. Loaded once in `.task` rather than computed in `body`,
    /// which would hit the keychain on every re-render.
    @State private var parentMode = false

    var body: some View {
        ZStack {
            SealTheme.ink.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.shield")
                        .font(.system(size: 44))
                        .foregroundStyle(.orange)
                        .padding(.top, 48)

                    Text(BackupKeyCopy.promptTitle(parentMode: parentMode))
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)

                    Text(BackupKeyCopy.stakes)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(BackupKeyCopy.notMessages)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .fixedSize(horizontal: false, vertical: true)

                    Button { showAdd = true } label: {
                        Text("Add a backup key")
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SealTheme.brass)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)

                    Button("I accept the risk", action: onFinish)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(minHeight: 52)
                        .padding(.bottom, 32)
                }
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
        .task { parentMode = ParentMode(ownerHash: myRoot.credentialIDHash).isOn }
        .sheet(isPresented: $showAdd) {
            AddBackupKeySheet(myRoot: myRoot, ceremony: ceremony, sync: sync) {
                // A key was added — the prompt has done its job.
                onFinish()
            }
        }
    }
}
