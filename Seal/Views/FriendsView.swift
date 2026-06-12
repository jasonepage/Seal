import SwiftUI
import Vision
import VisionKit
import CoreImage.CIFilterBuiltins

/// The friend ceremony (UI.md §3.2): show your QR, scan theirs, fetch their
/// identity from the directory, then they tap THEIR key on YOUR phone.
struct FriendsView: View {
    let myRoot: RootIdentity
    @Bindable var ceremony: CeremonyManager
    let sync: SyncEngine
    @Bindable var friendStore: FriendStore
    @Bindable var chatEngine: ChatEngine

    enum Stage: Equatable {
        case list
        case scanning
        case lookingUp(String)
        case confirm(RootIdentity)
        case forging(RootIdentity)
        case sealed(RootIdentity)
        case failed(String)
    }
    @State private var stage: Stage = .list

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                switch stage {
                case .list: listView
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

            Button { stage = .scanning } label: {
                Label("Scan a friend's seal", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(SealTheme.brass)
            .padding(.horizontal, 24)

            if friendStore.friends.isEmpty {
                Text("No friends yet. Find one in real life.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                List {
                    ForEach(friendStore.friends) { friend in
                        NavigationLink {
                            ChatView(
                                chat: chatEngine.ensureChat(with: friend.identity, myHash: myRoot.credentialIDHash),
                                myRoot: myRoot,
                                engine: chatEngine,
                                friendStore: friendStore)
                        } label: {
                            HStack {
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundStyle(friend.identity.tier == .verified ? SealTheme.brass : SealTheme.silver)
                                Text(friend.identity.displayName)
                                    .foregroundStyle(.white)
                                Spacer()
                                Text(friend.friendship.forgedAt, style: .date)
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                        }
                        .listRowBackground(Color.white.opacity(0.05))
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

    private var scannerView: some View {
        VStack(spacing: 16) {
            QRScannerView { code in
                guard code.hasPrefix("seal:") else { return }
                let hash = String(code.dropFirst(5))
                stage = .lookingUp(hash)
                Task { await lookup(hash) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .padding(24)
            Text("Point at your friend's seal")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
            Button("Cancel") { stage = .list }
                .foregroundStyle(.white.opacity(0.7))
                .padding(.bottom, 24)
        }
    }

    private func confirmView(_ friend: RootIdentity) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 56))
                .foregroundStyle(SealTheme.silver)
            Text(friend.displayName)
                .font(.system(.title, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
            Text("Found in the directory. To forge the friendship,\n\(friend.displayName) now taps THEIR key on THIS phone.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Spacer()
            Button { Task { await forge(friend) } } label: {
                Label("Ready — tap their key", systemImage: "key.radiowaves.forward.fill")
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
    }

    private func forgingView(_ friend: RootIdentity) -> some View {
        progressView(ceremony.phase == .reading
                     ? "Verifying \(friend.displayName)'s key…"
                     : "Waiting for \(friend.displayName)'s key…")
    }

    private func sealedView(_ friend: RootIdentity) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 72))
                .foregroundStyle(SealTheme.brass)
            Text("Friendship forged")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
            Text("\(friend.displayName) proved their key.\nHave them scan YOUR seal to complete both directions.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Text(FingerprintPhrase.phrase(for: friend.publicKey))
                .font(.title3)
                .foregroundStyle(SealTheme.brass)
            Text("Say it out loud to each other — matching phrases, matching keys.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
            Spacer()
            Button("Done") { stage = .list }
                .buttonStyle(.borderedProminent)
                .tint(SealTheme.brass)
                .padding(.bottom, 24)
        }
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
