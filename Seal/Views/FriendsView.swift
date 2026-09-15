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
    @Bindable var chatEngine: ChatEngine
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
        I'm moving the private stuff off text messages. Seal only works between \
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
    /// Set when "Introduce … to" is tapped on a friend's row
    /// (docs/INTRODUCTIONS.md). Only ever set for an IN-PERSON friend — the
    /// menu item isn't drawn for a linked one, because introduction doesn't
    /// chain.
    @State private var introducing: FriendStore.StoredFriend?
    /// The Circle-level entry point: no subject chosen yet, so the sheet asks
    /// for both people. The long-press menu remains as a shortcut that
    /// pre-fills the first one.
    @State private var introducingPair = false
    /// One person's timeline (docs/RECORD.md). Presented from their row.
    @State private var recordFor: FriendStore.StoredFriend?
    @Environment(\.openURL) private var openURL
    /// Circle isn't reachable in Parent Mode (HomeView renders the chat list
    /// alone), so this is belt and braces — but the rule "accepting an
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
            .sheet(item: $introducing) { friend in
                IntroduceSheet(subject: friend, myRoot: myRoot,
                               engine: chatEngine, friendStore: friendStore)
            }
            .sheet(isPresented: $introducingPair) {
                IntroduceSheet(myRoot: myRoot, engine: chatEngine,
                               friendStore: friendStore)
            }
            .sheet(item: $recordFor) { friend in
                NavigationStack {
                    RecordView(myRoot: myRoot, friendStore: friendStore,
                               chatEngine: chatEngine, counterpart: friend,
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
                // opened rarely and on purpose, so they moved to Profile ->
                // Advanced where they get a name and a sentence each
                // (docs/COLDSTART.md). This screen is now for one job: adding
                // and seeing the people you have actually met.
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

                // Only once there are two people to introduce. Below that the
                // action cannot do anything, and a button that opens a sheet to
                // explain why it can't help is a broken promise.
                if introducibleCount >= 2 {
                    Button { introducingPair = true } label: {
                        Label("Introduce two people", systemImage: "link")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .foregroundStyle(SealTheme.ink)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SealTheme.silver)
                    .parentTapTarget()
                }

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
                List {
                    ForEach(friendStore.friends) { friend in
                        friendRow(friend)
                    }
                    .onDelete { idx in
                        idx.map { friendStore.friends[$0] }.forEach { friendStore.remove($0.id) }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            Spacer()
        }
        .padding(.top, 24)
    }

    /// Scrollable body + an action footer pinned above the tab bar.
    ///
    /// The ceremony screens used to be a bare VStack with Spacers. A VStack
    /// does not clip or scroll — when its content is taller than the screen it
    /// simply overflows in BOTH directions, so the step rail slid up under the
    /// status bar while the primary button slid down under the tab bar, with no
    /// way to reach it. That is why the "Ready — they tap their key" button was
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
        // Don't rubber-band when everything already fits — on a big phone the
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
            // Cancel off-screen — trapping the user in a live camera with no
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
                       text: "Hand this phone to \(friend.displayName). They prove their key on THIS phone — it never leaves your hands together.")

            if friend.tier == .passkey {
                PasskeyHybridCard(friendName: friend.displayName)
            }
        } actions: {
            Button { Task { await forge(friend) } } label: {
                Label("Ready — \(friend.displayName) taps their key", systemImage: "key.radiowaves.forward.fill")
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
            Text("Say it out loud to each other — matching phrases, matching keys.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            RoleBanner(icon: "arrow.triangle.2.circlepath",
                       text: "One direction done. For \(friend.displayName) to message you, run it once more on THEIR phone: they scan your seal, you tap your key.")
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
            guard let (friend, _) = try await sync.fetchIdentity(credentialIDHash: hash) else {
                stage = .failed("Nobody in the directory with that seal. Have they registered?")
                return
            }
            stage = .confirm(friend)
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
            // ceremony has to be run a SECOND time on their device — the step
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

    /// People this device may introduce — in-person friendships only, since
    /// introduction does not chain (docs/INTRODUCTIONS.md §3.1).
    private var introducibleCount: Int {
        friendStore.friends.filter { $0.friendship.isInPerson }.count
    }

    private func friendRow(_ friend: FriendStore.StoredFriend) -> some View {
        let blocked = chatEngine.isBlocked(friend.identity.credentialIDHash)
        // Introduced, not forged: silver link glyph, never the brass seal
        // check. A linked friend is a real friend — they just aren't a
        // friend this phone watched somebody prove (docs/INTRODUCTIONS.md).
        let linked = !friend.friendship.isInPerson
        return NavigationLink {
            ChatView(
                chat: chatEngine.ensureChat(with: friend.identity, myHash: myRoot.credentialIDHash),
                myRoot: myRoot,
                engine: chatEngine,
                friendStore: friendStore)
        } label: {
            HStack {
                Image(systemName: blocked ? "hand.raised.fill"
                                          : (linked ? "link" : "checkmark.seal.fill"))
                    .foregroundStyle(blocked ? .orange.opacity(0.8)
                                     : (linked ? SealTheme.silver
                                        : (friend.identity.tier == .verified ? SealTheme.brass : SealTheme.silver)))
                Text(friend.identity.displayName)
                    .foregroundStyle(.white.opacity(blocked ? 0.4 : 1.0))
                Spacer()
                if blocked {
                    Text("Blocked")
                        .font(.caption2)
                        .foregroundStyle(.orange.opacity(0.8))
                } else if linked {
                    Text("Linked")
                        .font(.caption2)
                        .foregroundStyle(SealTheme.silver.opacity(0.9))
                } else {
                    Text(friend.friendship.forgedAt, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .listRowBackground(Color.white.opacity(0.05))
        .contextMenu {
            Button {
                recordFor = friend
            } label: {
                Label("See the record", systemImage: "list.bullet.rectangle.portrait")
            }
            Divider()
            // Only an in-person friend can be introduced, and only to another
            // in-person friend. The absence of this item is the UI half of
            // "introduction does not chain"; the enforcing halves are in
            // ChatEngine.sendIntroduction and on both recipients' phones.
            if !blocked, !linked {
                Button {
                    introducing = friend
                } label: {
                    Label("Introduce \(friend.identity.displayName) to…", systemImage: "link")
                }
                Divider()
            }
            if blocked {
                Button {
                    chatEngine.unblock(friend.identity.credentialIDHash)
                } label: {
                    Label("Unblock \(friend.identity.displayName)", systemImage: "hand.raised.slash")
                }
            } else {
                Button(role: .destructive) {
                    chatEngine.block(friend.identity.credentialIDHash)
                    moderationTitle = "Blocked"
                    moderationMessage = "\(friend.identity.displayName) is blocked — hidden from your chats and unable to reach you. Long-press them here to unblock."
                    showModerationAlert = true
                } label: {
                    Label("Block \(friend.identity.displayName)", systemImage: "hand.raised")
                }
                Button(role: .destructive) {
                    chatEngine.block(friend.identity.credentialIDHash)
                    if let url = reportURL(for: friend.identity) { openURL(url) }
                    moderationTitle = "Reported"
                    moderationMessage = "Thanks — \(friend.identity.displayName) is blocked and reported. We review reports and remove violators within 24 hours."
                    showModerationAlert = true
                } label: {
                    Label("Report \(friend.identity.displayName)", systemImage: "exclamationmark.bubble")
                }
            }
        }
    }

    /// Person-level report email (App Store 1.2) — mirrors ChatView.reportMailURL
    /// but reports an identity rather than a single message.
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
