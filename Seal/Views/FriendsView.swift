import SwiftUI
import Vision
import VisionKit
import CoreImage.CIFilterBuiltins

/// The friend ceremony (UI.md §3.2): show your QR, scan theirs, fetch their
/// identity from the directory, then they tap THEIR key on YOUR phone.
///
/// Wrapped in a live "forge coach": a one-time how-to before the first scan,
/// a Scan→Verify→Seal step rail, role banners that say whose phone does what,
/// a passkey nearby-device explainer, and a both-directions handoff so people
/// remember the ceremony has to run once on each phone.
struct FriendsView: View {
    let myRoot: RootIdentity
    @Bindable var ceremony: CeremonyManager
    let sync: SyncEngine
    @Bindable var friendStore: FriendStore
    @Bindable var chatEngine: ChatEngine

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

    /// First-timers see the how-to once; after that "Scan" goes straight to the
    /// camera. The "How forging works" link always reopens it.
    @AppStorage("seal.forgeGuideSeen") private var forgeGuideSeen = false

    // Person-level moderation confirmation (App Store 1.2).
    @State private var showModerationAlert = false
    @State private var moderationTitle = ""
    @State private var moderationMessage = ""
    @Environment(\.openURL) private var openURL

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
            .navigationTitle("Circle")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .alert(moderationTitle, isPresented: $showModerationAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(moderationMessage)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        ForgeLogView(myRoot: myRoot, friendStore: friendStore)
                    } label: {
                        Image(systemName: "book.closed.fill")
                            .foregroundStyle(SealTheme.brass)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Stages

    private var listView: some View {
        VStack(spacing: 24) {
            // My QR — the friend scans this on their phone.
            if let qr = Self.qrImage("seal:\(myRoot.credentialIDHash)") {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 180, height: 180)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16))
                Text("Your seal — have a friend scan it")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }

            VStack(spacing: 8) {
                Button {
                    stage = forgeGuideSeen ? .scanning : .guide
                } label: {
                    Label("Scan a friend's seal", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(SealTheme.brass)

                Button { stage = .guide } label: {
                    Text("How forging works")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .padding(.horizontal, 24)

            if friendStore.friends.isEmpty {
                SealMascot(size: 52,
                           line: "No friends forged yet.",
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

    /// One-time (and re-openable) how-to before the first scan.
    private var guideView: some View {
        VStack(spacing: 24) {
            Spacer()
            SealMascot(size: 48,
                       line: "Forge a friend",
                       sub: "Two humans, one tap. Here's the whole thing.")
            ForgeHowToCard()
            Spacer()
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
            .padding(.horizontal, 24)

            Button("Not now") { stage = .list }
                .foregroundStyle(.white.opacity(0.7))
                .padding(.bottom, 24)
        }
    }

    private var scannerView: some View {
        VStack(spacing: 16) {
            ForgeStepRail(active: 1)
            RoleBanner(icon: "viewfinder",
                       text: "This is your phone. Point it at your friend's seal — the QR on their Circle screen.")
            QRScannerView { code in
                guard code.hasPrefix("seal:") else { return }
                let hash = String(code.dropFirst(5))
                stage = .lookingUp(hash)
                Task { await lookup(hash) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 24)
            Text("Point at your friend's seal")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
            Button("Cancel") { stage = .list }
                .foregroundStyle(.white.opacity(0.7))
                .padding(.bottom, 24)
        }
    }

    private func confirmView(_ friend: RootIdentity) -> some View {
        VStack(spacing: 18) {
            ForgeStepRail(active: 2)
            Spacer()
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

            Spacer()
            Button { Task { await forge(friend) } } label: {
                Label("Ready — \(friend.displayName) taps their key", systemImage: "key.radiowaves.forward.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(SealTheme.brass)
            .padding(.horizontal, 24)
            Button("Cancel") { stage = .list }
                .foregroundStyle(.white.opacity(0.7))
                .padding(.bottom, 24)
        }
        .padding(.top, 8)
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
        VStack(spacing: 18) {
            ForgeStepRail(active: 3)
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 72))
                .foregroundStyle(SealTheme.brass)
            Text("Friendship forged")
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

            Spacer()
            Button { stage = .list } label: {
                Label("Show my seal for the other direction", systemImage: "qrcode")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(SealTheme.brass)
            .padding(.horizontal, 24)
            Button("Done") { stage = .list }
                .foregroundStyle(.white.opacity(0.7))
                .padding(.bottom, 24)
        }
        .padding(.top, 8)
    }

    private func failedView(_ reason: String) -> some View {
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
            Button("Try again") { stage = .list }
                .buttonStyle(.borderedProminent)
                .tint(SealTheme.brass)
                .padding(.bottom, 24)
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
        } catch {
            stage = .failed((error as? LocalizedError)?.errorDescription ?? "The forge failed. Try again.")
        }
    }

    // MARK: - Moderation (person-level block / report from Circle)

    private func friendRow(_ friend: FriendStore.StoredFriend) -> some View {
        let blocked = chatEngine.isBlocked(friend.identity.credentialIDHash)
        return NavigationLink {
            ChatView(
                chat: chatEngine.ensureChat(with: friend.identity, myHash: myRoot.credentialIDHash),
                myRoot: myRoot,
                engine: chatEngine,
                friendStore: friendStore)
        } label: {
            HStack {
                Image(systemName: blocked ? "hand.raised.fill" : "checkmark.seal.fill")
                    .foregroundStyle(blocked ? .orange.opacity(0.8)
                                     : (friend.identity.tier == .verified ? SealTheme.brass : SealTheme.silver))
                Text(friend.identity.displayName)
                    .foregroundStyle(.white.opacity(blocked ? 0.4 : 1.0))
                Spacer()
                if blocked {
                    Text("Blocked")
                        .font(.caption2)
                        .foregroundStyle(.orange.opacity(0.8))
                } else {
                    Text(friend.friendship.forgedAt, style: .date)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .listRowBackground(Color.white.opacity(0.05))
        .contextMenu {
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
        return URL(string: "mailto:jaysubplays@gmail.com?subject=\(s)&body=\(b)")
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
