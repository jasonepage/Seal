// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import Vision
import VisionKit
import CoreImage.CIFilterBuiltins

/// The friend ceremony (UI.md §3.2): show your QR, scan theirs, fetch their
/// identity from the directory, then they tap THEIR key on YOUR phone.
///
/// Wrapped in a live "forge coach": a one-time how-to before the first scan,
/// a Scan→Verify→Seal step rail, role banners that say whose phone does what,
/// and a passkey nearby-device explainer.
///
/// The ceremony runs ONCE, on ONE phone. ForgeHandshake.swift completes the
/// other side automatically, so nothing here should tell anyone to swap
/// phones and run it again (docs/COLDSTART.md 2.2).
struct FriendsView: View {
    let myRoot: RootIdentity
    @Bindable var ceremony: CeremonyManager
    let sync: SyncEngine
    @Bindable var friendStore: FriendStore
    let estateEngine: EstateEngine
    /// Set when this view is presented as a sheet, which is how the chat
    /// list's people button reaches it. nil would leave no way out, so the
    /// caller always passes one. Same pattern as ProfileView.
    var onClose: (() -> Void)? = nil

    enum Stage: Equatable {
        case list
        case guide
        case scanning
        case lookingUp(String)
        case confirm(RootIdentity)
        case forging(RootIdentity)
        case sealed(RootIdentity)
        case failed(String)
    }
    @State private var stage: Stage = .list

    /// The invitation. Always points at the site, never at a TestFlight or App
    /// Store URL: sealmessenger.com is already the WebAuthn relying party and
    /// already serves the landing page, so an invitation sent today still works
    /// after the distribution channel changes underneath it.
    private static let inviteURL = URL(string: "https://sealmessenger.com")!
    private static let inviteMessage = """
        I'm putting my passwords and a few letters in sealed envelopes for when I'm \
        gone, and I'd like you to hold one of the keys. Seal only works between \
        people who set it up face to face, so grab it and we'll take two minutes \
        next time we're together. sealmessenger.com
        """

    /// First-timers see the how-to once; after that "Scan" goes straight to the
    /// camera. The "How forging works" link always reopens it.
    @AppStorage("seal.forgeGuideSeen") private var forgeGuideSeen = false

    // Person-level moderation confirmation (App Store 1.2).
    @State private var showModerationAlert = false
    @State private var moderationTitle = ""
    @State private var moderationMessage = ""
    /// One person's timeline (docs/RECORD.md). Presented from their row.
    @State private var recordFor: FriendStore.StoredFriend?
    @Environment(\.openURL) private var openURL
    /// Circle isn't reachable in Parent Mode (HomeView renders the chat list
    /// alone), so this is belt and braces, but the rule "accepting an
    /// introduction is simplified-mode work, MAKING one is not" belongs on the
    /// control, not only in the shell that happens to hide it today.
    @Environment(\.parentMode) private var parentMode

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                switch stage {
                case .list: listView
                case .guide: guideView
                case .scanning: scannerView
                case .lookingUp: progressView("Looking them up…")
                case .confirm(let friend): confirmView(friend)
                case .forging(let friend): forgingView(friend)
                case .sealed(let friend): sealedView(friend)
                case .failed(let reason): failedView(reason)
                }
            }
            .navigationTitle("People")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .alert(moderationTitle, isPresented: $showModerationAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(moderationMessage)
            }
            .sheet(item: $recordFor) { friend in
                NavigationStack {
                    RecordView(myRoot: myRoot, friendStore: friendStore,
                               estateEngine: estateEngine, counterpart: friend,
                               onClose: { recordFor = nil })
                }
                .preferredColorScheme(.dark)
            }
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done", action: onClose)
                            .foregroundStyle(SealTheme.brass)
                    }
                }
                // The history and the handovers used to hang off this
                // toolbar as two unlabelled brass glyphs. They are evidence,
                // opened rarely and on purpose, so they moved to the You
                // screen under Your record, where they get a name and a
                // sentence each (docs/COLDSTART.md). This screen is now for
                // one job: adding and seeing the people you have actually met.
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Stages

    /// The ONE surface for adding people. It used to compete with an
    /// "Add someone" item in the chat list's compose menu and with
    /// AddSomeoneSheet, which was three doors to two actions. The invite path
    /// that sheet carried moved here, the sheet is gone, and the chat list's
    /// people button is now the single way in.
    private var listView: some View {
        // SCROLLS. It used to be a bare VStack holding a 158pt QR card, two
        // full width buttons, a footnote, and then a List. Two things went
        // wrong on a small phone and on any phone with Bigger text on. The
        // VStack overflowed with no way to reach the bottom, and the nested
        // List got whatever height was left over, which on an SE is close to
        // nothing, so the people you had actually met were the part that
        // disappeared. The List is now a plain LazyVStack inside one
        // ScrollView, which is the only arrangement where the header and the
        // rows scroll together as one page.
        ScrollView {
            VStack(spacing: 20) {
                // Your seal gets a card of its own rather than floating on the
                // background. It is the thing the other person points a camera at.
                if let qr = Self.qrImage("seal:\(myRoot.credentialIDHash)") {
                    VStack(spacing: 10) {
                        Image(uiImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 158, height: 158)
                            .padding(10)
                            .background(.white, in: RoundedRectangle(cornerRadius: 14))
                        Text("Your seal. Have them scan this.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
                    .padding(.horizontal, 24)
                }

                VStack(spacing: 10) {
                    // ONE loud button. Brass, because a key is about to be tapped
                    // in front of you (UI.md §1.1).
                    Button {
                        stage = forgeGuideSeen ? .scanning : .guide
                    } label: {
                        Label("Scan their seal", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SealTheme.brass)
                    .parentTapTarget()

                    // The growth loop, and the only thing here that works when the
                    // other person has nothing installed. Not brass: sending an
                    // invitation proves nothing and taps nobody's key.
                    ShareLink(item: Self.inviteURL,
                              subject: Text("Seal"),
                              message: Text(Self.inviteMessage)) {
                        Label("Invite someone who doesn't have Seal", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .parentTapTarget()


                    Button { stage = .guide } label: {
                        Text("How adding someone works")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.55))
                            .padding(.top, 2)
                    }
                }
                .padding(.horizontal, 24)

                if friendStore.friends.isEmpty {
                    SealMascot(size: 52,
                               line: "Nobody added yet.",
                               sub: "Seals make friends in person. So do you.")
                } else {
                    // Swipe to delete went with the List, and that is a fix as
                    // much as a loss: it called friendStore.remove on its own,
                    // which dropped the person but LEFT them a custodian on the
                    // estate. The Remove in the row's long press menu does both
                    // and says what it means for the envelopes.
                    LazyVStack(spacing: 10) {
                        ForEach(friendStore.friends) { friend in
                            friendRow(friend)
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }
            .padding(.top, 24)
            .padding(.bottom, 32)
            // GOTCHAS: a vertical ScrollView does not constrain its content's
            // width, so one wide child makes the whole screen drag sideways.
            .containerRelativeFrame(.horizontal)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// Scrollable body + an action footer pinned above the tab bar.
    ///
    /// The ceremony screens used to be a bare VStack with Spacers. A VStack
    /// does not clip or scroll, when its content is taller than the screen it
    /// simply overflows in BOTH directions, so the step rail slid up under the
    /// status bar while the primary button slid down under the tab bar, with no
    /// way to reach it. That is why the "Ready, they tap their key" button was
    /// unreachable on a smaller/older phone: the screen wasn't just clipped, it
    /// was unscrollable. Long role banners, the passkey explainer and large
    /// Dynamic Type all make this worse.
    ///
    /// ScrollView makes every screen reachable at any text size; safeAreaInset
    /// keeps the actions above the tab bar and home indicator, where nothing
    /// can cover them.
    private func ceremonyLayout<BodyContent: View, ActionsContent: View>(
        @ViewBuilder body: () -> BodyContent,
        @ViewBuilder actions: () -> ActionsContent
    ) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                body()
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        // Don't rubber-band when everything already fits, on a big phone the
        // short screens should feel static, not loose.
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                actions()
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .background(.ultraThinMaterial)
        }
    }

    /// One-time (and re-openable) how-to before the first scan.
    private var guideView: some View {
        ceremonyLayout {
            SealMascot(size: 48,
                       line: "Add someone",
                       sub: "Two humans, one tap. Here's the whole thing.")
            ForgeHowToCard()
        } actions: {
            Button {
                forgeGuideSeen = true
                stage = .scanning
            } label: {
                Label("Scan a friend's seal", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(SealTheme.brass)

            Button("Not now") { stage = .list }
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var scannerView: some View {
        VStack(spacing: 16) {
            ForgeStepRail(active: 1)
            RoleBanner(icon: "viewfinder",
                       text: "This is your phone. Point it at their seal, the QR code on their People screen.")
            QRScannerView { code in
                guard code.hasPrefix("seal:") else { return }
                let hash = String(code.dropFirst(5))
                stage = .lookingUp(hash)
                Task { await lookup(hash) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))
            // The camera is the flexible child that soaks up slack, so at large
            // Dynamic Type the role banner could squeeze it to nothing and push
            // Cancel off-screen, trapping the user in a live camera with no
            // exit. A floor here keeps the preview usable.
            .frame(minHeight: 180)
            .padding(.horizontal, 24)
            Text("Point at your friend's seal")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
        }
        // NOT ceremonyLayout: a ScrollView proposes unbounded height, and a
        // UIViewControllerRepresentable camera preview sizes ambiguously under
        // that. Only the pinned-footer half applies here.
        .safeAreaInset(edge: .bottom) {
            Button("Cancel") { stage = .list }
                .foregroundStyle(.white.opacity(0.7))
                .padding(.top, 10)
                .padding(.bottom, 6)
        }
    }

    private func confirmView(_ friend: RootIdentity) -> some View {
        ceremonyLayout {
            ForgeStepRail(active: 2)
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 56))
                .foregroundStyle(SealTheme.silver)
            Text(friend.displayName)
                .font(.system(.title, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
            Text("Found in the directory.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))

            RoleBanner(icon: "key.radiowaves.forward.fill",
                       text: "Hand this phone to \(friend.displayName). They prove their key on THIS phone, it never leaves your hands together.")

            if friend.tier == .passkey {
                PasskeyHybridCard(friendName: friend.displayName)
            }
        } actions: {
            Button { Task { await forge(friend) } } label: {
                Label("Ready, \(friend.displayName) taps their key", systemImage: "key.radiowaves.forward.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(SealTheme.brass)
            Button("Cancel") { stage = .list }
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func forgingView(_ friend: RootIdentity) -> some View {
        VStack(spacing: 20) {
            ForgeStepRail(active: 2)
            Spacer()
            progressView(ceremony.phase == .reading
                         ? "Verifying \(friend.displayName)'s key…"
                         : "Waiting for \(friend.displayName)'s key…")
            Text(friend.tier == .passkey
                 ? "If \(friend.displayName) sees an Apple prompt, they pick a nearby device and approve with Face ID."
                 : "Hold the key flat against the top of the phone.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .padding(.top, 8)
    }

    private func sealedView(_ friend: RootIdentity) -> some View {
        ceremonyLayout {
            ForgeStepRail(active: 3)
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 72))
                .foregroundStyle(SealTheme.brass)
            Text("You're connected")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
            Text(FingerprintPhrase.phrase(for: friend.publicKey))
                .font(.title3)
                .foregroundStyle(SealTheme.brass)
            Text("Say it out loud to each other, matching phrases, matching keys.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            RoleBanner(icon: "arrow.triangle.2.circlepath",
                       text: "One direction done. For \(friend.displayName) to hand you a key or write you an envelope, run it once more on THEIR phone: they scan your seal, you tap your key.")
        } actions: {
            Button { stage = .list } label: {
                Label("Show my seal for the other direction", systemImage: "qrcode")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(SealTheme.brass)
            Button("Done") { stage = .list }
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func failedView(_ reason: String) -> some View {
        // Deliberately NOT ceremonyLayout. This screen is short, and a
        // ScrollView would pin two lines of text under the nav bar above a
        // screenful of dead ink. Spacers keep it centred; safeAreaInset still
        // guarantees the button clears the tab bar.
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "xmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text(reason)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .safeAreaInset(edge: .bottom) {
            Button("Try again") { stage = .list }
                .buttonStyle(.borderedProminent)
                .tint(SealTheme.brass)
                .padding(.top, 10)
                .padding(.bottom, 6)
        }
    }

    private func progressView(_ text: String) -> some View {
        VStack(spacing: 16) {
            ProgressView().tint(SealTheme.brass).scaleEffect(1.4)
            Text(text)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    // MARK: - Actions

    private func lookup(_ hash: String) async {
        guard hash != myRoot.credentialIDHash else {
            stage = .failed("That's your own seal."); return
        }
        do {
            guard let found = try await sync.fetchIdentity(credentialIDHash: hash) else {
                stage = .failed("Nobody in the directory with that seal. Have they registered?")
                return
            }
            stage = .confirm(found.0)
        } catch {
            stage = .failed("Couldn't reach the directory: \(error.localizedDescription)")
        }
    }

    private func forge(_ friend: RootIdentity) async {
        stage = .forging(friend)
        ceremony.resetPhase()
        do {
            let friendship = try await ceremony.forgeFriendship(myRoot: myRoot, friend: friend)
            friendStore.add(identity: friend, friendship: friendship)
            stage = .sealed(friend)
            // Hand them their half of the edge so their phone completes the
            // friendship on its own (ForgeHandshake.swift). Without this the
            // ceremony has to be run a SECOND time on their device, the step
            // everybody forgets. Deliberately after `stage = .sealed`, and
            // deliberately non-throwing: the forge already succeeded here, and
            // a directory hiccup must not turn a good ceremony into an error.
            await ForgeHandshakeService.publish(myRoot: myRoot, friend: friend,
                                                friendship: friendship,
                                                identity: ceremony.identity, sync: sync)
        } catch {
            stage = .failed((error as? LocalizedError)?.errorDescription ?? "That didn't finish. Try again.")
        }
    }

    // MARK: - Moderation (person-level block / report from Circle)

    private func friendRow(_ friend: FriendStore.StoredFriend) -> some View {
        let role = estateEngine.estate.map { estate -> String? in
            let custodian = estate.custodians.contains { $0.rootHash == friend.identity.credentialIDHash }
            let recipient = estate.recipients.contains { $0.rootHash == friend.identity.credentialIDHash }
            switch (custodian, recipient) {
            case (true, true): return "Custodian and recipient"
            case (true, false): return "Custodian"
            case (false, true): return "Recipient"
            default: return nil
            }
        } ?? nil
        return NavigationLink {
            PersonView(person: friend, myRoot: myRoot, friendStore: friendStore,
                       estateEngine: estateEngine, ceremony: ceremony, sync: sync)
        } label: {
            HStack {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(friend.identity.tier == .verified ? SealTheme.brass : SealTheme.silver)
                VStack(alignment: .leading, spacing: 2) {
                    Text(friend.identity.displayName)
                        .foregroundStyle(.white)
                    if let role {
                        Text(role)
                            .font(.caption2)
                            .foregroundStyle(SealTheme.brass.opacity(0.9))
                    }
                }
                Spacer()
                Text(friend.friendship.forgedAt, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
                // Outside a List nothing draws the disclosure arrow, and
                // without one the row does not read as something to tap.
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.3))
            }
            .padding(16)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .parentTapTarget()
        .contextMenu {
            Button {
                recordFor = friend
            } label: {
                Label("See the record", systemImage: "list.bullet.rectangle.portrait")
            }
            Divider()
            Button(role: .destructive) {
                estateEngine.removeCustodian(friend.identity.credentialIDHash)
                friendStore.remove(friend.identity.credentialIDHash)
                moderationTitle = "Removed"
                moderationMessage = "\(friend.identity.displayName) has been removed. If they were a custodian, your envelopes are re-keyed the next time you seal them. Meet in person to add them again."
                showModerationAlert = true
            } label: {
                Label("Remove \(friend.identity.displayName)", systemImage: "person.badge.minus")
            }
            Button(role: .destructive) {
                estateEngine.removeCustodian(friend.identity.credentialIDHash)
                friendStore.remove(friend.identity.credentialIDHash)
                if let url = reportURL(for: friend.identity) { openURL(url) }
                moderationTitle = "Reported"
                moderationMessage = "Thanks. \(friend.identity.displayName) has been removed and reported. We review reports and remove violators within 24 hours."
                showModerationAlert = true
            } label: {
                Label("Report \(friend.identity.displayName)", systemImage: "exclamationmark.bubble")
            }
        }
    }

    /// Person-level report email (App Store 1.2). Reports an identity.
    private func reportURL(for identity: RootIdentity) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?+")
        let subject = "Seal report"
        let body = """
        A user reported another user in Seal.

        Reported user: \(identity.displayName)
        Reported user (root hash): \(identity.credentialIDHash)
        Reporter (root hash): \(myRoot.credentialIDHash)

        Action if upheld: tombstone the reported identity in the directory.
        """
        let s = subject.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let b = body.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: "mailto:jasonepage@gmail.com?subject=\(s)&body=\(b)")
    }

    // MARK: - QR

    static func qrImage(_ string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// VisionKit QR scanner wrapped for SwiftUI.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var fired = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !fired else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let value = barcode.payloadStringValue {
                    fired = true
                    onCode(value)
                    break
                }
            }
        }
    }
}
